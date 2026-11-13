FROM debian:trixie-slim

ENV DEBIAN_FRONTEND=noninteractive \
    HOME=/home/cloud \
    USER=cloud \
    DISPLAY=:0 \
    VNC_PORT=5900 \
    NOVNC_PORT=8080 \
    SCREEN_WIDTH=1440 \
    SCREEN_HEIGHT=900 \
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
      thunar mousepad dbus-x11 \
      fonts-dejavu fonts-liberation \
      mesa-utils libgl1-mesa-dri libglx-mesa0 \
      openjdk-21-jre \
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
COPY index.html /usr/share/novnc/index.html

RUN chmod +x /opt/cloudpc/entrypoint.sh /opt/cloudpc/healthcheck.sh

EXPOSE 8080
VOLUME ["/data"]
HEALTHCHECK --interval=30s --timeout=5s --start-period=90s --retries=3 \
  CMD ["/opt/cloudpc/healthcheck.sh"]

ENTRYPOINT ["/opt/cloudpc/entrypoint.sh"]
