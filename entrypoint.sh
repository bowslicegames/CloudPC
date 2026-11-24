#!/usr/bin/env bash
set -Eeuo pipefail

: "${NOVNC_PORT:=8080}"
: "${VNC_PORT:=5900}"
: "${SCREEN_WIDTH:=1440}"
: "${SCREEN_HEIGHT:=900}"
: "${SCREEN_DEPTH:=24}"
: "${JAVA_MIN_RAM:=512M}"
: "${JAVA_MAX_RAM:=1536M}"

mkdir -p /data/.vnc /data/.minecraft /data/.local/share/PrismLauncher \
         /data/.config /data/Desktop /data/Downloads
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

echo "CloudPC: VNC password authentication is DISABLED."

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

echo "CloudPC: starting XFCE desktop..."
runuser -u cloud -- env HOME=/home/cloud DISPLAY=:0 \
  XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR" \
  DBUS_SESSION_BUS_ADDRESS="$DBUS_ADDRESS" \
  startxfce4 &
DESKTOP_PID=$!

echo "CloudPC: starting password-free VNC server..."
# Keep x11vnc output visible: startup failures must be diagnosable in Altare.
runuser -u cloud -- env HOME=/home/cloud DISPLAY=:0 \
  x11vnc -display :0 -nopw -rfbport "${VNC_PORT}" \
  -forever -shared -noxdamage -repeat -localhost &
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

echo "CloudPC: noVNC is listening on port ${NOVNC_PORT}; password authentication is disabled."

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
