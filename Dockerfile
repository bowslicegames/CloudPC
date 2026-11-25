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

# Minecraft shades every pixel of its window on the CPU here, so performance is
# about doing less work. Every build below is pinned to the Minecraft/NeoForge the
# instance is seeded with and checksummed, and the entrypoint copies them into the
# instance on boot:
#   RenderScale      draws the world at a fraction of the window resolution
#   Cloth Config     the settings screen RenderScale needs
#   Sodium           replaces the chunk renderer; far fewer GL calls and CPU work
#   Lithium          cheaper world ticking (entities, AI, collisions)
#   ImmediatelyFast  batches HUD, text and entity drawing into fewer GL calls
#   EntityCulling    skips drawing entities that are fully occluded
#   BadOptimizations assorted micro-optimisations (lighting, text, GC pressure)
# RenderScale is documented as compatible with Sodium. A failed download only means
# an instance without that one jar.
RUN mkdir -p /opt/cloudpc/mods && cd /opt/cloudpc/mods \
 && printf '%s\n' \
      'renderscale-neoforge-1.21.11-1.3.6.jar https://cdn.modrinth.com/data/Va8PJBFX/versions/RpoRgNnx/renderscale-neoforge-1.21.11-1.3.6.jar 2f2f9f7dbc90f36fa9258755d2d01bbbcfdacbf70b50396ef7f5078b8bdf059aa06159bbcdf7a175a7c35463b07bbb46dfb7be06ecf975c0cbeb569846e5f2ff' \
      'cloth-config-21.11.153-neoforge.jar https://cdn.modrinth.com/data/9s6osm5g/versions/Wsus0EWg/cloth-config-21.11.153-neoforge.jar 04713c7d5c3e0a8de711b4f54933c2adf72836008e37dd6e65e8c10b4c7a45d28f3ecdf4b3a94dad6c62725cd5135247cafc378ae2711b13440962abf9c61dfe' \
      'sodium-neoforge-0.8.15-beta.2+mc1.21.11.jar https://cdn.modrinth.com/data/AANobbMI/versions/f2SPZkvy/sodium-neoforge-0.8.15-beta.2%2Bmc1.21.11.jar 9de9d332169cabbefa67f15739cfb8eb87c3d33884cdfd6a00f8b4a8849695183c377164c44cbfbbd2a1dd9e24120790d22be501dca9e16d052509342c9de800' \
      'lithium-neoforge-0.21.4+mc1.21.11.jar https://cdn.modrinth.com/data/gvQqBUqZ/versions/M93zf1Gr/lithium-neoforge-0.21.4%2Bmc1.21.11.jar df72f98f0a678aaa1bc6967105b00ac0533f078ec3a85098385d5a4a36ee5f8e101109ca19ae2170ba6e6b55c15c4a7654976d7c457f09ec44cda3fff4a7f270' \
      'ImmediatelyFast-NeoForge-1.14.3+1.21.11.jar https://cdn.modrinth.com/data/5ZwdcRci/versions/jaBvDEKq/ImmediatelyFast-NeoForge-1.14.3%2B1.21.11.jar cc48994afc4b0a660472c69f847eabdd3e1c6e45e5ebbe8d14291cf044de08a71acbf073bf2c11ecf9312e6931dcfa85f546fa4e069cc74bebeddc47a477b4ba' \
      'entityculling-neoforge-1.12.2-mc1.21.11.jar https://cdn.modrinth.com/data/NNAgCjsB/versions/hBfQAlMs/entityculling-neoforge-1.12.2-mc1.21.11.jar 6d14518559275cf2a5a2e003a6b2b75594a97df6ec6b61adf047b490811e52e0c656d7472511478a51383c76437f298d6f4d67ac967181069ace87bf11eab1e5' \
      'BadOptimizations-2.4.1-1.21.11.jar https://cdn.modrinth.com/data/g96Z4WVZ/versions/Q3Dusz2j/BadOptimizations-2.4.1-1.21.11.jar ff91f1866f21a13a32d379080b8efb5d4e07577591228c1d307b34d052696c9bdcbaf7706208dfbac56abc2c29482a15edcbf11f69fc0a01e459c4c20a5c2c28' \
    > /tmp/cloudpc-mods.txt \
 && while read -r name url sum; do \
      if curl -fsSL --max-time 180 -o "$name" "$url" \
         && printf '%s  %s\n' "$sum" "$name" | sha512sum -c - >/dev/null 2>&1; then \
        echo "CloudPC: pinned $name"; \
      else \
        rm -f "$name"; echo "CloudPC: could not fetch $name"; \
      fi; \
    done < /tmp/cloudpc-mods.txt \
 && rm -f /tmp/cloudpc-mods.txt

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
