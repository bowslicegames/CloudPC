# CloudPC

A browser-accessible, lightweight Debian desktop intended for an Altare Docker App. It includes XFCE, noVNC, Prism Launcher and Java 21.

> **Important reality check:** this is a remote Linux desktop running inside a container, not a full virtual machine. It uses an Xvfb virtual display and software rendering. Minecraft Java may start, but performance can be very limited without GPU passthrough. Treat this as an experimental desktop/launcher first, not a guaranteed playable gaming host.

## Features

- Debian 13 base
- XFCE desktop, Thunar file manager and terminal
- noVNC browser access with a phone- and tablet-friendly client
- VNC password authentication from the `VNC_PASSWORD` environment variable
- Touch controls: on-screen keyboard, a trackpad overlay that replaces the mouse for the whole desktop, and a game overlay with a floating movement joystick on the left half, a drag-anywhere look area on the right half and held LMB/RMB plus jump, sneak, sprint, inventory, drop, chat and Esc buttons
- A stream quality selector that keeps compression work in the browser instead of on the CPU-starved desktop
- Prism Launcher from Debian trixie-backports, preinstalled with a ready-to-run Minecraft instance and a one-tap desktop shortcut
- OpenJDK 21 runtime
- Persistent launcher configuration, accounts, instances, worlds, downloads and desktop files under `/data`
- 1280×800 desktop with larger fonts and cursor for small screens
- Conservative Java defaults (512 MiB initial, 1.5 GiB maximum)
- Minecraft instance preconfigured for software rendering: 800×450 window, 2.5 GiB heap, 4 chunk render distance, fast graphics, no clouds or entity shadows
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
- **🖱** toggles the **trackpad overlay**, which removes the need for a mouse anywhere in the desktop:
  - drag anywhere to move the cursor (movement speeds up with fast swipes),
  - tap for a left click, two-finger tap for a right click,
  - hold for about half a second, then drag, to drag windows or select text,
  - two-finger drag to scroll.
  - The buttons along the bottom give Left click, Right click, Scroll up, Scroll down, Alt+Tab, Alt+F4 and Menu (Super).
  - While it is on it captures touches, so toggle it off to tap the desktop directly.
- **🎮** toggles the game overlay, laid out like a phone first-person shooter:
  - The **left half** is a floating joystick. Touch anywhere there and the ring appears under your thumb; drag in any direction and it holds the matching W/A/S/D keys, diagonals included (up-right is W+D), and lifting your finger releases every key it pressed. There is no fixed corner to aim at.
  - The **right half** turns the camera. Drag anywhere on it — not just on a small pad — and a tap does nothing, so you cannot click by accident. The cursor is locked in the sense that it never wanders around the screen: Minecraft grabs the pointer while you play and pulls it back to the middle of its window every tick, so each update is reported as "middle of the screen plus this tick's travel". That is why looking up, down and sideways never runs out of room. Movement is sent 20 times a second, which is Minecraft's own mouse rate, so turning speed is the same at 5 or 60 fps.
  - **LMB** and **RMB** (bottom row, under your thumb) stay held down while your finger is on them, which is what mining a block, attacking or placing a stack needs. **Jump** is next to them, and **Drop**, **Chat**, **Esc**, **Sneak**, **Sprint** and **Inv** fill the two rows above, all press-and-hold.
  - The **Look speed** slider above the buttons sets how far the view turns per pixel of finger travel: `1.0` follows your finger exactly, the default `0.45` is slower because Minecraft applies its own mouse sensitivity on top. The value is remembered per browser, so tune it on the device you play on. Because turning follows your finger at a steady rate instead of accelerating the longer you hold it, a value you tuned on an older build may feel slow — raise the slider a notch.
- **⛶** toggles fullscreen. The toolbar and overlay respect phone safe areas.
- The desktop defaults to 1280×800 with 120 DPI fonts and a 24 px cursor for touch targets; override with `SCREEN_WIDTH` / `SCREEN_HEIGHT`. Window compositing is off because rendering is CPU-based.

## Resource recommendations for a 6 GB / 150% CPU team pool

- Give CloudPC about 4 GB RAM and 125% CPU only if the rest of your team has enough left.
- Keep Java maximum memory around 1–1.5 GB initially. Raising it does not make the CPU or GPU faster.
- Start with 2–4 chunks render distance, low graphics, no shaders and a small modpack.
- Close other desktop applications while Minecraft is running.
- The container's virtual display uses software rendering. `glxinfo -B` can help identify the renderer; if it reports llvmpipe, rendering is CPU-based.

## Minecraft performance

The desktop has no GPU, so Minecraft draws through Mesa's llvmpipe CPU rasteriser. Every frame is calculated on the CPU, and the CPU time the container is allowed is the ceiling: at 125% CPU (about one core) modern Minecraft is a few frames per second no matter which mods are installed.

What CloudPC already does for you:

- `LP_NUM_THREADS` is derived from the container's CPU quota, so llvmpipe uses the cores the app is actually allowed instead of spawning a worker per host core and thrashing.
- The Mesa shader cache lives in `/data/.cache/mesa`, so shaders compiled by the LLVM JIT survive restarts.
- The seeded instance opens in an 800×450 window (`instance.cfg`), a third of the pixels of the 1280×800 desktop, with a 2.5 GiB heap because 1.21.x plus mods thrashes a 1.5 GiB heap.
- A fresh instance starts at render distance 3, simulation distance 4, fast graphics, smooth lighting off, no clouds, no entity shadows, minimal particles and vsync off.
- The image ships **RenderScale** 1.3.6 with the Cloth Config it needs, preset to `scale: 0.5`: the world is drawn at half the window resolution and upscaled, so terrain costs a quarter of the pixels while the HUD stays sharp. The jars are only added to instances that are NeoForge 1.21.11 with NeoForge 21.11.6 or newer (the builds are pinned to that version, and a mismatched loader mod stops Minecraft from starting), and never when the instance already has its own build of the same mod. Change the factor in game under **Mods → RenderScale → Config → Scale factor** (0.4 or 0.33 goes further), or delete both jars from `<instance>/.minecraft/mods`. Set `RENDERSCALE=0` in the app environment to stop CloudPC adding them at all.
- Minecraft is forced out of fullscreen on start. The browser already scales the desktop to the device, and fullscreen is the most expensive case for a CPU rasteriser.

### What the browser does, and what it cannot do

Minecraft's own rendering cannot be moved into the iPad or phone browser: the game runs on the desktop, the desktop has no GPU, so llvmpipe shades every pixel on the container's CPU and the browser only ever sees the result as a stream. There is no way to hand the world geometry to the browser's WebGL — Minecraft has no such mode, and the world state lives on the server.

Everything around that picture is already offloaded, and CloudPC pushes what is left towards the browser:

- noVNC decompresses each update and scales the 1280×800 desktop to the device in the browser. Compositing, scaling and upsampling cost the container nothing.
- The **stream quality** button in the toolbar (Fast → Balanced → Sharp) decides how much of the picture compression is left to the desktop. **Fast** (the default) asks x11vnc for no zlib compression and lower JPEG quality: the container stops spending CPU on compression while the browser decodes a larger stream and upscales it. That is the right trade while the CPU is the bottleneck, which it is here, at the cost of bandwidth. **Balanced** is noVNC's usual setting and **Sharp** compresses hardest for the smallest stream and the most server CPU. The choice is remembered per browser.
- The look pad and the trackpad send at most one pointer event per animation frame, and the look pad one per 50 ms, because Minecraft only reads the mouse 20 times a second. The desktop gets a fraction of the input events it used to have to process.

What this does not do is make the CPU draw faster. If you want the frame rate up, the levers are still more CPU for the app, a smaller game window and a lower RenderScale factor.

How the numbers behave: at `scale 0.5` the terrain shader has a quarter of the pixels to shade, which typically turns 5 fps into 12–18 fps. Nothing reaches 30 fps on one core, because independent of pixel count the CPU also has to build chunk meshes, tick the world, run the JVM's GC and encode the VNC stream, and those do not shrink with resolution.

If it is still slow:

1. **Give the app more CPU.** This is the change that scales. 125% is about one core; 300–400% usually makes Minecraft playable, if your team pool has that spare.
2. In game, **Mods → RenderScale → Config**: drop the scale factor to 0.4 or 0.33. Each step is another large cut in shaded pixels, at the cost of a softer picture.
3. **Esc → Options → Video**: render distance 2–3 and simulation distance 4 is the floor; every extra chunk ring is new geometry to build and draw.
4. Keep the game window small; a bigger window means more pixels for the CPU to shade.
5. Close other desktop programs while playing.
6. Check the container log at boot: it prints the GL renderer once the display is up. `llvmpipe` there means no GPU is visible to the container and the CPU is doing all the drawing; `virgl`, `zink` or a real GPU name means the app does have hardware acceleration and the numbers should be much better.

About the mods: **Sodium** targets OpenGL 4.5 hardware and replaces Mojang's terrain renderer with GPU-driven drawing, so on a software rasteriser it can be slightly faster or slower than vanilla depending on the scene. If numbers look wrong, try one session with Sodium removed. **FerriteCore** only saves memory and does not change frame rate. Run `glxinfo -B` in a desktop terminal to confirm: when it reports `llvmpipe (LLVM ...)`, the renderer is the CPU.

### Stale halves or torn pictures

If parts of the picture stop updating — a stale half of a window, or a torn frame while the game redraws — x11vnc is polling the framebuffer instead of using the XDAMAGE extension. Polling re-reads the whole 1280×800 screen every pass, which on ~1 CPU catches only part of each redraw and competes with Minecraft for CPU. CloudPC uses XDAMAGE by default, so only the rectangles that actually changed are read and sent, and updates leave within 5 ms (`-wait 5 -defer 5`). If some GL application ever stops updating the picture under XDAMAGE, set the app environment variable `VNC_NO_DAMAGE=1` to return to full-screen polling.

This does not turn the container into a gaming host. Real frame rates need GPU passthrough or an ordinary machine.

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
