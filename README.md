# CloudPC

A browser-accessible, lightweight Debian desktop intended for an Altare Docker App. It includes XFCE, noVNC, Prism Launcher and Java 21.

> **Important reality check:** this is a remote Linux desktop running inside a container, not a full virtual machine. It uses an Xvfb virtual display and software rendering. Minecraft Java may start, but performance can be very limited without GPU passthrough. Treat this as an experimental desktop/launcher first, not a guaranteed playable gaming host.

## Features

- Debian 13 base
- XFCE desktop, Thunar file manager and terminal
- noVNC browser access
- VNC password authentication
- Prism Launcher from Debian trixie-backports
- OpenJDK 21 runtime
- Persistent launcher configuration, accounts, instances, worlds, downloads and desktop files under `/data`
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

Open `http://localhost:8080`. Use the VNC password you supplied.

For local testing, the image needs an x86-64 Linux host for the included Prism/Java package combination. The GitHub Actions workflow builds `linux/amd64`.

## Deploy on Altare

1. Push this repository to GitHub.
2. Push to `main`. The included GitHub Actions workflow builds the `linux/amd64` image and publishes it to GitHub Container Registry (GHCR) as `ghcr.io/OWNER/REPOSITORY:latest`.
3. In GitHub, open the newly created package under your profile → Packages. If you want Altare to pull without registry credentials, change the package visibility to **Public**. Otherwise create a GitHub token with `read:packages` and use Altare's private-registry credentials option.
4. In Altare, create a Docker App using the published image.
5. Set the container port to `8080`.
6. Set the app resource limits. Start with **4096 MB RAM**, **125% CPU**, and the largest disk allocation you can spare. Your team pool is shared, so make sure other servers still have resources.
7. Configure persistent storage for `/data` if the Docker App offers a persistent volume/mount. **Do not assume the container filesystem survives image redeploys.** If persistent mounts are not available for your selected Altare app type, use an Altare-supported persistent storage service or a Debian sandbox instead; do not store your only Minecraft worlds in the disposable container layer.
8. Set `VNC_PASSWORD` as an environment variable before first start. Use a unique password, not your Microsoft password.
9. Start the app and open its HTTPS address. If the page does not load, check the app logs and confirm that port `8080` is exposed.


## First launch

1. Open the CloudPC web address.
2. Select **Open desktop**.
3. Enter the VNC password.
4. Open Prism Launcher from the XFCE applications menu.
5. Add your Microsoft account inside Prism Launcher. Microsoft authentication is handled by Prism Launcher; CloudPC does not collect your credentials.
6. Create a Minecraft instance and choose its Java runtime. Select the installed Java 21 executable:
   `/usr/lib/jvm/java-21-openjdk-amd64/bin/java`

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

Back up `/data` regularly. The VNC password is generated once on first boot if `VNC_PASSWORD` is not set, printed once in the startup logs, and then retained in `/data/.vnc/passwd`. Set a new `VNC_PASSWORD` only when you intentionally want to rotate it.

## Security notes

- Keep the VNC password private and use a unique password.
- Do not expose the VNC port `5900`; only expose the noVNC web port `8080`.
- Do not share the desktop URL with untrusted people. Anyone with access and the VNC password can control the desktop and access files stored there.
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
