FROM debian:trixie-slim

ENV DEBIAN_FRONTEND=noninteractive \
    HOME=/home/cloud \
    USER=cloud \
    DISPLAY=:0 \
    VNC_PORT=5900 \
    NOVNC_PORT=8080 \
    SCREEN_WIDTH=1024 \
    SCREEN_HEIGHT=640 \
    SCREEN_DEPTH=24 \
    JAVA_HOME=/usr/lib/jvm/java-21-openjdk-amd64

# Prism Launcher is in Debian's trixie-backports contrib component.
RUN printf '%s\n' \
      'deb http://deb.debian.org/debian trixie main contrib non-free-firmware' \
      'deb http://deb.debian.org/debian trixie-updates main contrib non-free-firmware' \
      'deb http://security.debian.org/debian-security trixie-security main contrib non-free-firmware' \
      'deb http://deb.debian.org/debian trixie-backports main contrib non-free-firmware' \
      > /etc/apt/sources.list \
 && apt-get update \
 && apt-get install -y --no-install-recommends \
      ca-certificates curl wget gnupg \
      xvfb x11vnc novnc websockify x11-utils \
      xfce4-session xfce4-panel xfce4-terminal xfdesktop4 xfwm4 \
      thunar mousepad dbus dbus-x11 \
      fonts-dejavu fonts-liberation \
      mesa-utils libgl1-mesa-dri libglx-mesa0 \
      openjdk-21-jre python3 \
 && apt-get install -y --no-install-recommends -t trixie-backports prismlauncher \
 && apt-get clean \
 && rm -rf /var/lib/apt/lists/* \
 && useradd --create-home --shell /bin/bash cloud \
 && chmod 1777 /tmp \
 && mkdir -p /tmp/.X11-unix /data /opt/cloudpc \
 && chown root:root /tmp/.X11-unix \
 && chmod 1777 /tmp/.X11-unix \
 && chown -R cloud:cloud /home/cloud /data

COPY entrypoint.sh /opt/cloudpc/entrypoint.sh
COPY healthcheck.sh /opt/cloudpc/healthcheck.sh
COPY dbus-session.conf /opt/cloudpc/dbus-session.conf
COPY prism/ /opt/cloudpc/prism/
COPY etc/xdg/xfce4/xfconf/xfce-perchannel-xml/ /etc/xdg/xfce4/xfconf/xfce-perchannel-xml/
COPY index.html /usr/share/novnc/index.html

# Minecraft shades every pixel of its window on the CPU here, so the only large
# lever left is drawing the world at a fraction of the window resolution. These
# are the pinned RenderScale builds (plus the Cloth Config it requires) for the
# Minecraft/NeoForge the instance is seeded with; the entrypoint copies them into
# the instance on boot. A failed download only means an unmodified instance.
RUN mkdir -p /opt/cloudpc/mods \
 && ( curl -fsSL --max-time 120 -o /opt/cloudpc/mods/renderscale-neoforge-1.21.11-1.3.6.jar \
        'https://cdn.modrinth.com/data/Va8PJBFX/versions/RpoRgNnx/renderscale-neoforge-1.21.11-1.3.6.jar' \
   && curl -fsSL --max-time 120 -o /opt/cloudpc/mods/cloth-config-21.11.153-neoforge.jar \
        'https://cdn.modrinth.com/data/9s6osm5g/versions/Wsus0EWg/cloth-config-21.11.153-neoforge.jar' \
   && printf '%s  %s\n' \
        '2f2f9f7dbc90f36fa9258755d2d01bbbcfdacbf70b50396ef7f5078b8bdf059aa06159bbcdf7a175a7c35463b07bbb46dfb7be06ecf975c0cbeb569846e5f2ff' /opt/cloudpc/mods/renderscale-neoforge-1.21.11-1.3.6.jar \
        '04713c7d5c3e0a8de711b4f54933c2adf72836008e37dd6e65e8c10b4c7a45d28f3ecdf4b3a94dad6c62725cd5135247cafc378ae2711b13440962abf9c61dfe' /opt/cloudpc/mods/cloth-config-21.11.153-neoforge.jar \
      | sha512sum -c - ) \
  || echo 'CloudPC: could not fetch the pinned rendering mods; the instance starts without them'

# Pin the seeded Prism instance to the current Minecraft release when the build
# has network access; the baked version is kept when Mojang cannot be reached.
RUN version="$(curl -fsS --max-time 25 https://launchermeta.mojang.com/mc/game/version_manifest_v2.json \
       | python3 -c 'import json,sys; print(json.load(sys.stdin)["latest"]["release"])' 2>/dev/null || true)" \
 && case "$version" in ''|*[!0-9A-Za-z._-]*) version="1.21.4" ;; esac \
 && python3 -c 'import json,sys; path="/opt/cloudpc/prism/instance/mmc-pack.json"; data=json.load(open(path)); data["components"][0]["version"]=sys.argv[1]; json.dump(data, open(path, "w"), indent=2)' "$version" \
 && echo "CloudPC: Prism instance pinned to Minecraft ${version}"

RUN chmod +x /opt/cloudpc/entrypoint.sh /opt/cloudpc/healthcheck.sh \
 && rm -f /usr/share/novnc/vnc.html /usr/share/novnc/vnc_lite.html

EXPOSE 8080
VOLUME ["/data"]
HEALTHCHECK --interval=30s --timeout=5s --start-period=90s --retries=3 \
  CMD ["/opt/cloudpc/healthcheck.sh"]

ENTRYPOINT ["/opt/cloudpc/entrypoint.sh"]
