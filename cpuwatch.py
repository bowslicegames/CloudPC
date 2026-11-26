#!/usr/bin/env python3
"""Where the container's CPU is going, one log line per interval.

The container runs on a cgroup quota — 125% of a core on the app this was written
for — and every stage of a frame costs some of it: Minecraft's render and server
threads, llvmpipe filling the framebuffer, x11vnc reading the damaged rectangles and
JPEG-ing them, Xvfb copying the pixels, websockify shipping them, the launcher and the
proxy idling beside them. That is one budget and five processes, so "it is slow" never
had an owner: the performance line says what the quota is and nothing about where it
went.

llvmpipe is not a process. It is a library linked into Minecraft's JVM and its raster
threads run inside that PID, so a per-process view can never separate the rasteriser
from the game. The game's threads are therefore summed by name inside its own process,
which is as far as /proc can take it: render, server, chunk builders, the JIT, and
whatever is left in "other" — on this image, that is mostly the rasteriser.

Percentages are share of one core, as top prints them, so they reach the quota when the
container is saturated. The sampler reads /proc twice, INTERVAL apart, and subtracts:
two snapshots a minute do not show up in their own numbers. A process that was not in
the first snapshot contributes nothing to the second, so starting the game does not
report its whole lifetime as one interval.
"""

import os
import sys
import time

try:
    INTERVAL = max(10.0, float(os.environ.get("CPU_LOG_INTERVAL", "30") or 30))
except ValueError:
    INTERVAL = 30.0
SELF = os.getpid()
HZ = os.sysconf("SC_CLK_TCK")

# Threads inside the game's JVM, grouped by name. llvmpipe does not name its raster
# workers in every build; when it does not, their share is in "other", which still
# answers the only question that matters — is the time in the rasteriser or in Java.
THREAD_GROUPS = (
    ("render", ("render thread", "render-")),
    ("raster", ("llvmpipe", "lp_rast", "rast", "mesa", "tc-")),
    ("server", ("server thread",)),
    ("chunks", ("sodium", "worker-main", "chunk")),
    ("netty", ("netty",)),
    ("compiler", ("compiler", "c2 ", "c1 ")),
    ("gc", ("gc thread", "gc ", "g1 ", "gc#")),
)


def label_for(cmd):
    """What to call a process, from its command line. None when it is not worth a name."""
    low = " " + cmd.lower() + " "
    # The game first: its command line carries the launcher's own paths and brand, so
    # the launcher's name appears there too.
    if ("net.minecraft" in low or "neoforge" in low or "minecraft.client" in low
            or "-dminecraft" in low):
        return "minecraft"
    if "prismlauncher" in low or "prism launcher" in low:
        return "prism"
    if "x11vnc" in low:
        return "x11vnc"
    if "xvfb" in low:
        return "Xvfb"
    if "websockify" in low:
        return "websockify"
    if "mouseproxy" in low:
        return "mouseproxy"
    if "fpswatch" in low:
        return "fpswatch"
    if "cpuwatch" in low:
        return "cpuwatch"
    if "openbox" in low:
        return "openbox"
    if "dbus-daemon" in low:
        return "dbus"
    return None


def thread_group(name):
    low = (name or "").strip().lower()
    for group, needles in THREAD_GROUPS:
        if any(needle in low for needle in needles):
            return group
    return "other"


def stat_ticks(path):
    """(name, utime + stime) from a /proc stat file, or (None, None).

    The name is in parentheses and may itself contain spaces and parentheses, so the
    fields are split after the last ')' rather than by counting from the left.
    """
    try:
        with open(path, "rb") as handle:
            data = handle.read()
    except OSError:
        return None, None
    opened = data.find(b"(")
    closed = data.rfind(b")")
    if opened < 0 or closed <= opened:
        return None, None
    name = data[opened + 1:closed].decode("utf-8", "replace")
    try:
        fields = data[closed + 2:].split()
        # fields[0] is the state (field 3 of stat), so utime (14) and stime (15) are
        # at 11 and 12.
        return name, int(fields[11]) + int(fields[12])
    except (IndexError, ValueError):
        return None, None


def thread_ticks(pid):
    groups = {}
    try:
        tids = os.listdir("/proc/%d/task" % pid)
    except OSError:
        return groups
    for tid in tids:
        name, ticks = stat_ticks("/proc/%d/task/%s/stat" % (pid, tid))
        if ticks is None:
            continue
        group = thread_group(name)
        groups[group] = groups.get(group, 0) + ticks
    return groups


def snapshot():
    """Per-process CPU ticks, and the game's per-thread ticks when it is up."""
    processes = {}
    game_pid = 0
    for entry in os.listdir("/proc"):
        if not entry.isdigit():
            continue
        pid = int(entry)
        if pid == SELF:
            continue
        _, ticks = stat_ticks("/proc/%d/stat" % pid)
        if ticks is None:
            continue
        try:
            with open("/proc/%d/cmdline" % pid, "rb") as handle:
                cmd = handle.read().replace(b"\0", b" ").decode("utf-8", "replace")
        except OSError:
            continue
        if not cmd.strip():
            continue  # kernel threads, and processes already exiting
        label = label_for(cmd) or "other"
        processes[label] = processes.get(label, 0) + ticks
        if label == "minecraft":
            game_pid = pid
    return processes, thread_ticks(game_pid) if game_pid else {}


def throttle_stat():
    """(periods, throttled) from the CPU controller, or None when it does not say.

    This is the number that decides what to do about a slow session: a container that
    is throttled for most of its periods is over the quota, and only less work helps.
    """
    for path in ("/sys/fs/cgroup/cpu.stat", "/sys/fs/cgroup/cpu/cpu.stat",
                 "/sys/fs/cgroup/cpu,cpuacct/cpu.stat"):
        values = {}
        try:
            with open(path, "r", encoding="utf-8") as handle:
                for line in handle:
                    key, _, value = line.partition(" ")
                    value = value.strip()
                    if value.isdigit():
                        values[key] = int(value)
        except OSError:
            continue
        if "nr_periods" in values and "nr_throttled" in values:
            return values["nr_periods"], values["nr_throttled"]
    return None


def delta(before, after):
    """Ticks gained by each key. A key that was not in the first snapshot gains 0."""
    changes = {}
    for key, value in after.items():
        gained = value - before.get(key, value)
        if gained > 0:
            changes[key] = gained
    return changes


def percent(ticks, seconds):
    return ticks * 100.0 / (HZ * seconds) if seconds > 0 else 0.0


def report(processes, threads, seconds, quota, throttling):
    total = sum(percent(ticks, seconds) for ticks in processes.values())
    line = "CloudPC: cpu -- %.0f%% of one core, quota %d%% (%.0f%% of it)" % (
        total, quota, 100.0 * total / quota if quota > 0 else 0.0)
    if throttling is not None:
        periods, throttled = throttling
        if periods > 0:
            line += ", throttled %.0f%% of periods" % (100.0 * throttled / periods)
    parts = []
    for name, ticks in sorted(processes.items(), key=lambda item: -item[1]):
        share = percent(ticks, seconds)
        if share < 0.5:
            continue
        text = "%s %.0f%%" % (name, share)
        if name == "minecraft" and threads:
            details = []
            for group, group_ticks in sorted(threads.items(), key=lambda item: -item[1]):
                group_share = percent(group_ticks, seconds)
                if group_share < 0.5:
                    continue
                details.append("%s %.0f%%" % (group, group_share))
            if details:
                text += " (%s)" % ", ".join(details)
        parts.append(text)
    line += ": " + ", ".join(parts) if parts else ": nothing measurable"
    print(line, flush=True)


def main():
    try:
        quota = int(os.environ.get("CLOUDPC_CPU_PERCENT", "") or 100)
    except ValueError:
        quota = 100
    print("CloudPC: cpu breakdown every %.0fs; a line appears once something is spending "
          "CPU." % INTERVAL, flush=True)
    before = snapshot()
    throttling = throttle_stat()
    throttled_before = throttling
    start = time.monotonic()
    while True:
        time.sleep(INTERVAL)
        after = snapshot()
        throttling = throttle_stat()
        elapsed = time.monotonic() - start
        processes = delta(before[0], after[0])
        threads = delta(before[1], after[1])
        if "minecraft" in after[0] or percent(sum(processes.values()), elapsed) >= 10:
            report(processes, threads, elapsed, quota,
                   None if throttling is None or throttled_before is None else (
                       throttling[0] - throttled_before[0],
                       throttling[1] - throttled_before[1]))
        before = after
        throttled_before = throttling
        start = time.monotonic()


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        sys.exit(0)
