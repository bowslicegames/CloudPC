# CloudPC

A browser-accessible, lightweight Debian desktop intended for an Altare Docker App. It includes XFCE, noVNC, Prism Launcher and Java 21.

> **Important reality check:** this is a remote Linux desktop running inside a container, not a full virtual machine. It uses an Xvfb virtual display and software rendering. Minecraft Java may start, but performance can be very limited without GPU passthrough. Treat this as an experimental desktop/launcher first, not a guaranteed playable gaming host.

## Features

- Debian 13 base
- XFCE desktop, Thunar file manager and terminal
- noVNC browser access with a phone- and tablet-friendly client
- VNC password authentication from the `VNC_PASSWORD` environment variable
- Touch controls: on-screen keyboard, fullscreen, and a game overlay (W/A/S/D, jump, sneak, sprint, use, inventory, drop, chat and a look/tap pad)
- Prism Launcher from Debian trixie-backports, preinstalled with a ready-to-run Minecraft instance and a one-tap desktop shortcut
- OpenJDK 21 runtime
- Persistent launcher configuration, accounts, instances, worlds, downloads and desktop files under `/data`
- 1280×800 desktop with larger fonts and cursor for small screens
- Conservative Java defaults (512 MiB initial, 1.5 GiB maximum)
- Docker health check and GitHub Actions image-build workflow

## Build locally

```bash
docker build -t cloudpc:latest .
docker run --rm -it \
  -p 8080:8080 \
  -v cloudpc-data:/data \
  -e VNC_PASSWORD='choose-a-long-password' \
  cloudpc:latest
```

Open `http://localhost:8080` and enter the password. The RFB protocol keeps only the first 8 characters of a VNC password, so anything longer is truncated. If `VNC_PASSWORD` is not set, a random 8-character password is generated on first start and printed once in the container logs.

For local testing, the image needs an x86-64 Linux host for the included Prism/Java package combination. The GitHub Actions workflow builds `linux/amd64`.

## Deploy on Altare

1. Push this repository to GitHub.
2. Push to `main`. The included GitHub Actions workflow builds the `linux/amd64` image and publishes it to GitHub Container Registry (GHCR) as `ghcr.io/OWNER/REPOSITORY:latest`.
3. In GitHub, open the newly created package under your profile → Packages. If you want Altare to pull without registry credentials, change the package visibility to **Public**. Otherwise create a GitHub token with `read:packages` and use Altare's private-registry credentials option.
4. In Altare, create a Docker App using the published image.
5. Set the container port to `8080`.
6. Set the app resource limits. Start with **4096 MB RAM**, **125% CPU**, and the largest disk allocation you can spare. Your team pool is shared, so make sure other servers still have resources.
7. Configure persistent storage for `/data` if the Docker App offers a persistent volume/mount. **Do not assume the container filesystem survives image redeploys.** If persistent mounts are not available for your selected Altare app type, use an Altare-supported persistent storage service or a Debian sandbox instead; do not store your only Minecraft worlds in the disposable container layer.
8. Set `VNC_PASSWORD` as an environment variable before the first start. Use a unique password (never your Microsoft password); at most 8 characters are used. If you leave it unset, the container generates a password on first boot and prints it once in the app logs. Do not publish the address or share it with untrusted people; for internet-facing use, put the app behind a private network, VPN or an authenticated reverse proxy as well.
9. Start the app and open its HTTPS address. If the page does not load, check the app logs and confirm that port `8080` is exposed.


## First launch

1. Open the CloudPC web address.
2. Enter the VNC password: the `VNC_PASSWORD` you set, or the generated one printed in the container logs.
3. Tap **Prism Launcher** on the desktop (or open it from the XFCE applications menu).
4. Add your Microsoft account inside Prism Launcher. Microsoft authentication is handled by Prism Launcher; CloudPC does not collect your credentials.
5. Open the pre-seeded **Minecraft** instance. It is already pointed at the installed Java 21 executable:
   `/usr/lib/jvm/java-21-openjdk-amd64/bin/java`

The instance ships as a descriptor only: Prism Launcher downloads that Minecraft version's libraries, assets and game jar on first launch, which needs network access in the container and an authenticated Microsoft account.

## Mobile and touch use

- **⌨** opens the on-screen keyboard: tap it, then type into the desktop. Printable characters, Enter, Backspace, Tab, Escape, arrows and F-keys are forwarded.
- **🎮** toggles the game overlay. Left side is W/A/S/D; the right side has Jump, Sneak, Sprint, Use (right click), Inventory, Drop, Esc and Chat, all as press-and-hold buttons.
- The **Look** pad between them drags the pointer for camera movement (once Minecraft has captured the cursor this reads as mouse look) and a tap is a left click.
- **⛶** toggles fullscreen. The toolbar and overlay respect phone safe areas.
- The desktop defaults to 1280×800 with 120 DPI fonts and a 24 px cursor for touch targets; override with `SCREEN_WIDTH` / `SCREEN_HEIGHT`. Window compositing is off because rendering is CPU-based.

## Resource recommendations for a 6 GB / 150% CPU team pool

- Give CloudPC about 4 GB RAM and 125% CPU only if the rest of your team has enough left.
- Keep Java maximum memory around 1–1.5 GB initially. Raising it does not make the CPU or GPU faster.
- Start with 2–4 chunks render distance, low graphics, no shaders and a small modpack.
- Close other desktop applications while Minecraft is running.
- The container's virtual display uses software rendering. `glxinfo -B` can help identify the renderer; if it reports llvmpipe, rendering is CPU-based.

## Persistence

The following user data is stored beneath `/data`:

- `/data/.minecraft`
- `/data/.local/share/PrismLauncher`
- `/data/.config`
- `/data/Desktop`
- `/data/Downloads`
- `/data/.vnc/passwd`

Back up `/data` regularly. The VNC password is stored as a hash in `/data/.vnc/passwd`. Set `VNC_PASSWORD` to use your own, let the container generate and log one on first start, or delete the file to have a new password generated on the next boot.

## Security notes

- Always set `VNC_PASSWORD` and keep it private. Anyone with the URL and password can control the desktop and read files stored under `/data`.
- VNC authentication is weak: RFB limits passwords to 8 characters and uses a DES-based challenge. For internet-facing use, also put the app behind a private network, VPN or an authenticated reverse proxy.
- Do not expose the VNC port `5900`; only expose the noVNC web port `8080`.
- Do not share the desktop URL with untrusted people.
- Never store Microsoft credentials in environment variables or commit them to Git.
- Use HTTPS as provided by Altare's public app endpoint.

## Known limitations

- No GPU passthrough is configured.
- Xvfb + Mesa software rendering is not a substitute for a physical GPU.
- Some Minecraft versions/modpacks may need more memory than this plan can provide.
- The project does not bypass Microsoft authentication or Minecraft licensing.
- Altare storage persistence must be configured and verified separately; Docker volumes declared by an image do not by themselves guarantee persistent data on every hosting platform.

## License

MIT. Prism Launcher, Debian, XFCE, noVNC, OpenJDK and Minecraft remain under their respective licenses and trademarks.
