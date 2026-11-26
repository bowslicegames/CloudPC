#!/usr/bin/env python3
"""The game's own frame rate, taken from the damage its window receives.

x11vnc sends the pixels that changed, which is the right thing to ship and the wrong
thing to count. While the camera stands still a frame costs nothing, no rectangle
changes, and the page's counter reads zero — although the game is drawing thirty
frames a second exactly as before. That zero is then read as "the game is slow" by
both the player and the Auto detail control, and neither is true.

Every frame Minecraft presents is one large write into its window, and X records that
write as damage whether or not one pixel of it differs. Watching the window's damage
therefore counts presented frames, still camera or not, and it is the number a player
means by fps.

The result is published as a whole number in FPS_FILE and the file is removed when no
game window is up. This runs as its own process on purpose: a fault here can cost the
reading and nothing else — the desktop, the stream and the input path never wait on
it, and a stale file is ignored by the reader.
"""

import ctypes
import ctypes.util
import os
import select
import subprocess
import sys
import time
from collections import deque

DISPLAY = os.environ.get("CLOUDPC_DISPLAY", ":0")
FPS_FILE = os.environ.get("CLOUDPC_FPS_FILE", "/tmp/cloudpc-fps")
GAME_TITLE = os.environ.get("CLOUDPC_GAME_TITLE", "^Minecraft")

# A presented frame's damage covers the window; a HUD redraw, a tooltip or a cursor
# alone is a sliver of it. Only the former counts as a frame.
FRAME_AREA = 0.35
MIN_FRAME_AREA = 4096
# One frame can arrive as two damaged rectangles; anything closer than this to the last
# counted one is part of the same frame. A 30 fps game presents every 33 ms.
FRAME_GAP = 0.004
WINDOW_POLL = 2.0
RATE_WINDOW = 2.0


class XRectangle(ctypes.Structure):
    _fields_ = [("x", ctypes.c_short), ("y", ctypes.c_short),
                ("width", ctypes.c_ushort), ("height", ctypes.c_ushort)]


class DamageNotify(ctypes.Structure):
    """XDamageNotifyEvent, in Xlib's layout on a 64-bit platform."""
    _fields_ = [("type", ctypes.c_int),
                ("serial", ctypes.c_ulong),
                ("send_event", ctypes.c_int),
                ("display", ctypes.c_void_p),
                ("drawable", ctypes.c_ulong),
                ("damage", ctypes.c_ulong),
                ("level", ctypes.c_int),
                ("more", ctypes.c_int),
                ("area", XRectangle),
                ("geometry", XRectangle)]


def library(name, fallback):
    return ctypes.CDLL(ctypes.util.find_library(name) or fallback)


def game_window():
    """Minecraft's window and its size, or None when it is not on screen."""
    try:
        found = subprocess.run(["xdotool", "search", "--onlyvisible", "--name", GAME_TITLE],
                               capture_output=True, text=True, timeout=4)
        if found.returncode != 0 or not found.stdout.split():
            return None
        wid = found.stdout.split()[0]
        info = subprocess.run(["xdotool", "getwindowgeometry", "--shell", wid],
                              capture_output=True, text=True, timeout=4)
        values = {}
        for line in info.stdout.splitlines():
            key, _, value = line.partition("=")
            values[key.strip()] = value.strip()
        return {"id": int(wid, 10), "width": int(values["WIDTH"]),
                "height": int(values["HEIGHT"])}
    except (OSError, subprocess.SubprocessError, KeyError, ValueError):
        return None


def publish(value):
    """Write the reading, or remove it when there is nothing to report. Replaced
    rather than overwritten so the reader never sees half a number."""
    if value is None:
        try:
            os.unlink(FPS_FILE)
        except OSError:
            pass
        return
    try:
        with open(FPS_FILE + ".tmp", "w", encoding="utf-8") as handle:
            handle.write("%d\n" % value)
        os.replace(FPS_FILE + ".tmp", FPS_FILE)
    except OSError:
        pass


def watch():
    x11 = library("X11", "libX11.so.6")
    xdamage = library("Xdamage", "libXdamage.so.1")

    x11.XOpenDisplay.restype = ctypes.c_void_p
    x11.XOpenDisplay.argtypes = [ctypes.c_char_p]
    x11.XConnectionNumber.restype = ctypes.c_int
    x11.XConnectionNumber.argtypes = [ctypes.c_void_p]
    x11.XNextEvent.argtypes = [ctypes.c_void_p, ctypes.c_void_p]
    x11.XPending.argtypes = [ctypes.c_void_p]
    x11.XSync.argtypes = [ctypes.c_void_p, ctypes.c_int]
    x11.XSetErrorHandler.argtypes = [ctypes.c_void_p]
    xdamage.XDamageQueryExtension.argtypes = [
        ctypes.c_void_p, ctypes.POINTER(ctypes.c_int), ctypes.POINTER(ctypes.c_int)]
    xdamage.XDamageCreate.restype = ctypes.c_ulong
    xdamage.XDamageCreate.argtypes = [ctypes.c_void_p, ctypes.c_ulong, ctypes.c_int]
    xdamage.XDamageDestroy.argtypes = [ctypes.c_void_p, ctypes.c_ulong]

    # A window can disappear between xdotool naming it and damage being created on it,
    # and Xlib's default error handler calls exit() for a bad drawable. The game
    # closing is ordinary; it must not end the reading for the next one.
    handler = ctypes.CFUNCTYPE(ctypes.c_int, ctypes.c_void_p, ctypes.c_void_p)(
        lambda display, event: 0)
    x11.XSetErrorHandler(ctypes.cast(handler, ctypes.c_void_p))

    display = x11.XOpenDisplay(DISPLAY.encode())
    if not display:
        return "cannot open X display %s" % DISPLAY
    base = ctypes.c_int()
    error = ctypes.c_int()
    if not xdamage.XDamageQueryExtension(display, ctypes.byref(base), ctypes.byref(error)):
        return "this X display has no DAMAGE extension"

    notify = base.value + 0  # XDamageNotify
    event = ctypes.create_string_buffer(192)  # XEvent is 24 longs on 64-bit
    descriptor = x11.XConnectionNumber(display)
    stamps = deque()
    window = None
    damage = 0
    width = height = 0
    next_poll = 0.0
    next_publish = 0.0
    last_count = 0.0

    while True:
        now = time.monotonic()

        if now >= next_poll:
            next_poll = now + WINDOW_POLL
            found = game_window()
            if found is None:
                if damage:
                    xdamage.XDamageDestroy(display, damage)
                damage = 0
                window = None
                stamps.clear()
            elif found["id"] != window:
                if damage:
                    xdamage.XDamageDestroy(display, damage)
                window = found["id"]
                width, height = found["width"], found["height"]
                damage = xdamage.XDamageCreate(display, window, 0)
                x11.XSync(display, 0)
                stamps.clear()
                if not damage:
                    window = None

        while x11.XPending(display):
            x11.XNextEvent(display, ctypes.cast(event, ctypes.c_void_p))
            item = DamageNotify.from_buffer(event)
            if item.type != notify or item.damage != damage:
                continue
            area = item.area.width * item.area.height
            if area < max(MIN_FRAME_AREA, FRAME_AREA * width * height):
                continue
            if now - last_count < FRAME_GAP:
                continue
            last_count = now
            stamps.append(now)

        if time.monotonic() >= next_publish:
            next_publish = time.monotonic() + 1.0
            cutoff = next_publish - RATE_WINDOW
            while stamps and stamps[0] < cutoff:
                stamps.popleft()
            if window is None:
                publish(None)
            elif len(stamps) >= 2 and stamps[-1] - stamps[0] >= 0.4:
                publish(round((len(stamps) - 1) / (stamps[-1] - stamps[0])))
            elif not stamps:
                publish(0)

        wait = min(0.25, max(0.0, min(next_poll, next_publish) - time.monotonic()))
        try:
            select.select([descriptor], [], [], wait)
        except (OSError, ValueError):
            time.sleep(wait)


def main():
    print("CloudPC: game frame rate from window damage on %s" % DISPLAY, flush=True)
    try:
        reason = watch()
    except OSError as error:
        reason = "X libraries or the display are unavailable: %s" % error
    print("CloudPC: frame counter stopped: %s" % reason, flush=True)
    return 1


if __name__ == "__main__":
    sys.exit(main())
