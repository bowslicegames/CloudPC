#!/usr/bin/env python3
"""The one port the browser talks to: noVNC's files, the RFB websocket, and mouse look.

Three kinds of request arrive here:

    GET  /...             noVNC's files, including our index.html
    GET  /websockify      (Upgrade: websocket) relayed byte for byte to websockify
    POST /cloudpc/mouse   {"dx":..,"dy":..} moved through XTEST as *relative* motion

The last one is what makes mouse look work. RFB carries absolute pointer positions
only, so a look update always had to be "a point on the desktop". But Minecraft does
not read a pointer: it reads the mouse as the distance from the centre of its own
window, and while you play it hides the cursor and pins it there. Any absolute point
that is not exactly that centre leaves a constant difference which is added to every
single update, so the camera walks one way whatever the drag does, and dragging back
only subtracts a little from the walk. noVNC piles on: it clamps any point outside
the canvas to the canvas's last pixel, which throws away the sign of the drag too.

A relative motion has no anchor to be wrong about. XTEST moves the pointer by a
delta, the game reads that delta and nothing else, so a drag right and a drag of the
same size left are exact opposites and the camera comes back. It does not matter
where the game window is, whether it is fullscreen, or how the screen is scaled.

Injection is done in this process through libXtst rather than by running xdotool per
event: look updates arrive 20 times a second, and forking a process 20 times a
second on a one-core container is CPU taken straight from the game.
"""

import ctypes
import ctypes.util
import json
import mimetypes
import os
import socket
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import unquote, urlsplit

WEB_ROOT = os.path.abspath(os.environ.get("CLOUDPC_WEB_ROOT", "/usr/share/novnc"))
WS_UPSTREAM = os.environ.get("CLOUDPC_WS_UPSTREAM", "127.0.0.1:8081")
DISPLAY = os.environ.get("CLOUDPC_DISPLAY", ":0")
PORT = int(os.environ.get("NOVNC_PORT", "8080"))
# A single swipe interval is a few dozen pixels; anything near this is a client bug.
MAX_STEP = 2000
# Look requests are cheap, but there is no reason for a page to send thousands a
# second at a one-core desktop.
MAX_BODY = 4096


class Pointer:
    """Relative pointer motion on the X display, straight through libXtst."""

    def __init__(self, display):
        self.lock = threading.Lock()
        self.x11 = ctypes.CDLL(ctypes.util.find_library("X11") or "libX11.so.6")
        self.xtst = ctypes.CDLL(ctypes.util.find_library("Xtst") or "libXtst.so.6")

        self.x11.XOpenDisplay.restype = ctypes.c_void_p
        self.x11.XOpenDisplay.argtypes = [ctypes.c_char_p]
        self.x11.XFlush.argtypes = [ctypes.c_void_p]
        self.x11.XDefaultRootWindow.restype = ctypes.c_ulong
        self.x11.XDefaultRootWindow.argtypes = [ctypes.c_void_p]

        unsigned_long = ctypes.c_ulong
        integer = ctypes.c_int
        self.x11.XQueryPointer.restype = ctypes.c_int
        self.x11.XQueryPointer.argtypes = [
            ctypes.c_void_p, unsigned_long,
            ctypes.POINTER(unsigned_long), ctypes.POINTER(unsigned_long),
            ctypes.POINTER(integer), ctypes.POINTER(integer),
            ctypes.POINTER(integer), ctypes.POINTER(integer),
            ctypes.POINTER(ctypes.c_uint),
        ]
        self.xtst.XTestFakeRelativeMotionEvent.restype = ctypes.c_int
        self.xtst.XTestFakeRelativeMotionEvent.argtypes = [
            ctypes.c_void_p, ctypes.c_int, ctypes.c_int, ctypes.c_ulong]

        self.display = self.x11.XOpenDisplay(display.encode())
        if not self.display:
            raise SystemExit("mouseproxy: cannot open X display %s" % display)

    def move(self, dx, dy):
        """Move the pointer by (dx, dy) desktop pixels. Xlib is not thread safe, and
        every handler runs in its own thread, so the display is serialised here."""
        dx = max(-MAX_STEP, min(MAX_STEP, dx))
        dy = max(-MAX_STEP, min(MAX_STEP, dy))
        if not dx and not dy:
            return True
        with self.lock:
            ok = self.xtst.XTestFakeRelativeMotionEvent(self.display, dx, dy, 0)
            self.x11.XFlush(self.display)
        return bool(ok)

    def position(self):
        """Where the pointer is now, for the page's debug line: if this does not move
        when a look update is sent, the injection is not reaching X at all."""
        with self.lock:
            root = self.x11.XDefaultRootWindow(self.display)
            root_ret = ctypes.c_ulong()
            child_ret = ctypes.c_ulong()
            root_x = ctypes.c_int()
            root_y = ctypes.c_int()
            win_x = ctypes.c_int()
            win_y = ctypes.c_int()
            mask = ctypes.c_uint()
            found = self.x11.XQueryPointer(
                self.display, root,
                ctypes.byref(root_ret), ctypes.byref(child_ret),
                ctypes.byref(root_x), ctypes.byref(root_y),
                ctypes.byref(win_x), ctypes.byref(win_y),
                ctypes.byref(mask))
            if not found:
                return None
            return {"x": root_x.value, "y": root_y.value}


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "CloudPC"
    # Every response here is small and interactive — a look update's reply is about
    # 60 bytes. Nagle would hold it waiting for an ACK, and the browser would hold
    # the next look update waiting for that reply, so the delay compounds into
    # hundreds of milliseconds of input lag that has nothing to do with the network.
    disable_nagle_algorithm = True

    # The container log belongs to the desktop and the game, not to a request per
    # look update.
    def log_message(self, *args):
        pass

    def reply(self, code, kind, body):
        if isinstance(body, str):
            body = body.encode()
        self.send_response(code)
        self.send_header("Content-Type", kind)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        if body:
            self.wfile.write(body)

    # ---------- reading ----------

    def do_GET(self):
        if self.headers.get("Upgrade", "").lower() == "websocket":
            return self.tunnel()
        self.serve_static()

    def serve_static(self):
        path = unquote(urlsplit(self.path).path)
        if path in ("", "/"):
            path = "/index.html"
        target = os.path.abspath(os.path.join(WEB_ROOT, path.lstrip("/")))
        # Never serve anything outside noVNC's directory, whatever the path says.
        if target != WEB_ROOT and not target.startswith(WEB_ROOT + os.sep):
            return self.reply(403, "text/plain", "forbidden")
        if os.path.isdir(target):
            target = os.path.join(target, "index.html")
        try:
            with open(target, "rb") as handle:
                body = handle.read()
        except OSError:
            return self.reply(404, "text/plain", "not found")
        kind = mimetypes.guess_type(target)[0] or "application/octet-stream"
        self.reply(200, kind, body)

    # ---------- the RFB websocket ----------

    def tunnel(self):
        host, _, port = WS_UPSTREAM.partition(":")
        try:
            upstream = socket.create_connection((host, int(port)), timeout=15)
        except (OSError, ValueError):
            return self.reply(502, "text/plain", "websockify is not reachable")
        upstream.settimeout(None)

        # The same reason as on the HTTP side, one hop further along: websockify
        # carries RFB frames that can be a few dozen bytes, and every one of them is
        # something the game is waiting to draw or the player is waiting to see.
        for sock in (self.connection, upstream):
            try:
                sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
            except OSError:
                pass

        head = "%s %s HTTP/1.1\r\n" % (self.command, self.path)
        for key, value in self.headers.items():
            head += "%s: %s\r\n" % (key, value)
        head += "\r\n"
        try:
            upstream.sendall(head.encode("latin-1"))
        except OSError:
            upstream.close()
            return self.reply(502, "text/plain", "websockify is not reachable")

        client = self.connection
        client.settimeout(None)
        self.close_connection = True
        done = threading.Event()

        def pump(source, sink):
            try:
                while not done.is_set():
                    chunk = source.recv(65536)
                    if not chunk:
                        break
                    sink.sendall(chunk)
            except OSError:
                pass
            finally:
                done.set()
                try:
                    sink.shutdown(socket.SHUT_WR)
                except OSError:
                    pass

        workers = [threading.Thread(target=pump, args=(client, upstream), daemon=True),
                   threading.Thread(target=pump, args=(upstream, client), daemon=True)]
        for worker in workers:
            worker.start()
        for worker in workers:
            worker.join()
        try:
            upstream.close()
        except OSError:
            pass

    # ---------- mouse look ----------

    def do_POST(self):
        if urlsplit(self.path).path != "/cloudpc/mouse":
            return self.reply(404, "text/plain", "not found")
        # A custom header cannot be attached by another site without a CORS
        # preflight, which this server never approves, so only our own page can
        # steer the pointer.
        if self.headers.get("X-CloudPC") != "1":
            return self.reply(403, "text/plain", "forbidden")
        origin = self.headers.get("Origin")
        if origin and urlsplit(origin).netloc not in ("", self.headers.get("Host")):
            return self.reply(403, "text/plain", "forbidden")

        try:
            length = int(self.headers.get("Content-Length") or 0)
        except ValueError:
            length = 0
        if length <= 0 or length > MAX_BODY:
            return self.reply(400, "text/plain", "bad request")
        try:
            body = json.loads(self.rfile.read(length) or b"{}")
            dx = int(round(float(body.get("dx", 0))))
            dy = int(round(float(body.get("dy", 0))))
        except (ValueError, TypeError, AttributeError, json.JSONDecodeError):
            return self.reply(400, "text/plain", "bad request")

        if POINTER is None:
            return self.reply(503, "text/plain", "no X display")
        if not POINTER.move(dx, dy):
            return self.reply(500, "text/plain", "injection failed")
        where = POINTER.position() or {}
        self.reply(200, "application/json", json.dumps({
            "dx": dx, "dy": dy,
            "x": where.get("x"), "y": where.get("y"),
        }))


POINTER = None


def main():
    global POINTER
    # A desktop that cannot be opened is the entrypoint's problem, not this
    # process': noVNC should still be served so the failure is visible instead of
    # the whole app going away.
    try:
        POINTER = Pointer(DISPLAY)
    except (OSError, SystemExit) as error:
        print("mouseproxy: relative mouse disabled: %s" % error, flush=True)
    server = ThreadingHTTPServer(("0.0.0.0", PORT), Handler)
    server.request_queue_size = 64
    server.daemon_threads = True
    print("CloudPC: noVNC and relative mouse on 0.0.0.0:%d (websocket to %s)"
          % (PORT, WS_UPSTREAM), flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    return 0


if __name__ == "__main__":
    sys.exit(main())
