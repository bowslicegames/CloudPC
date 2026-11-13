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

# Keep Minecraft and Prism data on the persistent mount, not the container layer.
if [[ ! -L /home/cloud/.minecraft ]]; then
  rm -rf /home/cloud/.minecraft
  ln -s /data/.minecraft /home/cloud/.minecraft
fi
if [[ ! -L /home/cloud/.local ]]; then
  rm -rf /home/cloud/.local
  ln -s /data/.local /home/cloud/.local
fi
if [[ ! -L /home/cloud/.config ]]; then
  rm -rf /home/cloud/.config
  ln -s /data/.config /home/cloud/.config
fi
if [[ ! -L /home/cloud/Desktop ]]; then
  rm -rf /home/cloud/Desktop
  ln -s /data/Desktop /home/cloud/Desktop
fi
if [[ ! -L /home/cloud/Downloads ]]; then
  rm -rf /home/cloud/Downloads
  ln -s /data/Downloads /home/cloud/Downloads
fi
chown -h cloud:cloud /home/cloud/.minecraft /home/cloud/.local \
  /home/cloud/.config /home/cloud/Desktop /home/cloud/Downloads

# Generate a persistent VNC password on first boot. It is printed once so the
# owner can retrieve it from the container logs, and then retained in /data.
if [[ -n "${VNC_PASSWORD:-}" ]]; then
  printf '%s\n' "$VNC_PASSWORD" | x11vnc -storepasswd - /data/.vnc/passwd >/dev/null
  chmod 600 /data/.vnc/passwd
elif [[ ! -s /data/.vnc/passwd ]]; then
  VNC_PASSWORD="$(od -An -N8 -tx1 /dev/urandom | tr -d ' \n')"
  printf '%s\n' "$VNC_PASSWORD" | x11vnc -storepasswd - /data/.vnc/passwd >/dev/null
  chmod 600 /data/.vnc/passwd
  echo "CLOUDPC_FIRST_BOOT_VNC_PASSWORD=${VNC_PASSWORD}"
else
  echo "CloudPC: using the VNC password already stored in /data/.vnc/passwd"
fi

# Sensible low-memory Java defaults; users can change these in Prism settings.
mkdir -p /data/.config
cat > /data/.config/cloudpc-env <<EOF
JAVA_MIN_RAM=${JAVA_MIN_RAM}
JAVA_MAX_RAM=${JAVA_MAX_RAM}
EOF
chown cloud:cloud /data/.config/cloudpc-env

cleanup() {
  kill "${NOVNC_PID:-}" "${VNC_PID:-}" "${DESKTOP_PID:-}" "${XVFB_PID:-}" 2>/dev/null || true
  wait || true
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
    echo "ERROR: Xvfb process exited during startup."
    wait "$XVFB_PID" || true
    break
  fi
  if xdpyinfo -display :0 >/dev/null 2>&1; then
    DISPLAY_READY=1
    break
  fi
  sleep 0.5
done
if [[ "$DISPLAY_READY" != "1" ]]; then
  echo "ERROR: Xvfb did not become ready. Diagnostics:"
  command -v Xvfb || true
  command -v xdpyinfo || true
  ls -ld /tmp /tmp/.X11-unix || true
  ls -la /tmp/.X11-unix || true
  ps aux | grep '[X]vfb' || true
  exit 1
fi

echo "CloudPC: starting XFCE desktop..."
runuser -u cloud -- env HOME=/home/cloud DISPLAY=:0 \
  dbus-run-session -- startxfce4 &
DESKTOP_PID=$!

echo "CloudPC: starting authenticated VNC server..."
runuser -u cloud -- env HOME=/home/cloud DISPLAY=:0 \
  x11vnc -display :0 -rfbauth /data/.vnc/passwd \
  -rfbport "${VNC_PORT}" -forever -shared -noxdamage -repeat \
  -localhost -quiet &
VNC_PID=$!

for _ in $(seq 1 40); do
  if (echo >/dev/tcp/127.0.0.1/"${VNC_PORT}") >/dev/null 2>&1; then break; fi
  sleep 0.5
done

echo "CloudPC: serving noVNC on 0.0.0.0:${NOVNC_PORT}"
websockify --web=/usr/share/novnc "0.0.0.0:${NOVNC_PORT}" "127.0.0.1:${VNC_PORT}" &
NOVNC_PID=$!

set +e
wait -n "$XVFB_PID" "$DESKTOP_PID" "$VNC_PID" "$NOVNC_PID"
status=$?
set -e
echo "CloudPC: a core process exited (status ${status}); stopping container."
exit "$status"
