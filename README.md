# CloudPC

A browser-accessible, lightweight Debian desktop intended for an Altare Docker App. It includes XFCE, noVNC, Prism Launcher and Java 21.

> **Important reality check:** this is a remote Linux desktop running inside a container, not a full virtual machine. It uses an Xvfb virtual display and software rendering. Minecraft Java may start, but performance can be very limited without GPU passthrough. Treat this as an experimental desktop/launcher first, not a guaranteed playable gaming host.

## Features

- Debian 13 base
- A **lite openbox session by default**: window manager plus Prism Launcher and nothing else running, because every megabyte and every idle daemon is CPU and RAM the renderer does not get. `SESSION=xfce` brings the full XFCE desktop (panel, settings daemons, wallpaper, Thunar) back
- noVNC browser access with a phone- and tablet-friendly client
- VNC password authentication from the `VNC_PASSWORD` environment variable
- Touch controls: on-screen keyboard, a trackpad overlay that replaces the mouse for the whole desktop, and a game overlay with a floating movement joystick on the left half, a drag-anywhere look area on the right half, held LMB/RMB plus jump, sneak, sprint, inventory, drop, chat and Esc buttons, and a nine-slot hotbar
- A stream quality selector that keeps compression work in the browser instead of on the CPU-starved desktop
- Prism Launcher from Debian trixie-backports, preinstalled with a ready-to-run Minecraft instance and a one-tap desktop shortcut
- OpenJDK 21 runtime
- Persistent launcher configuration, accounts, instances, worlds, downloads and desktop files under `/data`
- A 1024×640 desktop with larger fonts and a big cursor for small screens; the browser upscales the stream to the device
- Conservative Java defaults (512 MiB initial, 1.5 GiB maximum)
- Minecraft instance preconfigured for software rendering: fullscreen on the 1024×640 desktop, 2.5 GiB heap, 3 chunk render distance, fast graphics, no clouds or entity shadows
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
3. Prism Launcher starts with the session in the default lite mode. If you set `AUTOSTART_PRISM=0`, right-click the desktop background and pick **Prism Launcher**; in `SESSION=xfce` it is on the desktop or in the applications menu.
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
  - The **right half** turns the camera. Drag anywhere on it — not just on a small pad — and a tap does nothing, so you cannot click by accident. The pointer is **locked to the middle of the game window**: the overlay hides the remote cursor dot, and every drag, press and release is delivered at "measured middle of the game window plus this tick's travel" and nowhere else, while Minecraft pins its own hidden cursor to that same point every tick. The container force-fits every Minecraft window to the whole screen at 0,0 with no titlebar *and* publishes the window's real rectangle in `cloudpc-game.json`; the page reads that file and dead-reckons from it, so neither the game's fullscreen request nor the window manager's decoration can shift the centre any more. While the game overlay is on, a small monospace line in the top-left corner shows `look x,y  travel dx,dy` and the `win` rectangle in use — that is the whole look path in one glance, and it is the first thing to read if turning ever feels wrong. That is why looking up, down and sideways never runs out of room, and why pressing a button never jerks the camera. Movement is sent 20 times a second, which is Minecraft's own mouse rate, so turning speed is the same at 5 or 60 fps.
  - **LMB** and **RMB** (bottom row, under your thumb) stay held down while your finger is on them, which is what mining a block, attacking or placing a stack needs. **Jump** is next to them, and **Drop**, **Chat**, **Esc**, **Sneak**, **Sprint** and **Inv** fill the two rows above, all press-and-hold.
  - The **hotbar row** along the bottom is slots 1–9, where Minecraft's own bar sits. Each one presses its number key while your finger is on it. The look half's buttons are padded to sit above the row, so reaching for a slot cannot turn the camera.
  - The **Look speed** slider above the buttons sets how far the view turns per pixel of finger travel: `1.0` follows your finger exactly, the default `0.45` is slower because Minecraft applies its own mouse sensitivity on top. The value is remembered per browser, so tune it on the device you play on. Because turning follows your finger at a steady rate instead of accelerating the longer you hold it, a value you tuned on an older build may feel slow — raise the slider a notch.
- **⛶** toggles fullscreen. The toolbar and overlay respect phone safe areas.
- The desktop defaults to 1024×640 with 120 DPI fonts and a 24 px cursor for touch targets; override with `SCREEN_WIDTH` / `SCREEN_HEIGHT`. Window compositing is off because rendering is CPU-based.

## Desktop modes and what they cost

The desktop is not the point of this image — the game is — so the default session is deliberately small:

| Session | Runs | Approx. idle RSS |
| --- | --- | --- |
| `SESSION=lite` (default) | Xvfb, dbus, openbox, Prism Launcher | ~300 MB including the launcher |
| `SESSION=xfce` | the above plus xfce4-session, xfwm4, xfdesktop, xfce4-panel, xfsettingsd, xfconfd and Thunar's daemon | ~550 MB |

In lite mode the desktop background is empty and there is no taskbar: right-click it for a small menu with Prism Launcher, Terminal and Files. Window management, focus, titlebars, minimise and fullscreen toggle (F11 / a double-click on the titlebar) all still work.

Environment variables that control the cost of the desktop and the streamer:

- `SESSION=lite|xfce` — which desktop to run (default `lite`).
- `AUTOSTART_PRISM=0` — do not start the launcher with the session.
- `FIT_GAME_WINDOW=0` — stop forcing Minecraft's window to the full screen geometry (see the mouse-look notes below; only turn this off if you move the game into a window on purpose).
- `VNC_WAIT` and `VNC_DEFER` (default `8` and `12`, milliseconds) — how often x11vnc polls the framebuffer and how long it batches damage before encoding. Higher values cost a few milliseconds of stream latency and save CPU; `VNC_WAIT=5 VNC_DEFER=5` is the twitchier old setting.
- `MALLOC_ARENA_MAX` (default `2`) — caps glibc's per-thread allocation arenas. Java, Mesa and GTK all allocate from many threads and the default is one arena per core, which costs RSS and page faults for nothing here.
- `LP_NUM_THREADS` — llvmpipe's worker count, already derived from the container's CPU quota.

## Resource recommendations for a 6 GB / 150% CPU team pool

- Give CloudPC about 4 GB RAM and 125% CPU only if the rest of your team has enough left.
- Java heap: 2.5 GiB is what the instance ships with and 3 GiB is a comfortable ceiling for this scene; a 4 GiB maximum is fine but is headroom, not speed. The heap does not make frames faster — it only avoids collection stalls and running out of memory while chunks generate — and a heap that is allowed to grow to 4 GiB can press the whole container against its 6 GB limit, where the out-of-memory killer usually takes the game or the X server. If the app restarts by itself while you play, lower it first.
- Start with 2–4 chunks render distance, low graphics, no shaders and a small modpack.
- Close other desktop applications while Minecraft is running.
- The container's virtual display uses software rendering. `glxinfo -B` can help identify the renderer; if it reports llvmpipe, rendering is CPU-based.

## Minecraft performance

The desktop has no GPU, so Minecraft draws through Mesa's llvmpipe CPU rasteriser. Every frame is calculated on the CPU, and the CPU time the container is allowed is the ceiling: at 125% CPU (about one core) modern Minecraft is a few frames per second no matter which mods are installed.

What CloudPC already does for you:

- `LP_NUM_THREADS` is derived from the container's CPU quota, so llvmpipe uses the cores the app is actually allowed instead of spawning a worker per host core and thrashing.
- The Mesa shader cache lives in `/data/.cache/mesa`, so shaders compiled by the LLVM JIT survive restarts.
- The desktop itself runs at 1024×640 rather than 1280×800: fewer pixels for llvmpipe to fill and for x11vnc to encode, and the browser upscales the stream to the device, so the smaller framebuffer is nearly free to look at.
- The seeded instance runs fullscreen, with a 2.5 GiB heap because 1.21.x plus mods thrashes a 1.5 GiB heap. Fullscreen is the one size the touch look can work with: Minecraft pins the hidden cursor to the middle of its window and reads the mouse as the offset from there, and the look pad injects "middle of the screen plus this drag's travel". Only fullscreen makes those two middles the same pixel. If you switch fullscreen off with F11, the game falls back to the 960×540 window in `instance.cfg`.
- A fresh instance starts at render distance 3, simulation distance 4, fast graphics, smooth lighting off, no clouds, no entity shadows, minimal particles and vsync off.
- The image ships pinned **performance mods** for exactly that Minecraft and NeoForge, every jar checksummed at build time and copied into any compatible instance on boot: **RenderScale** 1.3.6 (plus the Cloth Config it needs) preset to `scale: 0.33`, so the world is drawn at a third of the window resolution and upscaled — about a ninth of the pixels, HUD still sharp; **Sodium** 0.8.15, which replaces the chunk renderer and issues far fewer GL calls per frame; **Lithium** 0.21.4 for cheaper entity, AI and collision ticking; **ImmediatelyFast** 1.14.3 for batched HUD, text and entity drawing; **EntityCulling** 1.12.2 to skip entities that terrain hides anyway; and **BadOptimizations** 2.4.1 for assorted micro-optimisations. RenderScale's author documents it as compatible with Sodium. Jars only go to instances that are NeoForge 1.21.11 with NeoForge 21.11.6 or newer (the builds are pinned to that, and a mismatched loader mod stops Minecraft from starting), and never to an instance that already has its own build of that mod. Change the scale in game under **Mods → RenderScale → Config → Scale factor** (0.25 goes further, 0.5 is sharper); a factor CloudPC did not write is never overwritten. Set `MODS=0` (or the older `RENDERSCALE=0`) in the app environment to ship an untouched instance.
- Minecraft is switched to fullscreen on start, and on top of that the container re-fits every Minecraft window it sees to the whole screen at 0,0 with decorations off. Relying on the game's own fullscreen request alone was not enough here: GLFW picks an XRandR video mode, which Xvfb offers few of, and the window manager can still add a titlebar afterwards — and a titlebar's worth of offset is exactly what made the camera walk one direction whatever way you dragged. A windowed game is cheaper for a CPU rasteriser, but it breaks touch look: the game pins the hidden cursor to the middle of its window while the look pad injects around the middle of the screen, so any gap between the two is added to every single update and the camera slides the same way whatever direction you drag. Fullscreen makes the gap zero. Fullscreen also survives F11: CloudPC flips the setting once, so switching it off yourself is respected.
- If you would rather have the cheaper windowed game, set `fullscreen:false` in `<instance>/options.txt`. The overlay's drag-look (🎮) needs the two middles to line up, so in that case look with the **trackpad** (🖱): it drives the cursor's absolute position, so a windowed game still turns predictably.

### What the browser does, and what it cannot do

Minecraft's own rendering cannot be moved into the iPad or phone browser: the game runs on the desktop, the desktop has no GPU, so llvmpipe shades every pixel on the container's CPU and the browser only ever sees the result as a stream. There is no way to hand the world geometry to the browser's WebGL — Minecraft has no such mode, and the world state lives on the server.

Everything around that picture is already offloaded, and CloudPC pushes what is left towards the browser:

- noVNC decompresses each update and scales the 1024×640 desktop to the device in the browser. Compositing, scaling and upsampling cost the container nothing.
- The **stream quality** button in the toolbar (Fast → Balanced → Sharp) decides how much of the picture compression is left to the desktop. **Fast** (the default) asks x11vnc for no zlib compression and lower JPEG quality: the container stops spending CPU on compression while the browser decodes a larger stream and upscales it. That is the right trade while the CPU is the bottleneck, which it is here, at the cost of bandwidth. **Balanced** is noVNC's usual setting and **Sharp** compresses hardest for the smallest stream and the most server CPU. The choice is remembered per browser.
- The look pad and the trackpad send at most one pointer event per animation frame, and the look pad one per 50 ms, because Minecraft only reads the mouse 20 times a second. The desktop gets a fraction of the input events it used to have to process.

What this does not do is make the CPU draw faster. If you want the frame rate up, the levers are still more CPU for the app, a smaller RenderScale factor, and turning fullscreen off.

How the numbers behave: at `scale 0.33` a fullscreen 1024×640 game shades the world over about 71,000 pixels, against 90,000 for the original 800×450 window at `scale 0.5`, so the larger picture costs less than the small one did. The win comes from rendering less, not from showing less: the HUD and the final upscale still grow with the window. Nothing reaches 30 fps on one core, because independent of pixel count the CPU also has to build chunk meshes, tick the world, run the JVM's GC and encode the VNC stream, and those do not shrink with resolution.

If it is still slow:

1. **Give the app more CPU.** This is the change that scales. 125% is about one core; 300–400% usually makes Minecraft playable, if your team pool has that spare.
2. In game, **Mods → RenderScale → Config**: drop the scale factor to 0.25. Each step is another large cut in shaded pixels, at the cost of a softer picture.
3. **Esc → Options → Video**: render distance 2–3 and simulation distance 4 is the floor; every extra chunk ring is new geometry to build and draw.
4. Turn fullscreen off (F11) and keep the game window small: every pixel of the window is shaded on the CPU. The overlay's drag-look then drifts (see above), so use the trackpad instead.
5. Close other desktop programs while playing.
6. Check the container log at boot: it prints the GL renderer once the display is up. `llvmpipe` there means no GPU is visible to the container and the CPU is doing all the drawing; `virgl`, `zink` or a real GPU name means the app does have hardware acceleration and the numbers should be much better.

About the mods: **Sodium** is the biggest single change. It replaces Mojang's chunk renderer with one that batches terrain into far fewer GL calls and does much less per-frame work on the CPU, which is the bottleneck here; on a software rasteriser that is usually a clear win, though scenes differ, so if something looks wrong try one session with the Sodium jar removed from `<instance>/.minecraft/mods`. **Lithium** only makes world ticking cheaper and cannot change how anything looks. **ImmediatelyFast** and **BadOptimizations** change nothing you can see. None of them adds CPU: they lower the cost of a frame.

Two extra knobs, off by default because they depend on the machine. `GLTHREAD=1` in the app environment enables Mesa's threaded GL dispatch, the feature behind the widely reported ~30% Minecraft gain on Mesa drivers — it needs a core to spare, so try it and keep it only if it helps. Independently, CloudPC runs x11vnc one notch below Minecraft in CPU priority so the encoder waits instead of the renderer, and sets `vblank_mode=0` so a software swap never waits for a display refresh.

Run `glxinfo -B` in a desktop terminal to confirm the renderer: when it reports `llvmpipe (LLVM ...)`, the CPU is doing all the drawing.

### If mouse look still turns one way whatever you do

The camera turning the same way for every swipe has exactly two causes, and both are now visible instead of guessed at:

1. **The injected point is not the game's centre.** Minecraft reads the mouse as the offset from the centre of its own window, so any constant gap is added to every update. The boot log prints `CloudPC: game window <id> fitted to ... (X=.. Y=.. WIDTH=.. HEIGHT=..)` and the overlay's `win` line shows the rectangle the page is using; if those are not `0,0 1024x640`, that is the bug, and `FIT_GAME_WINDOW=1` is what fixes it (it is on by default). If the game is deliberately windowed, the `win` line still follows it, and the look now works there too.
2. **The point is clamped to an edge.** noVNC clamps anything outside the canvas to the canvas's bottom-right pixel, and a clamped point has no direction left in it. That is why the old builds always seemed to drag towards the bottom-right. Updates are now clamped inside the game window in the browser before they are sent.

If it is still one-directional, read the overlay line while you swipe left and right: `travel` must go negative when you swipe left and positive when you swipe right, and `look` must move below and above the middle of `win`. If `travel` keeps its sign, the gesture handling is at fault; if `travel` flips but the camera does not, the game is not seeing the injected motion and the log line above it tells us which window it thinks it is aiming at.

### Stale halves or torn pictures

If parts of the picture stop updating — a stale half of a window, or a torn frame while the game redraws — x11vnc is polling the framebuffer instead of using the XDAMAGE extension. Polling re-reads the whole 1024×640 screen every pass, which on ~1 CPU catches only part of each redraw and competes with Minecraft for CPU. CloudPC uses XDAMAGE by default, so only the rectangles that actually changed are read and sent, and updates leave within about 12 ms (`-wait 8 -defer 12`). If some GL application ever stops updating the picture under XDAMAGE, set the app environment variable `VNC_NO_DAMAGE=1` to return to full-screen polling.

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
