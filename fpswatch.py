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

Two files are published. FPS_FILE holds the whole number, and is removed when no game
window is up. FPS_FILE.status holds the same reading with the reason behind it — no
window, no DAMAGE extension, no X connection — so the page can say why it has no
number instead of showing a dash with no explanation. The reading is written every
second for as long as this process lives: a branch that published nothing left a stale
file behind and the page read that as "no measurement at all".

This runs as its own process on purpose: a fault here can cost the reading and nothing
else — the desktop, the stream and the input path never wait on it.
"""

import ctypes
import ctypes.util
import json
import os
import select
import subprocess
import sys
import time
from collections import deque

DISPLAY = os.environ.get("CLOUDPC_DISPLAY", ":0")
FPS_FILE = os.environ.get("CLOUDPC_FPS_FILE", "/tmp/cloudpc-fps")
STATUS_FILE = os.environ.get("CLOUDPC_FPS_STATUS", FPS_FILE + ".status")
GAME_TITLE = os.environ.get("CLOUDPC_GAME_TITLE", "^Minecraft")

# A presented frame writes the window: Minecraft clears it and draws the world into
# it, so one frame's damage covers all of it. A HUD redraw, a tooltip or a cursor
# alone is a sliver, and counting those would report frames where nothing happened.
# The share is deliberately small: some drivers only report the rectangle that really
# changed, and a frame that is mostly identical would then look like a sliver too.
FRAME_AREA = 0.02
MIN_FRAME_AREA = 2048
# If a window's damage never reaches that share, count every damage on it instead of
# giving up on the reading.
LOOSE_AFTER = 4.0
# One frame can arrive as more than one damaged rectangle; anything closer than this
# to the last counted one belongs to the same frame. A 30 fps game presents every 33 ms.
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


def publish(value, status):
    """Write the reading and the reason behind it. Replaced rather than overwritten so
    a reader never sees half a number, and removed when there is nothing to report."""
    try:
        with open(STATUS_FILE + ".tmp", "w", encoding="utf-8") as handle:
            json.dump(status, handle)
        os.replace(STATUS_FILE + ".tmp", STATUS_FILE)
    except OSError:
        pass
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
    # A damage object accumulates until it is subtracted; left alone the region grows
    # until it is the whole window and costs the server work on every frame.
    xdamage.XDamageSubtract.argtypes = [
        ctypes.c_void_p, ctypes.c_ulong, ctypes.c_ulong, ctypes.c_ulong]

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
    created = 0.0
    events = frames = 0
    biggest = (0, 0)
    loose = False

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
                width = height = 0
                stamps.clear()
                events = frames = 0
                biggest = (0, 0)
                loose = False
            elif found["id"] != window:
                if damage:
                    xdamage.XDamageDestroy(display, damage)
                window = found["id"]
                width, height = found["width"], found["height"]
                damage = xdamage.XDamageCreate(display, window, 0)
                x11.XSync(display, 0)
                stamps.clear()
                events = frames = 0
                biggest = (0, 0)
                loose = False
                created = time.monotonic()
                if not damage:
                    print("CloudPC: window %s takes no damage watch" % window, flush=True)
                    window = None

        while x11.XPending(display):
            x11.XNextEvent(display, ctypes.cast(event, ctypes.c_void_p))
            item = DamageNotify.from_buffer(event)
            if item.type != notify or item.damage != damage:
                continue
            events += 1
            area = item.area.width * item.area.height
            if area > biggest[0] * biggest[1]:
                biggest = (item.area.width, item.area.height)
            if area < (1 if loose else max(MIN_FRAME_AREA, FRAME_AREA * width * height)):
                continue
            if now - last_count < FRAME_GAP:
                continue
            last_count = now
            stamps.append(now)
            frames += 1
            if frames == 1:
                print("CloudPC: game frame %dx%d on a %dx%d window"
                      % (item.area.width, item.area.height, width, height), flush=True)

        if damage and not loose and events and not frames and now - created >= LOOSE_AFTER:
            loose = True
            print("CloudPC: no damage on the game window covers a frame (largest %dx%d of "
                  "%dx%d); counting every damage instead"
                  % (biggest[0], biggest[1], width, height), flush=True)

        if damage:
            xdamage.XDamageSubtract(display, damage, 0, 0)

        if time.monotonic() >= next_publish:
            after = time.monotonic()
            next_publish = after + 1.0
            cutoff = after - RATE_WINDOW
            while stamps and stamps[0] < cutoff:
                stamps.popleft()
            rate = 0
            if window is not None:
                if len(stamps) >= 2 and stamps[-1] - stamps[0] >= 0.5:
                    rate = round((len(stamps) - 1) / (stamps[-1] - stamps[0]))
                else:
                    rate = round(len(stamps) / RATE_WINDOW)
            why = "" if window is not None else "no game window"
            if window is not None and not rate:
                why = "the game window is not being drawn into"
            publish(None if window is None else rate, {
                "up": window is not None,
                "fps": None if window is None else rate,
                "why": why,
                "window": [width, height],
                "events": events,
                "frames": frames,
                "biggest": [biggest[0], biggest[1]],
                "loose": loose,
            })

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
    publish(None, {"up": False, "fps": None, "why": reason})
    print("CloudPC: frame counter stopped: %s" % reason, flush=True)
    return 1


if __name__ == "__main__":
    sys.exit(main())
