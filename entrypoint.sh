#!/usr/bin/env bash
set -Eeuo pipefail

: "${NOVNC_PORT:=8080}"
# The port the app exposes belongs to mouseproxy.py: it serves noVNC's files, speaks
# the RFB websocket to x11vnc directly, and injects the pointer motion and the clicks
# the overlays need. websockify used to sit behind it and is gone; the proxy's start
# below says why.
: "${VNC_PORT:=5900}"
: "${SCREEN_WIDTH:=800}"
: "${SCREEN_HEIGHT:=500}"
: "${SCREEN_DEPTH:=24}"
# The browser takes the last stage of the pipeline (the upscale and the sharpening,
# in index.html's WebGPU pass), so the container no longer has to shade and encode
# every pixel at desktop size to keep the picture acceptable. PIXEL_OFFLOAD=1 or 2
# picks a smaller framebuffer — 36% and 59% fewer pixels for llvmpipe to shade and
# for x11vnc to read and JPEG — but only while SCREEN_WIDTH/SCREEN_HEIGHT still hold
# the shipped 800x500, so an explicit resolution always wins over the preset.
case "${PIXEL_OFFLOAD:-0}" in
  1) OFFLOAD_WIDTH=640 OFFLOAD_HEIGHT=400 ;;
  2) OFFLOAD_WIDTH=512 OFFLOAD_HEIGHT=320 ;;
  *) OFFLOAD_WIDTH="" OFFLOAD_HEIGHT="" ;;
esac
if [[ -n "$OFFLOAD_WIDTH" && "$SCREEN_WIDTH" = "800" && "$SCREEN_HEIGHT" = "500" ]]; then
  SCREEN_WIDTH="$OFFLOAD_WIDTH"
  SCREEN_HEIGHT="$OFFLOAD_HEIGHT"
  echo "CloudPC: PIXEL_OFFLOAD=${PIXEL_OFFLOAD} -- desktop ${SCREEN_WIDTH}x${SCREEN_HEIGHT}, the device upscales it."
fi
unset OFFLOAD_WIDTH OFFLOAD_HEIGHT

# Desktop left visible around every window, and the titlebar openbox puts above it.
# Both are in X pixels: they are the room a window leaves the desktop so its edges
# and its titlebar stay visible and reachable on a touch screen.
: "${WINDOW_MARGIN:=8}"
: "${WINDOW_TITLEBAR:=24}"

# Qt and GTK draw at 100% of the pixels they are given, so the layout that fills an
# 800x500 desktop fills 40% of the area at 512x320, and a dialog that just fits at
# 800x500 hangs off the smaller screen. Scaling the toolkit UI by the same fraction
# of the screen keeps the layout a user already knows at every framebuffer size; the
# device upscales the stream, so the smaller text still arrives legible.
: "${UI_SCALE:=$(awk -v w="$SCREEN_WIDTH" -v h="$SCREEN_HEIGHT" \
  'BEGIN { s = w / 800; if (h / 500 < s) s = h / 500; if (s > 1) s = 1; printf "%.2f", s }')}"
: "${JAVA_MIN_RAM:=512M}"
: "${JAVA_MAX_RAM:=1536M}"
# Seconds between the per-process CPU lines in the log; see cpuwatch.py.
: "${CPU_LOG_INTERVAL:=30}"
# Desktop on top of X: `lite` is openbox plus the launcher (no panel, no wallpaper
# daemon, no settings daemons), `xfce` is the full session. SESSION=xfce gets the
# old desktop back.
: "${SESSION:=lite}"
# How long x11vnc sleeps between framebuffer polls and how long it batches damage
# before encoding. Saving CPU here costs a few milliseconds of stream latency, and
# what the encoder can afford depends on how many pixels the stream carries and how
# many cores the container has, so both are set with those below instead of here.

# glibc gives every thread its own malloc arena (8 x cores of 64 MB mappings). On
# a one-core container with Java, Mesa and GTK all allocating, capping the arenas
# keeps RSS down and the page faults with it. It must not cap them so far that
# threads meant to run beside each other queue on one malloc lock, though — two
# arenas for a render thread, three raster workers, chunk builders and two GC
# workers is how a multi-core game still behaves like a one-core one — so the
# number is set below from the CPU budget instead of here.

# Minecraft has no GPU here: it draws through Mesa's llvmpipe CPU rasteriser.
# llvmpipe starts one worker per core and takes that count from the host machine,
# not from the container's CPU quota, so a ~1 CPU app ends up with dozens of
# threads fighting over one core. Pin it to the quota, and keep the LLVM-compiled
# shader cache on /data so Minecraft does not recompile every shader each boot.
# The quota is read once, here, and every rule below works from these two numbers.
# CPU_CORE_COUNT is how many threads' worth of work the container can actually run:
# the quota rounded up — 125% still funds a whole second thread's worth above one
# core — then capped by the CPUs it is allowed to be scheduled on. CPU_QUOTA_PERCENT
# is the same quota as a percentage of one core, and that is what the question "is
# there a second core to put this thread on" is actually asking. Parsing the file
# twice is how those answers drifted: 125% rounded to two cores, so Mesa's GL
# dispatch thread was put on a core that does not exist.
CPU_QUOTA_UNSPENDABLE=0
CPU_QUOTA_CORES=""
CPU_PERIOD_MS=""
cgroup_cpu_quota() {
  local quota="" period=""
  # Which CPUs the container may run on at all, quota or not. sched_getaffinity is
  # what nproc reports and it is the hard edge: no amount of cgroup quota gets a
  # thread scheduled on a CPU outside this set.
  CPU_AVAILABLE_CPUS="$(nproc 2>/dev/null || echo 1)"
  if ! [[ "$CPU_AVAILABLE_CPUS" =~ ^[1-9][0-9]*$ ]]; then CPU_AVAILABLE_CPUS=1; fi
  if [[ -r /sys/fs/cgroup/cpu.max ]]; then
    read -r quota period < /sys/fs/cgroup/cpu.max || true
  fi
  if [[ ! "$quota" =~ ^[0-9]+$ ]]; then
    # v2 has no numeric quota ("max"), or there is no v2 file at all.
    quota="" period=""
    if [[ -r /sys/fs/cgroup/cpu/cpu.cfs_quota_us && -r /sys/fs/cgroup/cpu/cpu.cfs_period_us ]]; then
      read -r quota < /sys/fs/cgroup/cpu/cpu.cfs_quota_us || true
      read -r period < /sys/fs/cgroup/cpu/cpu.cfs_period_us || true
    fi
  fi
  if [[ "$quota" =~ ^[0-9]+$ ]] && (( quota > 0 )) \
     && [[ "${period:-0}" =~ ^[0-9]+$ ]] && (( period > 0 )); then
    CPU_QUOTA_PERCENT=$(( quota * 100 / period ))
    if (( CPU_QUOTA_PERCENT < 1 )); then CPU_QUOTA_PERCENT=1; fi
    # The period is the other half of the quota: a container is frozen for the rest
    # of its period when it spends the quota, so a long period turns an over-budget
    # session into long freezes rather than short stutters. It is in the log so that
    # "smooth, then frozen, repeating" can be told apart from a game-side stall.
    CPU_PERIOD_MS=$(( period / 1000 ))
    CPU_QUOTA_CORES=$(( (quota + period - 1) / period ))
    CPU_CORE_COUNT="$CPU_QUOTA_CORES"
    # Quota above the allowed CPU set cannot be spent. This is the difference
    # between a 300% allocation and three cores: a container pinned to one CPU can
    # only take turns, and sizing the JVM and llvmpipe for three would put every
    # worker it has on that one CPU. Cap the thread counts at what can run, and
    # report the gap instead of pretending the quota is usable.
    if (( CPU_CORE_COUNT > CPU_AVAILABLE_CPUS )); then
      CPU_CORE_COUNT="$CPU_AVAILABLE_CPUS"
      CPU_QUOTA_UNSPENDABLE=1
    fi
    return 0
  fi
  # No quota: the whole CPU set, which is also what llvmpipe would have assumed.
  CPU_CORE_COUNT="$CPU_AVAILABLE_CPUS"
  CPU_QUOTA_PERCENT=$(( CPU_CORE_COUNT * 100 ))
}
cgroup_cpu_quota

MALLOC_ARENA_MAX="${MALLOC_ARENA_MAX:-$(( CPU_CORE_COUNT >= 3 ? 4 : 2 ))}"
export MALLOC_ARENA_MAX

# The app's CPU setting can be a quota, a CPU set, or both. When the quota is the
# bigger of the two, Minecraft's threads have nowhere to run beside each other and
# the app looks like it is using one core however much CPU it was given — which is
# not something this image can fix, only something it can name.
if (( CPU_QUOTA_UNSPENDABLE == 1 )); then
  CPU_ALLOWED_LIST="$(sed -n 's/^Cpus_allowed_list:[[:space:]]*//p' /proc/self/status 2>/dev/null | head -n1 || true)"
  echo "WARNING: the cgroup allows ${CPU_QUOTA_CORES} CPU(s) of quota (${CPU_QUOTA_PERCENT}%), but this container may only run on ${CPU_AVAILABLE_CPUS} CPU(s) (Cpus_allowed_list ${CPU_ALLOWED_LIST:-unknown}). The extra quota cannot be used: raise the app's CPU allocation so it includes more than one CPU, not just a larger percentage. Sizing for ${CPU_CORE_COUNT}."
fi

LP_NUM_THREADS="${LP_NUM_THREADS:-$CPU_CORE_COUNT}"
if ! [[ "${LP_NUM_THREADS:-}" =~ ^[1-9][0-9]*$ ]]; then
  LP_NUM_THREADS=1
fi
MESA_SHADER_CACHE_DIR="${MESA_SHADER_CACHE_DIR:-/data/.cache/mesa}"
MESA_SHADER_CACHE_MAX_SIZE="${MESA_SHADER_CACHE_MAX_SIZE:-512M}"
export LP_NUM_THREADS MESA_SHADER_CACHE_DIR MESA_SHADER_CACHE_MAX_SIZE

# Driver-level knobs that cost nothing: never wait for a display refresh (the swap only
# feeds a framebuffer that x11vnc reads, and Minecraft already runs with vsync off),
# leave Mesa's shader cache alone so the LLVM JIT does not rebuild programs it has
# already compiled, and skip GL error bookkeeping. MESA_NO_ERROR drops the per-call
# error state tracking in the driver, which on a CPU rasteriser is pure overhead: the
# only consumer is Minecraft, and a GL error it does not check is not reported either
# way. Nothing here changes a pixel.
export vblank_mode=0 MESA_SHADER_CACHE_DISABLE=false MESA_NO_ERROR=1
# Name the fast software rasteriser instead of letting Mesa choose: when it cannot
# prove the pixels are aligned it falls back to softpipe, which is several times
# slower, and "the desktop is suddenly unusable" would then have no visible cause.
# With a render node present the real driver is left alone.
if [[ ! -e /dev/dri/renderD128 && ! -e /dev/dri/card0 && -z "${GALLIUM_DRIVER:-}" ]]; then
  export GALLIUM_DRIVER=llvmpipe
fi
# Mesa's threaded GL dispatch moves the OpenGL command stream onto a second thread,
# which is where Minecraft's ~30% on Mesa drivers comes from. It needs a second core
# to land on: on one core the extra thread only adds hand-offs, so it is on by default
# where the cgroup really allows two, off below that. The test is the raw quota rather
# than the rounded thread count, because a 125% allocation rounds up to two raster
# threads — which is right, those threads share the whole quota while the render thread
# is blocked in a draw — but it is not a second core for a thread that has to run
# *alongside* the game. GLTHREAD=1 forces it on and GLTHREAD=0 forces it off.
GLTHREAD="${GLTHREAD:-auto}"
if [[ "$GLTHREAD" == "auto" ]]; then
  if (( CPU_QUOTA_PERCENT >= 175 && CPU_CORE_COUNT >= 2 )); then GLTHREAD=1; else GLTHREAD=0; fi
fi
if [[ "$GLTHREAD" == "1" ]]; then
  export mesa_glthread=true
  echo "CloudPC: Mesa threaded GL dispatch on (GLTHREAD=1)."
else
  echo "CloudPC: Mesa threaded GL dispatch off: ${CPU_QUOTA_PERCENT}% of a core across ${CPU_CORE_COUNT} allowed CPU(s) is not a second core to put it on (GLTHREAD=1 forces it on)."
fi

CPU_BUDGET="$CPU_CORE_COUNT"

# ---------------------------------------------------------------------------
# The JVM heap is sized from the container's memory, not from a fixed number
#
# Minecraft's process is more than its Java heap: metaspace, the code cache, GC
# structures, thread stacks, LWJGL and NeoForge's native buffers, and Mesa's
# llvmpipe framebuffers all live outside it, and Xvfb, x11vnc, the proxy and
# Prism live outside the JVM. So the heap ceiling is a share of the cgroup's
# memory limit with room left for everything else, not the whole allocation.
# The app platforms enforce RAM with that limit; without one there is nothing to
# size against and the shipped heap stays. A sentinel-sized "unlimited" value is
# ignored the same way.
MEM_LIMIT_MB=0
cgroup_memory_limit_mb() {
  local bytes=""
  if [[ -r /sys/fs/cgroup/memory.max ]]; then
    read -r bytes < /sys/fs/cgroup/memory.max || true
  fi
  if [[ ! "$bytes" =~ ^[0-9]+$ ]]; then
    # v2 with no numeric limit ("max"), or no v2 file at all.
    bytes=""
    if [[ -r /sys/fs/cgroup/memory/memory.limit_in_bytes ]]; then
      read -r bytes < /sys/fs/cgroup/memory/memory.limit_in_bytes || true
    fi
  fi
  [[ "$bytes" =~ ^[0-9]+$ ]] || return 0
  # v1 reports "unlimited" as a huge sentinel near 2^63; anything above a
  # petabyte is no limit at all, and anything below 64 MiB is not a session.
  if (( bytes < 67108864 || bytes > 1125899906842624 )); then return 0; fi
  MEM_LIMIT_MB=$(( bytes / 1048576 ))
}
cgroup_memory_limit_mb

# Two thirds of the limit, rounded down to a whole 256 MiB, capped at 4096. The
# documented 4 GB floor lands exactly on the 2560 MiB this image used to hard-code;
# 6 GB lands on 4096 MiB; more than that does not need any more heap for this scene.
# The starting heap stays modest: growth is cheap, and a young generation sized for
# a heap that is never filled only makes Serial's pauses longer.
HEAP_MAX_MB=2560
HEAP_MIN_MB=1024
if (( MEM_LIMIT_MB > 0 )); then
  HEAP_MAX_MB=$(( MEM_LIMIT_MB * 2 / 3 / 256 * 256 ))
  if (( HEAP_MAX_MB > 4096 )); then HEAP_MAX_MB=4096; fi
  if (( HEAP_MAX_MB < 1024 )); then HEAP_MAX_MB=1024; fi
  if (( HEAP_MAX_MB >= 4096 )); then HEAP_MIN_MB=2048; fi
  if (( HEAP_MIN_MB > HEAP_MAX_MB / 2 )); then HEAP_MIN_MB=$(( HEAP_MAX_MB / 2 )); fi
  MEM_LIMIT_LABEL="${MEM_LIMIT_MB} MiB"
  echo "CloudPC: ${MEM_LIMIT_MB} MiB of container memory -- Minecraft heap ${HEAP_MIN_MB}-${HEAP_MAX_MB} MiB, the rest is for the JVM's native memory and the session."
else
  MEM_LIMIT_LABEL="no cgroup limit"
  echo "CloudPC: no cgroup memory limit visible -- keeping the shipped Minecraft heap ${HEAP_MIN_MB}-${HEAP_MAX_MB} MiB."
fi

# ---------------------------------------------------------------------------
# The stream is a rectangle
#
# Every stage between the game and the device costs the same number of pixels, and
# they all run on this container's CPU: llvmpipe shades the HUD and blits the world
# onto the window, the driver copies the frame out, x11vnc reads the damaged
# rectangles, JPEGs them, and the proxy ships them. RenderScale already made the
# *world* cheap by drawing it at a third of the window, which is why the terrain is
# no longer what a frame costs; everything else still ran at the full 800x500, and
# that is 400,000 pixels of work per frame however small the world is.
#
# So the stream itself is now a rectangle. x11vnc's -clip sends exactly that
# sub-region as the VNC framebuffer, and the game window is sized to the same
# rectangle at 0,0, so the picture is all game and every stage above shrinks with
# it: at 50% the encoder reads, JPEGs and ships a quarter of the pixels. The device
# upscales what arrives (index.html's WebGPU stage), and the rectangle is not fixed:
# mouseproxy.py writes this file and asks the running x11vnc to re-clip through its
# remote-control channel, so the page can trade detail for frames without dropping
# the session. STREAM_SCALE=100 turns the whole thing off.
STREAM_FILE="${STREAM_FILE:-/data/.config/cloudpc-stream}"
# Where fpswatch.py publishes the game's own frame rate. A file, not a socket: the
# page reads it from mouseproxy, and nothing waits on the process that writes it.
FPS_FILE="${FPS_FILE:-/tmp/cloudpc-fps}"

# A container with one and a bit cores cannot afford to start at full size, and it is
# the worst place to start: every stage after the game draws runs on that same core,
# so the first seconds ask for the most pixels per frame the session will ever ask
# for. Start two steps down there, one step down at two cores, full size with cores
# to spare. Auto moves it either way; this only decides where it starts.
if (( CPU_BUDGET >= 3 )); then
  DEFAULT_STREAM_SCALE=100
elif (( CPU_BUDGET >= 2 )); then
  DEFAULT_STREAM_SCALE=80
else
  DEFAULT_STREAM_SCALE=62
fi

stream_scale() {
  local percent="${STREAM_SCALE:-}" digits
  if [[ -z "$percent" && -r "$STREAM_FILE" ]]; then
    digits="$(tr -cd '0-9' < "$STREAM_FILE" 2>/dev/null | head -c 3 || true)"
    percent="${digits:-}"
  fi
  if [[ ! "$percent" =~ ^[0-9]+$ ]]; then
    percent="$DEFAULT_STREAM_SCALE"
  fi
  if (( percent < 30 )); then percent=30; fi
  if (( percent > 100 )); then percent=100; fi
  echo "$percent"
}

# "W H" of the stream: even numbers, because JPEG chroma comes in pairs and the
# upscaler prefers them, and never smaller than a legible window.
stream_size() {
  local percent width height
  percent="$(stream_scale)"
  width=$(( SCREEN_WIDTH * percent / 100 / 2 * 2 ))
  height=$(( SCREEN_HEIGHT * percent / 100 / 2 * 2 ))
  if (( width < 128 )); then width=128; fi
  if (( height < 80 )); then height=80; fi
  echo "$width $height"
}

# The stream's own timing: how often x11vnc looks for damage, and how long it batches
# what it found before encoding. Both halves are dead time for the player — the picture
# is the only feedback the game gives — so both are as short as the budget allows. On
# one or two cores the encoder is a rival for the core the game renders on: full size
# keeps 46 ms, and a stream at 640x400 or below, four times less to read and encode,
# gets 28. At three cores that rivalry is gone, because the render thread and the
# raster workers run while x11vnc looks, so the poll is at its floor: 4 ms between
# looks, 6 ms of defer to put one frame's rectangles into a single encode.
# It went to 2/3 for one build and is back: damage arrives once per game frame, so a
# shorter poll does not make frames arrive sooner — it splits each one into more,
# smaller encodes, which is more bytes for the same picture, and a link that falls
# behind the encoder freezes the display while the socket drains. 4/6 is the smallest
# pair that has actually run smoothly on a tablet, and it is already half the 10/18
# this started at.
if (( CPU_BUDGET >= 3 )); then
  : "${VNC_WAIT:=4}"
  : "${VNC_DEFER:=6}"
elif (( $(stream_scale) <= 80 )); then
  : "${VNC_WAIT:=12}"
  : "${VNC_DEFER:=16}"
else
  : "${VNC_WAIT:=16}"
  : "${VNC_DEFER:=30}"
fi

mkdir -p /data/.vnc /data/.minecraft /data/.local/share/PrismLauncher \
         /data/.config /data/Desktop /data/Downloads "$MESA_SHADER_CACHE_DIR"
chown -R cloud:cloud /data

# Keep user data on the persistent /data mount.
for item in .minecraft .local .config Desktop Downloads; do
  if [[ ! -L "/home/cloud/$item" ]]; then
    rm -rf "/home/cloud/$item"
    ln -s "/data/$item" "/home/cloud/$item"
  fi
done
chown -h cloud:cloud /home/cloud/.minecraft /home/cloud/.local \
  /home/cloud/.config /home/cloud/Desktop /home/cloud/Downloads

# GLib/GTK and D-Bus expect a private runtime directory owned by the desktop
# user; without one they fall back to /tmp and log warnings.
XDG_RUNTIME_DIR="/run/user/$(id -u cloud)"
mkdir -p "$XDG_RUNTIME_DIR"
chown cloud:cloud "$XDG_RUNTIME_DIR"
chmod 700 "$XDG_RUNTIME_DIR"
export XDG_RUNTIME_DIR

# Prism Launcher is preinstalled in the image. Seed a ready-to-run instance and
# a one-tap desktop shortcut on first boot so the desktop needs no setup.
PRISM_DIR=/data/.local/share/PrismLauncher
INSTANCE_DIR="$PRISM_DIR/instances/Minecraft"
mkdir -p "$PRISM_DIR/instances"
if [[ ! -f "$INSTANCE_DIR/mmc-pack.json" ]]; then
  cp -a /opt/cloudpc/prism/instance "$INSTANCE_DIR"
fi

# Software rendering gets slower with every extra pixel, so the seeded instance
# opens in a small window. Prism writes OverrideWindow itself as soon as a window
# size is chosen in the launcher, and from then on these lines are left alone.
INSTANCE_CFG="$INSTANCE_DIR/instance.cfg"
if [[ -f "$INSTANCE_CFG" ]] && ! grep -q '^OverrideWindow=' "$INSTANCE_CFG"; then
  printf 'OverrideWindow=true\nMinecraftWinWidth=800\nMinecraftWinHeight=500\n' >> "$INSTANCE_CFG"
fi

# The seeded instance starts fullscreen so the stream is all game and every pixel
# the encoder sends is one Minecraft drew. Mouse look does not depend on it any
# more -- the look pad sends relative motion (see mouseproxy.py), which works in a
# window too -- so this is about the picture, not the controls. Flipped once, with
# a marker, so turning fullscreen off in game (F11) stays off.
INSTANCE_OPTIONS="$INSTANCE_DIR/options.txt"
FULLSCREEN_MARKER=/data/.local/share/.cloudpc-fullscreen
if [[ -f "$INSTANCE_OPTIONS" && ! -e "$FULLSCREEN_MARKER" ]]; then
  if grep -qx 'fullscreen:false' "$INSTANCE_OPTIONS"; then
    sed -i 's/^fullscreen:false$/fullscreen:true/' "$INSTANCE_OPTIONS"
    echo "CloudPC: Minecraft set to fullscreen so the stream is all game"
  fi
  : > "$FULLSCREEN_MARKER"
fi

# Move earlier presets forward. Each key is only rewritten while it still holds
# exactly the value we shipped, so anything the user picked in Prism is kept.
set_instance_default() {
  local key="$1" from="$2" to="$3"
  if grep -qx "${key}=${from}" "$INSTANCE_CFG"; then
    sed -i "s/^${key}=${from}\$/${key}=${to}/" "$INSTANCE_CFG"
    echo "CloudPC: instance default ${key} ${from} -> ${to}"
  fi
}
# The heap was sized above from the container's memory limit. Only values this
# image shipped are moved: 512/1024/2048 MiB for the minimum and 1536/2560 MiB for
# the maximum. A number picked in Prism is left alone, the same rule as the JVM
# arguments; 4096 is deliberately not in the list because the README suggests it
# as a manual choice, so a heap the user set must stay where it is.
set_instance_heap() {
  local key="$1" value="$2" current allowed
  [[ -f "$INSTANCE_CFG" ]] || return 0
  current="$(sed -n "s/^${key}=//p" "$INSTANCE_CFG" | tail -n 1)"
  [[ -n "$current" && "$current" != "$value" ]] || return 0
  case "$key" in
    MinMemAlloc) allowed=" 512 1024 2048 " ;;
    MaxMemAlloc) allowed=" 1536 2560 " ;;
    *) return 0 ;;
  esac
  [[ "$allowed" == *" $current "* ]] || return 0
  sed -i "s/^${key}=${current}\$/${key}=${value}/" "$INSTANCE_CFG"
  echo "CloudPC: instance heap ${key} ${current} -> ${value} MiB"
}
set_instance_heap MinMemAlloc "$HEAP_MIN_MB"
set_instance_heap MaxMemAlloc "$HEAP_MAX_MB"
# The desktop is 800x500: every pixel is shaded on the CPU and then encoded for
# the browser, which upscales the stream to the device. That is 61% of the pixels of
# the old 1024x640 desktop, at the same 16:10 shape, so nothing has to be re-laid-out.
# A windowed game is fitted to the same size; a size chosen in Prism is left alone.
set_instance_default MinecraftWinWidth 960 800
set_instance_default MinecraftWinHeight 540 500
set_instance_default MinecraftWinHeight 450 500

# The JVM is the other process that has to fit in this container's budget. Prism
# leaves it on G1, whose concurrent marking, refinement threads and per-store
# barrier are all extra work that has to be squeezed into the core the game is
# drawing on. Below about two cores a stop-the-world Serial GC is faster: one
# collection pass, no background threads, a pointer-bump allocator and no barrier.
# G1 was tried at three cores — a 10 ms pause target and two collection workers, to
# keep the pause on the thread that reads input in single digits — and it is not
# worth it here. On a 2.5 GiB NeoForge heap that allocates faster than a quota-bound
# container can fund the collection, the collector becomes the stall: the session
# ran smoothly for about half a second and then froze for about half a second, which
# is G1 falling behind its own allocation rate and repeatedly catching up. Serial's
# young pauses are shorter at this heap size than they look, and, more importantly,
# they are bounded — the collector can never end up competing with the rasteriser
# for the quota for hundreds of milliseconds at a time. So the client stays on
# Serial GC at every size, and the extra cores go to the rasteriser and the game's
# own background pools instead (see ActiveProcessorCount below).
# The remaining flags are container wins: stop writing the perf counters through a
# memory-mapped file, and cap the JIT compilers at two so a host with dozens of
# cores cannot fill this container with compiler threads.
# The JVM sizes every pool it has from the host's core count, not from the cgroup
# quota: on an eight-core host this container's Minecraft got a background executor,
# a ForkJoin pool, Sodium's chunk builders and a dozen idling threads all sized for
# eight cores, and all of them fighting for the cores it actually gets.
# -XX:ActiveProcessorCount tells the JVM the truth, so every one of those pools, and
# Runtime.availableProcessors() that the mods read, matches the CPU the container is
# allowed — including the case where the quota is large but the allowed CPU set is
# not.
JAVA_CPUS="$CPU_BUDGET"
if (( JAVA_CPUS < 1 )); then JAVA_CPUS=1; fi
if (( JAVA_CPUS > 16 )); then JAVA_CPUS=16; fi
GC_NAME="Serial GC"
CLOUDPC_JVM_ARGS="-XX:+UseSerialGC -XX:+PerfDisableSharedMem -XX:CICompilerCount=2 -XX:ActiveProcessorCount=${JAVA_CPUS}"

# Prism records "use the defaults" as OverrideJavaArgs=false, so that is the only
# state that gets taken over. After that the args are ours until someone types their
# own into Prism -- and those are recognised by not being the preset we wrote, so a
# preset from an older build of this image is moved forward on the next boot while a
# value the user chose is never touched.
prism_jvm_args() {
  local cfg="$1" current
  [[ -f "$cfg" ]] || return 1
  if grep -qx 'OverrideJavaArgs=false' "$cfg"; then
    sed -i 's/^OverrideJavaArgs=false$/OverrideJavaArgs=true/' "$cfg"
  elif ! grep -q '^OverrideJavaArgs=' "$cfg"; then
    printf 'OverrideJavaArgs=true\n' >> "$cfg"
  elif ! grep -qx 'OverrideJavaArgs=true' "$cfg"; then
    return 1
  fi
  current="$(sed -n 's/^JvmArgs=//p' "$cfg" | tail -n 1)"
  # Ours is either preset: the Serial one this build writes, or the G1 one the build
  # before it wrote, which has to be moved back. A value the user typed themselves is
  # recognised by starting with neither collector flag.
  if [[ -n "$current" && "$current" != -XX:+UseSerialGC* && "$current" != -XX:+UseG1GC* ]]; then
    return 1
  fi
  if [[ "$current" == "$CLOUDPC_JVM_ARGS" ]]; then
    return 1
  fi
  if grep -q '^JvmArgs=' "$cfg"; then
    sed -i "s|^JvmArgs=.*\$|JvmArgs=${CLOUDPC_JVM_ARGS}|" "$cfg"
  else
    printf 'JvmArgs=%s\n' "$CLOUDPC_JVM_ARGS" >> "$cfg"
  fi
  echo "CloudPC: Minecraft JVM args set for ${JAVA_CPUS} CPU core(s) (${GC_NAME}, APCount, 2 JIT threads)"
  return 0
}
if [[ -f "$INSTANCE_CFG" ]]; then
  prism_jvm_args "$INSTANCE_CFG" || true
fi

# Same idea for options.txt: terrain shading dominates the frame cost, so the
# seeded view and simulation radius stay small. Both are in-game sliders.
set_options_default() {
  local key="$1" from="$2" to="$3"
  [[ -f "$INSTANCE_OPTIONS" ]] || return 0
  if grep -qx "${key}:${from}" "$INSTANCE_OPTIONS"; then
    sed -i "s/^${key}:${from}\$/${key}:${to}/" "$INSTANCE_OPTIONS"
    echo "CloudPC: option default ${key} ${from} -> ${to}"
  fi
}
set_options_default renderDistance 4 3
set_options_default simulationDistance 5 4
# Ticking is the other half of the frame: with a 3-chunk view, four chunks of
# simulation is the same world twice over. Three keeps every block in view ticking
# and drops the ones that were only being simulated behind the player.
set_options_default simulationDistance 4 3
# The stream ships about 20 updates a second, so 30 fps is already more than the
# picture can show. An uncapped menu, sky or paused game is the cheapest place to
# hand a core back to the encoder and to everything else on the box.
set_options_default maxFps 60 30
# The HUD is laid out in "GUI pixels" and the scale is pinned here, so a fixed 2 at a
# 240x150 stream draws a hotbar wider than the window. 0 is Minecraft's Auto, which
# picks the largest scale that fits: 2 at full size, 1 once the Detail control has
# shrunk the window below 640x480, and back up when it grows.
set_options_default guiScale 2 0
# View and simulation distance are the two settings that trade the most frame time
# for the least code, so they can be set from the app's environment instead of from
# the in-game sliders: every chunk inside the view is meshed and drawn on this one
# core, and going from radius 3 to 2 removes 24 of the 49 chunks. Only an explicit
# value is written, so an environment without them leaves the sliders alone.
set_option_value() {
  local key="$1" value="$2"
  [[ -f "$INSTANCE_OPTIONS" ]] || return 0
  if grep -q "^${key}:" "$INSTANCE_OPTIONS"; then
    sed -i "s/^${key}:.*\$/${key}:${value}/" "$INSTANCE_OPTIONS"
  else
    printf '%s:%s\n' "$key" "$value" >> "$INSTANCE_OPTIONS"
  fi
  echo "CloudPC: option ${key}:${value} from the environment"
}
if [[ "${RENDER_DISTANCE:-}" =~ ^[0-9]+$ ]] && (( RENDER_DISTANCE >= 2 && RENDER_DISTANCE <= 32 )); then
  set_option_value renderDistance "$RENDER_DISTANCE"
fi
if [[ "${SIMULATION_DISTANCE:-}" =~ ^[0-9]+$ ]] && (( SIMULATION_DISTANCE >= 3 && SIMULATION_DISTANCE <= 32 )); then
  set_option_value simulationDistance "$SIMULATION_DISTANCE"
fi

# Options that only add per-frame work and that an older options.txt does not
# contain at all. Each is written once and then belongs to the game: a key that is
# already there, including a value chosen with the in-game sliders, is left alone.
add_options_default() {
  local key="$1" value="$2"
  [[ -f "$INSTANCE_OPTIONS" ]] || return 0
  if ! grep -q "^${key}:" "$INSTANCE_OPTIONS"; then
    printf '%s:%s\n' "$key" "$value" >> "$INSTANCE_OPTIONS"
    echo "CloudPC: option added ${key}:${value}"
  fi
}
# Entities stop being drawn beyond half the normal range -- visible only when many
# are in view at once -- and biome colours are blended per block unless this is 0.
add_options_default entityDistanceScaling 0.5
add_options_default biomeBlendRadius 0
# Minecraft writes every chunk it unloads, and every player-data change, with a fsync
# by default, which on a mounted volume is a stall a tick cannot hide. Nothing here
# is crash-safe by contract: the world is a game, and a lost second of it after a
# hard kill costs less than the hitch every autosave puts in the frame the player is
# looking at. A key that is already there, including one set by hand, is untouched.
add_options_default syncChunkWrites false

# Every pixel of the Minecraft window is shaded on the CPU, so the seeded instance
# draws the world at half resolution and upscales it: a quarter of the pixels for
# the terrain, with the HUD still drawn at full size. RENDERSCALE=0 leaves the
# instance's mods untouched for a clean unmodded test.
INSTANCE_MODS="$INSTANCE_DIR/.minecraft/mods"
RENDERSCALE_CONFIG="$INSTANCE_DIR/.minecraft/config/renderscale.json"

# RenderScale 1.3.6 is a NeoForge 1.21.11 build. Loading it into anything else is a
# mod-loading failure that stops Minecraft from starting, so check first.
mods_compatible() {
  python3 - "$1/mmc-pack.json" <<'PY'
import json, sys
try:
    components = json.load(open(sys.argv[1])).get("components", [])
except (OSError, ValueError):
    sys.exit(1)
minecraft = [c.get("version", "") for c in components if c.get("uid") == "net.minecraft"]
neoforge = next((c.get("version", "") for c in components
                 if c.get("uid") in ("net.neoforged", "net.neoforged.neoforge")), "")
if minecraft[:1] != ["1.21.11"] or not neoforge:
    sys.exit(1)
try:
    parts = [int(p) for p in neoforge.split("-")[0].split(".")[:3]]
except ValueError:
    sys.exit(1)
sys.exit(0 if parts >= [21, 11, 6] else 1)
PY
}

mod_present() {
  [[ -d "$1" ]] || return 1
  find "$1" -maxdepth 1 -iname "$2*.jar" -print -quit | grep -q .
}

install_mods() {
  local instance="$1" mods="$1/.minecraft/mods" config="$1/.minecraft/config/renderscale.json" jar base name
  name="$(basename "$instance")"
  mkdir -p "$mods" "$(dirname "$config")"
  for jar in /opt/cloudpc/mods/*.jar; do
    [[ -e "$jar" ]] || continue
    base="$(basename "$jar")"
    # NeoForge refuses to start with two jars of one mod id, so never add a
    # second build of something the instance already has.
    if mod_present "$mods" "${base%%-[0-9]*}"; then
      echo "CloudPC: ${name} already has a ${base%%-[0-9]*} jar, leaving it alone."
      continue
    fi
    cp "$jar" "$mods/$base"
    echo "CloudPC: added $base to ${name}"
  done
  if [[ ! -e "$config" ]]; then
    printf '{\n  "scale": 0.33,\n  "forceLinear": false,\n  "irisScale": -1.0\n}\n' > "$config"
    echo "CloudPC: RenderScale preset to 0.33 for ${name}"
  fi
  # The preset is 0.33: the game is fullscreen at 800x500, so the world is shaded at
  # roughly 264x165, about 43,000 pixels, well below the 90,000 the original
  # 800x450 window cost at 0.5. Only a config that is still exactly what CloudPC
  # wrote is moved; any other value is a factor the user
  # picked in Mods -> RenderScale -> Config and stays as it is.
  if [[ -f "$config" ]]; then
    python3 - "$config" <<'PY'
import json, sys
path = sys.argv[1]
try:
    data = json.load(open(path))
except (OSError, ValueError):
    raise SystemExit(0)
ours = (
    isinstance(data, dict)
    and set(data) == {"scale", "forceLinear", "irisScale"}
    and data["forceLinear"] is False
    and data["irisScale"] == -1.0
    and data["scale"] in (0.5, 0.4)
)
if ours:
    data["scale"] = 0.33
    with open(path, "w") as handle:
        json.dump(data, handle, indent=2)
    print("CloudPC: RenderScale preset moved to 0.33")
PY
  fi
}

if [[ "${MODS:-1}" = "0" || "${RENDERSCALE:-1}" = "0" ]]; then
  echo "CloudPC: mods disabled (MODS=0 or RENDERSCALE=0), leaving the instances untouched."
elif [[ ! -d /opt/cloudpc/mods ]]; then
  echo "CloudPC: the image has no pinned performance mods, leaving the instances untouched."
else
  # Any instance that can load the builds gets them, not just the seeded one.
  for instance in "$PRISM_DIR"/instances/*/; do
    instance="${instance%/}"
    [[ -f "$instance/mmc-pack.json" ]] || continue
    if mods_compatible "$instance"; then
      install_mods "$instance"
    else
      echo "CloudPC: $(basename "$instance") is not NeoForge 1.21.11, not adding the performance mods to it."
    fi
  done
fi

if [[ ! -f "/data/Desktop/Prism Launcher.desktop" ]]; then
  cp /opt/cloudpc/prism/PrismLauncher.desktop "/data/Desktop/Prism Launcher.desktop"
fi
chmod +x "/data/Desktop/Prism Launcher.desktop"
chown -R cloud:cloud "$PRISM_DIR" /data/Desktop

# VNC password: VNC_PASSWORD wins, otherwise the password already stored on the
# persistent /data mount is reused, otherwise one is generated once and logged.
# RFB truncates VNC passwords to 8 characters, which is a protocol limitation.
VNC_PASSWD_FILE=/data/.vnc/passwd
mkdir -p /data/.vnc
if [[ -n "${VNC_PASSWORD:-}" ]]; then
  runuser -u cloud -- env HOME=/home/cloud \
    x11vnc -storepasswd "$VNC_PASSWORD" "$VNC_PASSWD_FILE" >/dev/null
  echo "CloudPC: VNC password set from VNC_PASSWORD (stored in ${VNC_PASSWD_FILE})."
elif [[ -s "$VNC_PASSWD_FILE" ]]; then
  echo "CloudPC: using the existing VNC password stored in ${VNC_PASSWD_FILE}."
else
  GENERATED_VNC_PASSWORD="$(head -c 96 /dev/urandom | tr -dc 'A-Za-z0-9' | cut -c1-8)"
  runuser -u cloud -- env HOME=/home/cloud \
    x11vnc -storepasswd "$GENERATED_VNC_PASSWORD" "$VNC_PASSWD_FILE" >/dev/null
  echo "CloudPC: generated VNC password (shown once): ${GENERATED_VNC_PASSWORD}"
  echo "CloudPC: set VNC_PASSWORD to choose your own password instead."
fi
chown cloud:cloud "$VNC_PASSWD_FILE"

cat > /data/.config/cloudpc-env <<EOF
JAVA_MIN_RAM=${JAVA_MIN_RAM}
JAVA_MAX_RAM=${JAVA_MAX_RAM}
EOF
chown cloud:cloud /data/.config/cloudpc-env

XVFB_PID=""
DBUS_PID=""
DESKTOP_PID=""
PRISM_PID=""
FIT_WINDOWS_PID=""
FIT_PID=""
VNC_PID=""
PROXY_PID=""
cleanup() {
  trap - EXIT INT TERM
  for pid in "$PROXY_PID" "$VNC_PID" "$FIT_WINDOWS_PID" "$FIT_PID" "$PRISM_PID" "$DESKTOP_PID" "$DBUS_PID" "$XVFB_PID"; do
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
      kill "$pid" 2>/dev/null || true
    fi
  done
  wait 2>/dev/null || true
}
trap cleanup EXIT INT TERM

echo "CloudPC: preparing X11 socket directory..."
chmod 1777 /tmp
mkdir -p /tmp/.X11-unix
chown root:root /tmp/.X11-unix
chmod 1777 /tmp/.X11-unix
rm -f /tmp/.X0-lock /tmp/.X11-unix/X0

# The X screen's current size, as "W H".
screen_size() {
  DISPLAY=:0 xdpyinfo 2>/dev/null \
    | awk '/dimensions:/ { split($2, d, "x"); print d[1], d[2]; exit }'
}

start_xvfb() {
  local width="$1" height="$2" attempt
  rm -f /tmp/.X0-lock /tmp/.X11-unix/X0
  runuser -u cloud -- env HOME=/home/cloud DISPLAY=:0 \
    Xvfb :0 -screen 0 "${width}x${height}x${SCREEN_DEPTH}" \
    -nolisten tcp -noreset -ac &
  XVFB_PID=$!
  for attempt in $(seq 1 60); do
    if ! kill -0 "$XVFB_PID" 2>/dev/null; then
      return 1
    fi
    if xdpyinfo -display :0 >/dev/null 2>&1; then
      return 0
    fi
    sleep 0.5
  done
  return 1
}

echo "CloudPC: starting virtual display ${SCREEN_WIDTH}x${SCREEN_HEIGHT}..."
if ! start_xvfb "$SCREEN_WIDTH" "$SCREEN_HEIGHT"; then
  echo "ERROR: Xvfb did not become ready."
  ps aux | grep '[X]vfb' || true
  exit 1
fi

# One line in the log that says what actually draws the desktop: a render node
# means hardware OpenGL, otherwise Mesa falls back to llvmpipe on the CPU.
if [[ -e /dev/dri/renderD128 || -e /dev/dri/card0 ]]; then
  echo "CloudPC: /dev/dri is present, Mesa may use hardware OpenGL."
else
  echo "CloudPC: no /dev/dri, OpenGL runs on llvmpipe (${LP_NUM_THREADS} thread(s))."
fi
GL_RENDERER_LINE="$(timeout 15 env DISPLAY=:0 glxinfo -B 2>/dev/null | grep -m1 'OpenGL renderer' || true)"
if [[ -n "$GL_RENDERER_LINE" ]]; then
  echo "CloudPC: ${GL_RENDERER_LINE#*: }"
fi

# One line with every number that decides how fast this session can be, so a slow
# desktop can be diagnosed from the log instead of guessed at. nproc is the CPUs the
# container may run on, not what the cgroup will fund, which is why llvmpipe's worker
# count comes from the budget and not from nproc alone.
read -r STREAM_WIDTH STREAM_HEIGHT < <(stream_size)
echo "CloudPC: performance -- ${CPU_BUDGET} CPU core(s) allowed (quota ${CPU_QUOTA_PERCENT}%${CPU_PERIOD_MS:+ over a ${CPU_PERIOD_MS} ms period}, nproc $(nproc)), llvmpipe ${LP_NUM_THREADS} thread(s), framebuffer ${SCREEN_WIDTH}x${SCREEN_HEIGHT} (PIXEL_OFFLOAD=${PIXEL_OFFLOAD:-0}, UI scale ${UI_SCALE}), stream ${STREAM_WIDTH}x${STREAM_HEIGHT} at $(stream_scale)% of it, ${VNC_WAIT}/${VNC_DEFER} ms, Minecraft on ${GC_NAME} with ${JAVA_CPUS} core(s), heap ${HEAP_MIN_MB}-${HEAP_MAX_MB} MiB of ${MEM_LIMIT_LABEL} RAM, view $(sed -n 's/^renderDistance://p' "$INSTANCE_OPTIONS" 2>/dev/null | head -n1)/sim $(sed -n 's/^simulationDistance://p' "$INSTANCE_OPTIONS" 2>/dev/null | head -n1)."
case "$GL_RENDERER_LINE" in
  *softpipe*)
    echo "WARNING: Mesa is on softpipe, which is several times slower than llvmpipe. Check that libgl1-mesa-dri is installed; GALLIUM_DRIVER=llvmpipe forces the fast rasteriser."
    ;;
esac

# Session bus on loopback TCP: on a unix socket GDBus always sends
# SCM_CREDENTIALS first, which sandboxed runtimes reject with EPERM. That is the
# "Unable to contact settings server ... Operation not permitted" dialog: xfconfd
# and xfsettingsd could never reach the bus. Over TCP no credentials are sent.
echo "CloudPC: starting session D-Bus on loopback TCP..."
DBUS_ADDRESS_FILE=/tmp/cloudpc-dbus-address
rm -f "$DBUS_ADDRESS_FILE"
: > "$DBUS_ADDRESS_FILE"
chown cloud:cloud "$DBUS_ADDRESS_FILE"
runuser -u cloud -- env HOME=/home/cloud DISPLAY=:0 \
  XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR" \
  dbus-daemon --config-file=/opt/cloudpc/dbus-session.conf \
  --nofork --print-address=1 >"$DBUS_ADDRESS_FILE" &
DBUS_PID=$!

DBUS_ADDRESS=""
for _ in $(seq 1 40); do
  if ! kill -0 "$DBUS_PID" 2>/dev/null; then
    echo "ERROR: dbus-daemon exited during startup."
    wait "$DBUS_PID" || true
    exit 1
  fi
  DBUS_ADDRESS="$(head -n1 "$DBUS_ADDRESS_FILE" 2>/dev/null || true)"
  if [[ "$DBUS_ADDRESS" == tcp:host=* ]]; then
    break
  fi
  DBUS_ADDRESS=""
  sleep 0.25
done
if [[ -z "$DBUS_ADDRESS" ]]; then
  echo "ERROR: dbus-daemon did not report a bus address."
  exit 1
fi
export DBUS_SESSION_BUS_ADDRESS="$DBUS_ADDRESS"
echo "CloudPC: session bus is listening (${DBUS_ADDRESS%%,guid=*})."

# Mouse look does not depend on this any more: index.html sends the travel to
# /cloudpc/mouse and mouseproxy.py moves the pointer by exactly that much as
# relative motion, which is the only thing the game reads. Fitting the window is
# still worth doing for a windowed game, because the stream is the phone's whole
# world: an unfitted window leaves desktop furniture around the game and shrinks
# it below the pixels the encoder is already sending. The game's own fullscreen
# request is not dependable here (GLFW asks XRandR for a video mode, Xvfb offers
# few, and openbox can still add a titlebar that shifts the client area down), so
# the geometry is set directly, once per Minecraft window, retried a few times
# because the game resizes itself just after it opens, and never again afterwards,
# so F11 stays yours. FIT_GAME_WINDOW=0 disables it.

# ---------------------------------------------------------------------------
# Window fitting
#
# openbox does not fit anything: a window keeps the size the application asks for,
# even when that is larger than the framebuffer, and a touch client has no way to
# reach the edges it hangs over. Every window is moved fully into view and shrunk to
# leave WINDOW_MARGIN of desktop around it, so its titlebar and its resize grips stay
# reachable.
#
# The framebuffer is never resized. Xvfb will change the screen size with
# `xrandr --fb`, but it does that by disabling the output's CRTC: the RandR screen
# then has no active monitor, glfwGetPrimaryMonitor() returns NULL and Minecraft
# refuses to start fullscreen ("Failed to locate a primary monitor"). So the desktop
# is the size asked for from boot and stays that size, and a window whose minimum is
# larger — Prism's Settings dialog at small framebuffer sizes — is kept inside by
# UI_SCALE, which shrinks that minimum along with the rest of the layout.
#
# Desktop furniture is skipped before it is measured or moved. In xfce mode the
# panel and the wallpaper window are in the same client list as the applications
# (a DOCK and a DESKTOP), so fitting them would shrink and move the panel and the
# wallpaper like any application window. Minecraft is left alone too: fit_game_window
# below gives it the whole framebuffer on purpose, because every pixel there is game.
# The loop costs a couple of small X queries per window every two seconds, and only
# asks a window its name when it is not already where it should be.
client_windows() {
  # The windows openbox manages, from its own list. Searching the window tree would
  # also turn up menus, tooltips and other override-redirect windows, which are not
  # things a user resizes or moves.
  DISPLAY=:0 xprop -root -notype _NET_CLIENT_LIST 2>/dev/null \
    | sed -n 's/.*# *//p' | tr ',' '\n' | tr -d ' ' | sed '/^$/d'
}

# "x y width height" of a client window, in root coordinates.
window_geometry() {
  DISPLAY=:0 xdotool getwindowgeometry --shell "$1" 2>/dev/null \
    | sed -n 's/^X=//p;s/^Y=//p;s/^WIDTH=//p;s/^HEIGHT=//p' | paste -sd' '
}

# The window's _NET_WM_WINDOW_TYPE atoms, space separated. Most applications set no
# type at all and print nothing here, which leaves them ordinary windows to fit.
window_type() {
  # -notype drops the "(ATOM)" after the property name, so match around it: the
  # line is "_NET_WM_WINDOW_TYPE = _NET_WM_WINDOW_TYPE_DOCK" either way.
  DISPLAY=:0 xprop -id "$1" -notype _NET_WM_WINDOW_TYPE 2>/dev/null \
    | sed -n 's/^_NET_WM_WINDOW_TYPE[^=]*= *//p'
}

fit_windows() {
  local margin="${WINDOW_MARGIN}" titlebar="${WINDOW_TITLEBAR}"
  local wid name type state gx gy gw gh sw sh avail_w avail_h
  local target_x target_y warn_key last_warn=""
  local -A refused=()
  while kill -0 "$XVFB_PID" 2>/dev/null; do
    read -r sw sh < <(screen_size) || true
    if [[ ! "$sw" =~ ^[0-9]+$ || ! "$sh" =~ ^[0-9]+$ ]]; then
      sleep 2
      continue
    fi
    for wid in $(client_windows); do
      read -r gx gy gw gh < <(window_geometry "$wid") || true
      if [[ ! "$gx" =~ ^-?[0-9]+$ || ! "$gy" =~ ^-?[0-9]+$ \
            || ! "$gw" =~ ^[0-9]+$ || ! "$gh" =~ ^[0-9]+$ ]]; then
        continue
      fi
      if (( gw < 16 || gh < 16 )); then
        continue
      fi
      # Skip the session's own furniture: the panel (DOCK), the desktop background
      # (DESKTOP) and any tooltip a toolkit manages for itself. They have no titlebar
      # and are not the user's to resize; fitting the panel and the wallpaper would
      # shrink and move them.
      type="$(window_type "$wid")"
      case "$type" in
        *DOCK*|*DESKTOP*|*TOOLTIP*) continue ;;
      esac
      avail_w=$(( sw - 2 * margin ))
      avail_h=$(( sh - titlebar - 2 * margin ))
      if (( avail_w < 64 )); then avail_w=64; fi
      if (( avail_h < 64 )); then avail_h=64; fi
      # Only a window that is not already where it should be costs the extra queries
      # to identify it, which is most windows most of the time.
      if (( gw > avail_w || gh > avail_h \
            || gx < margin || gy < margin + titlebar \
            || gx > sw - margin - gw || gy > sh - margin - gh )); then
        name="$(DISPLAY=:0 xdotool getwindowname "$wid" 2>/dev/null || true)"
        case "$name" in
          ""|Minecraft*|*[Mm]inecraft*) continue ;;
        esac
        # A maximized or fullscreen window is a size the user asked for, and openbox
        # resizes those itself when the screen changes.
        state="$(DISPLAY=:0 xprop -id "$wid" -notype _NET_WM_STATE 2>/dev/null || true)"
        case "$state" in
          *MAXIMIZED*|*FULLSCREEN*) continue ;;
        esac
        # Ask for the smaller size, unless this window already refused exactly this
        # size: a minimum it cannot cross would otherwise be retried every two
        # seconds for as long as the window is open. A window whose size has changed
        # since (the dialog switched page, the application resized itself) is tried
        # again. The geometry is read back instead of assumed.
        if (( gw > avail_w || gh > avail_h )) \
              && [[ "${refused[$wid]:-}" != "${gw}x${gh}" ]]; then
          timeout 5 xdotool windowsize --sync "$wid" \
            "$(( gw < avail_w ? gw : avail_w ))" \
            "$(( gh < avail_h ? gh : avail_h ))" >/dev/null 2>&1 || true
          read -r gx gy gw gh < <(window_geometry "$wid") || true
          if [[ ! "$gx" =~ ^-?[0-9]+$ || ! "$gy" =~ ^-?[0-9]+$ \
                || ! "$gw" =~ ^[0-9]+$ || ! "$gh" =~ ^[0-9]+$ ]]; then
            continue
          fi
          # Remember the size the window settled on when that is still too big, so
          # the next pass does not ask again; clear it if it did shrink.
          if (( gw > avail_w || gh > avail_h )); then
            refused[$wid]="${gw}x${gh}"
          else
            unset 'refused[$wid]'
          fi
        fi
        # Move it fully inside the margin box. The client area sits below openbox's
        # titlebar, so the frame's top edge is at y - titlebar: placing the client at
        # margin + titlebar is what leaves the margin above the frame.
        target_x="$gx"
        if (( target_x < margin )); then target_x="$margin"; fi
        if (( target_x > sw - margin - gw )); then target_x="$(( sw - margin - gw ))"; fi
        if (( target_x < margin )); then target_x="$margin"; fi
        target_y="$gy"
        if (( target_y < margin + titlebar )); then target_y="$(( margin + titlebar ))"; fi
        if (( target_y > sh - margin - gh )); then target_y="$(( sh - margin - gh ))"; fi
        if (( target_y < margin + titlebar )); then target_y="$(( margin + titlebar ))"; fi
        if (( target_x != gx || target_y != gy )); then
          timeout 5 xdotool windowmove --sync "$wid" "$target_x" "$target_y" >/dev/null 2>&1 || true
        fi
        # A window that will not shrink to what this desktop leaves for it is the one
        # case fitting cannot solve alone. Say it once, with the knob that can.
        if (( gw > avail_w || gh > avail_h )); then
          warn_key="$wid:$gw:$gh"
          if [[ "$warn_key" != "$last_warn" ]]; then
            last_warn="$warn_key"
            echo "WARNING: window '${name}' will not shrink below ${gw}x${gh}, but this desktop leaves ${avail_w}x${avail_h} for it, so part of it stays off screen. Lower UI_SCALE to make its layout smaller."
          fi
        fi
      fi
    done
    sleep 2
  done
}

# Ask the running x11vnc for a framebuffer rectangle, through its remote-control
# channel: an X property on the display, not a new connection. The session is not
# interrupted -- x11vnc starts sending that sub-region, reports the new size, and
# noVNC resizes its canvas to match. Passing the whole screen turns the clip off
# again, which is what happens when the game closes and the desktop comes back.
set_stream_clip() {
  local width="$1" height="$2" out
  out="$(timeout 8 runuser -u cloud -- env HOME=/home/cloud DISPLAY=:0 \
    x11vnc -R "clip:${width}x${height}+0+0" 2>&1 || true)"
  echo "CloudPC: stream region ${width}x${height} at 0,0"
  case "${out,,}" in
    *error*|*fail*|*unknown*)
      echo "CloudPC: x11vnc did not take that region: ${out//$'\n'/ }"
      ;;
  esac
}

fit_game_window() {
  local wid="" last="" attempt geometry stream_w stream_h clip_w clip_h last_clip=""
  while kill -0 "$XVFB_PID" 2>/dev/null; do
    wid="$(DISPLAY=:0 xdotool search --onlyvisible --name '^Minecraft' 2>/dev/null | head -n1 || true)"
    if [[ -z "$wid" ]]; then
      if [[ -n "$last" ]]; then
        echo "CloudPC: game window closed"
        last=""
        last_clip=""
        # The launcher and every window fitted to the screen need the whole
        # framebuffer again, so the stream goes back to the full desktop.
        set_stream_clip "$SCREEN_WIDTH" "$SCREEN_HEIGHT"
      fi
      sleep 2
      continue
    fi
    read -r stream_w stream_h < <(stream_size)
    if [[ "$wid" != "$last" ]]; then
      last="$wid"
      # _MOTIF_WM_HINTS: ask the window manager for no titlebar and no border, so the
      # client area really is the whole stream and not the stream minus a titlebar.
      DISPLAY=:0 xprop -id "$wid" -f _MOTIF_WM_HINTS 32c \
        -set _MOTIF_WM_HINTS '0x2, 0x0, 0x0, 0x0, 0x0' >/dev/null 2>&1 || true
      for attempt in 1 2 3; do
        sleep 1
        timeout 5 xdotool windowmove --sync "$wid" 0 0 >/dev/null 2>&1 || true
        timeout 5 xdotool windowsize --sync "$wid" \
          "$stream_w" "$stream_h" >/dev/null 2>&1 || true
        timeout 5 xdotool windowraise "$wid" >/dev/null 2>&1 || true
      done
      # The stream is exactly the game window now, so the desktop behind it is
      # never read, JPEGed or shipped while you play.
      set_stream_clip "$stream_w" "$stream_h"
      last_clip="${stream_w}x${stream_h}"
      geometry="$(DISPLAY=:0 xdotool getwindowgeometry --shell "$wid" 2>/dev/null | tr '\n' ' ' || true)"
      echo "CloudPC: game window ${wid} fitted to ${stream_w}x${stream_h} at 0,0 (${geometry:-geometry unknown})"
    else
      # The game can resize itself afterwards (F11, a resolution or GUI scale
      # change). That size is never overridden again, but the stream still has to
      # show all of it, so the region follows the window instead of cropping it;
      # the page asks for a smaller window again when the frame rate drops.
      read -r _ _ clip_w clip_h < <(window_geometry "$wid") || true
      if [[ "$clip_w" =~ ^[0-9]+$ && "$clip_h" =~ ^[0-9]+$ ]] \
         && (( clip_w >= 96 && clip_h >= 96 )) \
         && [[ "${clip_w}x${clip_h}" != "$last_clip" ]]; then
        set_stream_clip "$clip_w" "$clip_h"
        last_clip="${clip_w}x${clip_h}"
      fi
    fi
    sleep 2
  done
}

# The lite session is the whole desktop here: openbox holds the windows, and the
# only thing the user needs on top of it is the launcher. The XFCE stack costs
# several hundred megabytes of RSS and a handful of always-running daemons
# (panel, settings, desktop, notify, power, thunar) for a taskbar nobody needs
# while the game is fullscreen, and that memory and CPU belong to the renderer.
seed_openbox_menu() {
  local dir=/data/.config/openbox
  mkdir -p "$dir"
  if [[ ! -f "$dir/menu.xml" ]]; then
    cat > "$dir/menu.xml" <<'MENU'
<?xml version="1.0" encoding="UTF-8"?>
<openbox_menu xmlns="http://openbox.org/3.4/menu">
  <menu id="root-menu" label="CloudPC">
    <item label="Prism Launcher">
      <action name="Execute"><command>prismlauncher</command></action>
    </item>
    <item label="Terminal">
      <action name="Execute"><command>xfce4-terminal</command></action>
    </item>
    <item label="Files">
      <action name="Execute"><command>thunar</command></action>
    </item>
  </menu>
</openbox_menu>
MENU
    chown -R cloud:cloud "$dir"
  fi
}

SESSION_ENV=(HOME=/home/cloud DISPLAY=:0
  XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR"
  DBUS_SESSION_BUS_ADDRESS="$DBUS_ADDRESS"
  LP_NUM_THREADS="$LP_NUM_THREADS"
  MESA_SHADER_CACHE_DIR="$MESA_SHADER_CACHE_DIR"
  MESA_SHADER_CACHE_MAX_SIZE="$MESA_SHADER_CACHE_MAX_SIZE"
  MALLOC_ARENA_MAX="$MALLOC_ARENA_MAX"
  # Every toolkit in the session draws at this fraction of 100% (see UI_SCALE):
  # Qt for Prism Launcher, GDK for the terminal, Thunar and mousepad.
  QT_SCALE_FACTOR="$UI_SCALE"
  GDK_SCALE=1
  GDK_DPI_SCALE="$UI_SCALE")

# The page's Prism button runs this command. The launcher needs the session's
# environment — dbus, XDG_RUNTIME_DIR, the UI scale — and that is built here, so the
# command is written here too rather than guessed at in mouseproxy.py. Regenerated
# every boot so it cannot go stale; kept on /data so a redeploy does not lose it.
PRISM_LAUNCHER=/data/.config/cloudpc-launch-prism
mkdir -p /data/.config
{
  echo '#!/bin/sh'
  echo 'exec env \'
  for setting in "${SESSION_ENV[@]}"; do
    printf '  %q \\\n' "$setting"
  done
  echo '  nice -n 10 prismlauncher "$@"'
} > "$PRISM_LAUNCHER"
chmod 755 "$PRISM_LAUNCHER"
chown cloud:cloud "$PRISM_LAUNCHER"

if [[ "$SESSION" == "lite" ]] && command -v openbox >/dev/null 2>&1; then
  seed_openbox_menu
  echo "CloudPC: starting openbox session (llvmpipe limited to ${LP_NUM_THREADS} CPU thread(s))..."
  runuser -u cloud -- env "${SESSION_ENV[@]}" openbox &
  DESKTOP_PID=$!

  WM_READY=0
  for _ in $(seq 1 40); do
    if ! kill -0 "$DESKTOP_PID" 2>/dev/null; then
      echo "ERROR: openbox exited during startup."
      exit 1
    fi
    if DISPLAY=:0 xprop -root -notype _NET_SUPPORTING_WM_CHECK 2>/dev/null | grep -q window; then
      WM_READY=1
      break
    fi
    sleep 0.25
  done
  if [[ "$WM_READY" != "1" ]]; then
    echo "WARNING: openbox did not claim the root window yet; starting the launcher anyway."
  fi

  # AUTOSTART_PRISM=0 leaves the desktop empty (right-click the background for the menu).
  if [[ "${AUTOSTART_PRISM:-1}" == "1" ]] && command -v prismlauncher >/dev/null 2>&1; then
    # The launcher stays open behind the game and is a whole Qt application plus its
    # own JVM: animations, a status timer, a heap of its own. It has nothing to do
    # while Minecraft is fullscreen on the stream, so it yields to the game rather
    # than sharing the core with it.
    runuser -u cloud -- env "${SESSION_ENV[@]}" nice -n 10 prismlauncher &
    PRISM_PID=$!
    echo "CloudPC: Prism Launcher started (session memory kept off the game's core)."
  else
    echo "CloudPC: AUTOSTART_PRISM=0, right-click the background and pick Prism Launcher."
  fi
else
  echo "CloudPC: starting XFCE desktop (llvmpipe limited to ${LP_NUM_THREADS} CPU thread(s))..."
  runuser -u cloud -- env "${SESSION_ENV[@]}" startxfce4 &
  DESKTOP_PID=$!
fi

# The page can only count stream updates, and x11vnc sends nothing while the picture
# does not change — so a still camera read as zero frames a second although the game
# was drawing thirty. fpswatch.py counts the game's own frames instead: one large
# damage event on its window per presented frame, still picture or not. It is a
# separate process writing a number to /tmp and nothing depends on it: the page
# falls back to the stream rate when the file is absent or stale.
if command -v xdotool >/dev/null 2>&1; then
  rm -f "$FPS_FILE"
  runuser -u cloud -- env HOME=/home/cloud DISPLAY=:0 \
    CLOUDPC_DISPLAY=:0 CLOUDPC_FPS_FILE="$FPS_FILE" CLOUDPC_OPTIONS="$INSTANCE_OPTIONS" \
    python3 /opt/cloudpc/fpswatch.py &
  FPS_PID=$!
  if kill -0 "$FPS_PID" 2>/dev/null; then
    echo "CloudPC: the game's frame rate is measured from its window damage."
  else
    echo "WARNING: fpswatch did not start; the page will count stream updates only."
  fi
fi

# Fits every window of the session, the launcher included. Nothing here is a game
# window, so this is the one that keeps dialogs and the launcher whole on screen.
if [[ "${FIT_WINDOWS:-1}" == "1" ]] && command -v xdotool >/dev/null 2>&1; then
  fit_windows &
  FIT_WINDOWS_PID=$!
fi

if [[ "${FIT_GAME_WINDOW:-1}" == "1" ]] && command -v xdotool >/dev/null 2>&1; then
  fit_game_window &
  FIT_PID=$!
fi

# Keep x11vnc output visible: startup failures must be diagnosable in Altare.
#
# The encoder runs well below Minecraft in CPU priority. The stream can be a few
# milliseconds late without hurting anything, while the frame the game is drawing
# cannot wait: on a ~1 CPU container renice is the cheapest way to give the
# renderer the core when both want it. 12, not 5, because x11vnc now also encodes
# in bigger batches: when the core is contended it should lose whole frames rather
# than steal slices of every one the game is trying to draw.
#
# With -noxdamage x11vnc has no idea which rectangles changed: it re-reads the
# whole framebuffer every poll, and on a ~1 CPU container that read is slow
# enough to catch only part of each redraw. The desktop then shows stale halves
# of the screen and the polling steals CPU from Minecraft. XDAMAGE (supported by
# Xvfb) tells x11vnc exactly what changed, so only those rectangles are read and
# shipped. Set VNC_NO_DAMAGE=1 to fall back to full-screen polling if some GL
# application ever fails to update under DAMAGE.
VNC_EXTRA_ARGS=()
if [[ "${VNC_NO_DAMAGE:-0}" == "1" ]]; then
  echo "CloudPC: VNC_NO_DAMAGE=1, polling the whole framebuffer instead of using XDAMAGE."
  VNC_EXTRA_ARGS+=(-noxdamage)
fi
echo "CloudPC: starting password-protected VNC server..."
runuser -u cloud -- env HOME=/home/cloud DISPLAY=:0 \
  nice -n 12 x11vnc -display :0 -rfbauth "$VNC_PASSWD_FILE" -rfbport "${VNC_PORT}" \
  -forever -shared -repeat -localhost -wait "$VNC_WAIT" -defer "$VNC_DEFER" \
  "${VNC_EXTRA_ARGS[@]}" &
VNC_PID=$!

VNC_READY=0
for _ in $(seq 1 40); do
  if ! kill -0 "$VNC_PID" 2>/dev/null; then
    echo "ERROR: x11vnc exited before opening port ${VNC_PORT}."
    wait "$VNC_PID" || true
    exit 1
  fi
  if (echo >/dev/tcp/127.0.0.1/"${VNC_PORT}") >/dev/null 2>&1; then
    VNC_READY=1
    break
  fi
  sleep 0.5
done
if [[ "$VNC_READY" != "1" ]]; then
  echo "ERROR: x11vnc did not listen on 127.0.0.1:${VNC_PORT}."
  ps aux | grep '[x]11vnc' || true
  exit 1
fi

# The RFB websocket is spoken by mouseproxy.py itself, straight to x11vnc. It used to
# be relayed through websockify, which put a second Python process and a copy of every
# frame — and every keystroke — in both directions between the encoder and the player,
# for nothing: the proxy already terminates the browser's websocket, so pointing that
# at the VNC socket is strictly less work. It also puts TCP_NODELAY on the one hop
# that matters, from the encoder to the socket, so a button press is not held behind
# an ACK. The proxy stays at nice 10: it carries the player's input now as well as the
# picture, so it may not be starved, and it still yields the core to the game first.

# Which process is spending the quota. The performance line says what the budget is;
# this says who takes it, because llvmpipe lives inside the JVM and "the game is slow"
# and "the rasteriser is slow" need different fixes. Niced all the way down: a sampler
# that competes with the thing it measures is worse than no sampler.
CLOUDPC_CPU_PERCENT="$CPU_QUOTA_PERCENT" CPU_LOG_INTERVAL="$CPU_LOG_INTERVAL" \
  nice -n 19 python3 /opt/cloudpc/cpuwatch.py &

echo "CloudPC: starting noVNC and relative mouse on 0.0.0.0:${NOVNC_PORT}..."
runuser -u cloud -- env HOME=/home/cloud DISPLAY=:0 \
  CLOUDPC_WEB_ROOT=/usr/share/novnc \
  CLOUDPC_WS_UPSTREAM="127.0.0.1:${VNC_PORT}" \
  NOVNC_PORT="${NOVNC_PORT}" \
  CLOUDPC_DISPLAY=:0 \
  CLOUDPC_SCREEN_WIDTH="${SCREEN_WIDTH}" \
  CLOUDPC_SCREEN_HEIGHT="${SCREEN_HEIGHT}" \
  CLOUDPC_STREAM_FILE="${STREAM_FILE}" \
  CLOUDPC_FPS_FILE="${FPS_FILE}" \
  CLOUDPC_CPU_CORES="${CPU_BUDGET}" \
  CLOUDPC_PRISM_LAUNCHER="${PRISM_LAUNCHER}" \
  nice -n 10 python3 /opt/cloudpc/mouseproxy.py &
PROXY_PID=$!

NOVNC_READY=0
for _ in $(seq 1 40); do
  if ! kill -0 "$PROXY_PID" 2>/dev/null; then
    echo "ERROR: mouseproxy exited during startup."
    wait "$PROXY_PID" || true
    exit 1
  fi
  if (echo >/dev/tcp/127.0.0.1/"${NOVNC_PORT}") >/dev/null 2>&1; then
    NOVNC_READY=1
    break
  fi
  sleep 0.5
done
if [[ "$NOVNC_READY" != "1" ]]; then
  echo "ERROR: mouseproxy did not listen on 127.0.0.1:${NOVNC_PORT}."
  ps aux | grep '[m]ouseproxy' || true
  exit 1
fi

echo "CloudPC: noVNC is listening on port ${NOVNC_PORT}; mouse look uses relative XTEST motion; VNC password authentication is enabled."

# Prism is niced so a first launch cannot starve the stream, but the game is its child
# and inherits that priority — which left Minecraft below Xvfb (nice 0) and level with
# the RFB relay, on a box where it is the one thing that has to be fast. The X server must
# stay its equal, because the game blocks on it to present, and everything else stays
# below. New instances are caught as they appear; a relaunch inside a session is too.
lift_game_priority() {
  local pid priority
  while true; do
    for pid in $(pgrep -u cloud -f 'net\.minecraft\.client' 2>/dev/null); do
      priority="$(ps -o ni= -p "$pid" 2>/dev/null | tr -d ' ')"
      if [[ -n "$priority" && "$priority" != "0" ]]; then
        if renice -n 0 -p "$pid" >/dev/null 2>&1; then
          echo "CloudPC: Minecraft (PID ${pid}) raised from nice ${priority} to 0; it was running below the X server."
        fi
      fi
    done
    sleep 5
  done
}
if command -v renice >/dev/null 2>&1 && command -v pgrep >/dev/null 2>&1; then
  lift_game_priority &
fi

# Supervise all core services. If one exits, report which one before shutdown.
set +e
wait -n "$XVFB_PID" "$DBUS_PID" "$DESKTOP_PID" "$VNC_PID" "$PROXY_PID"
status=$?
set -e
for name in XVFB DBUS DESKTOP VNC PROXY; do
  pidvar="${name}_PID"
  pid="${!pidvar}"
  if [[ -n "$pid" ]] && ! kill -0 "$pid" 2>/dev/null; then
    echo "ERROR: CloudPC core process $name (PID $pid) exited."
  fi
done
echo "CloudPC: a core process exited (status $status); stopping container."
exit "$status"
