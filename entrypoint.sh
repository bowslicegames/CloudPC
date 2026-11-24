#!/usr/bin/env bash
set -Eeuo pipefail

: "${NOVNC_PORT:=8080}"
: "${VNC_PORT:=5900}"
: "${SCREEN_WIDTH:=1440}"
: "${SCREEN_HEIGHT:=900}"
: "${SCREEN_DEPTH:=24}"
: "${JAVA_MIN_RAM:=512M}"
: "${JAVA_MAX_RAM:=1536M}"

# Minecraft has no GPU here: it draws through Mesa's llvmpipe CPU rasteriser.
# llvmpipe starts one worker per core and takes that count from the host machine,
# not from the container's CPU quota, so a ~1 CPU app ends up with dozens of
# threads fighting over one core. Pin it to the quota, and keep the LLVM-compiled
# shader cache on /data so Minecraft does not recompile every shader each boot.
cgroup_cpu_limit() {
  local quota period
  if [[ -r /sys/fs/cgroup/cpu.max ]]; then
    read -r quota period < /sys/fs/cgroup/cpu.max || true
    if [[ "$quota" =~ ^[0-9]+$ ]] && [[ "${period:-0}" =~ ^[0-9]+$ ]] && (( period > 0 )); then
      echo $(( (quota + period - 1) / period ))
      return 0
    fi
  fi
  if [[ -r /sys/fs/cgroup/cpu/cpu.cfs_quota_us && -r /sys/fs/cgroup/cpu/cpu.cfs_period_us ]]; then
    read -r quota < /sys/fs/cgroup/cpu/cpu.cfs_quota_us || true
    read -r period < /sys/fs/cgroup/cpu/cpu.cfs_period_us || true
    if [[ "$quota" =~ ^[0-9]+$ ]] && [[ "${period:-0}" =~ ^[0-9]+$ ]] && (( period > 0 )) && (( quota > 0 )); then
      echo $(( (quota + period - 1) / period ))
      return 0
    fi
  fi
  nproc
}

LP_NUM_THREADS="${LP_NUM_THREADS:-$(cgroup_cpu_limit)}"
if ! [[ "${LP_NUM_THREADS:-}" =~ ^[1-9][0-9]*$ ]]; then
  LP_NUM_THREADS=1
fi
MESA_SHADER_CACHE_DIR="${MESA_SHADER_CACHE_DIR:-/data/.cache/mesa}"
MESA_SHADER_CACHE_MAX_SIZE="${MESA_SHADER_CACHE_MAX_SIZE:-512M}"
export LP_NUM_THREADS MESA_SHADER_CACHE_DIR MESA_SHADER_CACHE_MAX_SIZE

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
  printf 'OverrideWindow=true\nMinecraftWinWidth=960\nMinecraftWinHeight=540\n' >> "$INSTANCE_CFG"
fi

# Full screen on a 1280x800 software-rendered display costs the most fill rate of
# all, and the browser already scales the desktop to the device, so keep the game
# windowed. Only this one in-game setting is touched; everything else is the user's.
INSTANCE_OPTIONS="$INSTANCE_DIR/options.txt"
if [[ -f "$INSTANCE_OPTIONS" ]]; then
  sed -i 's/^fullscreen:true$/fullscreen:false/' "$INSTANCE_OPTIONS"
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
# 1.21.x with mods needs more heap than 1.5 GiB; a smaller window is cheaper to
# render on llvmpipe because every pixel is shaded on the CPU.
set_instance_default MinMemAlloc 512 1024
set_instance_default MaxMemAlloc 1536 2560
set_instance_default MinecraftWinWidth 960 800
set_instance_default MinecraftWinHeight 540 450

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

# Every pixel of the Minecraft window is shaded on the CPU, so the seeded instance
# draws the world at half resolution and upscales it: a quarter of the pixels for
# the terrain, with the HUD still drawn at full size. RENDERSCALE=0 leaves the
# instance's mods untouched for a clean unmodded test.
INSTANCE_MODS="$INSTANCE_DIR/.minecraft/mods"
RENDERSCALE_CONFIG="$INSTANCE_DIR/.minecraft/config/renderscale.json"

# RenderScale 1.3.6 is a NeoForge 1.21.11 build. Loading it into anything else is a
# mod-loading failure that stops Minecraft from starting, so check first.
renderscale_compatible() {
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

install_renderscale() {
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
    printf '{\n  "scale": 0.5,\n  "forceLinear": false,\n  "irisScale": -1.0\n}\n' > "$config"
    echo "CloudPC: RenderScale preset to 0.5 for ${name}"
  fi
}

if [[ "${RENDERSCALE:-1}" = "0" ]]; then
  echo "CloudPC: RENDERSCALE=0, not adding the rendering mods."
elif [[ ! -d /opt/cloudpc/mods ]]; then
  echo "CloudPC: the image has no pinned rendering mods, leaving the instances untouched."
else
  # Any instance that can load the builds gets them, not just the seeded one.
  for instance in "$PRISM_DIR"/instances/*/; do
    instance="${instance%/}"
    [[ -f "$instance/mmc-pack.json" ]] || continue
    if renderscale_compatible "$instance"; then
      install_renderscale "$instance"
    else
      echo "CloudPC: $(basename "$instance") is not NeoForge 1.21.11, not adding RenderScale to it."
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
VNC_PID=""
NOVNC_PID=""
cleanup() {
  trap - EXIT INT TERM
  for pid in "$NOVNC_PID" "$VNC_PID" "$DESKTOP_PID" "$DBUS_PID" "$XVFB_PID"; do
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

echo "CloudPC: starting virtual display ${SCREEN_WIDTH}x${SCREEN_HEIGHT}..."
runuser -u cloud -- env HOME=/home/cloud DISPLAY=:0 \
  Xvfb :0 -screen 0 "${SCREEN_WIDTH}x${SCREEN_HEIGHT}x${SCREEN_DEPTH}" \
  -nolisten tcp -noreset -ac &
XVFB_PID=$!

DISPLAY_READY=0
for _ in $(seq 1 60); do
  if ! kill -0 "$XVFB_PID" 2>/dev/null; then
    echo "ERROR: Xvfb exited during startup."
    wait "$XVFB_PID" || true
    exit 1
  fi
  if xdpyinfo -display :0 >/dev/null 2>&1; then
    DISPLAY_READY=1
    break
  fi
  sleep 0.5
done
if [[ "$DISPLAY_READY" != "1" ]]; then
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

echo "CloudPC: starting XFCE desktop (llvmpipe limited to ${LP_NUM_THREADS} CPU thread(s))..."
runuser -u cloud -- env HOME=/home/cloud DISPLAY=:0 \
  XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR" \
  DBUS_SESSION_BUS_ADDRESS="$DBUS_ADDRESS" \
  LP_NUM_THREADS="$LP_NUM_THREADS" \
  MESA_SHADER_CACHE_DIR="$MESA_SHADER_CACHE_DIR" \
  MESA_SHADER_CACHE_MAX_SIZE="$MESA_SHADER_CACHE_MAX_SIZE" \
  startxfce4 &
DESKTOP_PID=$!

# Keep x11vnc output visible: startup failures must be diagnosable in Altare.
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
  x11vnc -display :0 -rfbauth "$VNC_PASSWD_FILE" -rfbport "${VNC_PORT}" \
  -forever -shared -repeat -localhost -wait 5 -defer 5 \
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

echo "CloudPC: starting noVNC/websockify on 0.0.0.0:${NOVNC_PORT}..."
websockify --web=/usr/share/novnc "0.0.0.0:${NOVNC_PORT}" "127.0.0.1:${VNC_PORT}" &
NOVNC_PID=$!

NOVNC_READY=0
for _ in $(seq 1 40); do
  if ! kill -0 "$NOVNC_PID" 2>/dev/null; then
    echo "ERROR: websockify exited during startup."
    wait "$NOVNC_PID" || true
    exit 1
  fi
  if (echo >/dev/tcp/127.0.0.1/"${NOVNC_PORT}") >/dev/null 2>&1; then
    NOVNC_READY=1
    break
  fi
  sleep 0.5
done
if [[ "$NOVNC_READY" != "1" ]]; then
  echo "ERROR: websockify did not listen on 127.0.0.1:${NOVNC_PORT}."
  ps aux | grep '[w]ebsockify' || true
  exit 1
fi

echo "CloudPC: noVNC is listening on port ${NOVNC_PORT}; VNC password authentication is enabled."

# Supervise all core services. If one exits, report which one before shutdown.
set +e
wait -n "$XVFB_PID" "$DBUS_PID" "$DESKTOP_PID" "$VNC_PID" "$NOVNC_PID"
status=$?
set -e
for name in XVFB DBUS DESKTOP VNC NOVNC; do
  pidvar="${name}_PID"
  pid="${!pidvar}"
  if [[ -n "$pid" ]] && ! kill -0 "$pid" 2>/dev/null; then
    echo "ERROR: CloudPC core process $name (PID $pid) exited."
  fi
done
echo "CloudPC: a core process exited (status $status); stopping container."
exit "$status"
