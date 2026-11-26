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
- An 800×500 desktop whose apps scale with the framebuffer, and a big cursor for small screens; the browser upscales the stream to the device. The framebuffer is deliberately small: it is what the CPU rasteriser fills and what x11vnc reads and encodes, so 800×500 is 61% of the pixels of a 1024×640 desktop at the same 16:10 shape. `SCREEN_WIDTH` / `SCREEN_HEIGHT` override it; 640×400 is a further 36% cut if you want more speed and do not mind a softer picture. `PIXEL_OFFLOAD=1|2` selects 640×400 or 512×320 outright, and the browser's WebGPU stage sharpens the upscale so a smaller framebuffer stays legible — the **GPU** button in the toolbar turns that stage on or off
- Conservative Java defaults (512 MiB initial, 1.5 GiB maximum)
- Minecraft instance preconfigured for software rendering: fullscreen on the 800×500 desktop, 2.5 GiB heap, 3 chunk render distance, fast graphics, no clouds or entity shadows
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
  - The **right half** turns the camera. Drag anywhere on it — not just on a small pad — and a tap does nothing, so you cannot click by accident. It sends **relative motion**: each drag's travel goes to the container, which moves the X pointer by exactly that much (XTEST) instead of sending an absolute pointer position. Minecraft reads the mouse as a delta, so a swipe left and a swipe of the same size right are exact opposites and the view comes back. Earlier builds sent an absolute point instead, and any mismatch between that point and the centre of the game window — or noVNC clamping a point outside the canvas to its bottom-right pixel — added a constant to every update, which is why the camera only ever went one way. Now the position of the window, fullscreen, and the stream's scaling cannot affect turning at all. The remote cursor dot is hidden while the overlay is on. Movement is sent 20 times a second, which is Minecraft's own mouse rate, so turning speed is the same at 5 or 60 fps. While the overlay is on, a small monospace line in the top-left corner shows the travel just sent, the pointer position the desktop reports back, and how many updates succeeded or failed — the whole look path in one glance. **LMB** and **RMB** still travel as absolute positions, because a button press can only be sent that way; they go to the middle of the stream.
  - **LMB** and **RMB** (bottom row, under your thumb) stay held down while your finger is on them, which is what mining a block, attacking or placing a stack needs. **Jump** is next to them, and **Drop**, **Chat**, **Esc**, **Sneak**, **Sprint** and **Inv** fill the two rows above, all press-and-hold.
  - The **hotbar row** along the bottom is slots 1–9, where Minecraft's own bar sits. Each one presses its number key while your finger is on it. The look half's buttons are padded to sit above the row, so reaching for a slot cannot turn the camera.
  - The **Look speed** slider above the buttons sets how far the view turns per pixel of finger travel: `1.0` follows your finger exactly, the default `0.45` is slower because Minecraft applies its own mouse sensitivity on top. The value is remembered per browser, so tune it on the device you play on. Because turning follows your finger at a steady rate instead of accelerating the longer you hold it, a value you tuned on an older build may feel slow — raise the slider a notch.
- **⛶** toggles fullscreen. The toolbar and overlay respect phone safe areas.
- The desktop defaults to 800×500, scales its apps to the screen it is given, and uses a 24 px cursor for touch targets; override with `SCREEN_WIDTH` / `SCREEN_HEIGHT` (the game window follows the desktop, so the two always match). Window compositing is off because rendering is CPU-based.

## Desktop modes and what they cost

The desktop is not the point of this image — the game is — so the default session is deliberately small:

| Session | Runs | Approx. idle RSS |
| --- | --- | --- |
| `SESSION=lite` (default) | Xvfb, dbus, openbox, Prism Launcher | ~300 MB including the launcher |
| `SESSION=xfce` | the above plus xfce4-session, xfwm4, xfdesktop, xfce4-panel, xfsettingsd, xfconfd and Thunar's daemon | ~550 MB |

In lite mode the desktop background is empty and there is no taskbar: right-click it for a small menu with Prism Launcher, Terminal and Files. Window management, focus, titlebars, minimise and fullscreen toggle (F11 / a double-click on the titlebar) all still work.

Windows are fitted rather than left to the applications. Every window openbox manages is moved fully on screen and shrunk to leave `WINDOW_MARGIN` (8 px by default) of desktop around it, so its titlebar and its resize grips stay visible and reachable by touch — Prism Launcher itself included. Windows the session owns are left where they are: the panel and the desktop background share the same client list in `SESSION=xfce`, so docks, desktop windows and tooltips are recognised by their window type and skipped. A window cannot be shrunk below the minimum its toolkit publishes to the window manager, and at small framebuffer sizes Prism's Settings dialog is larger than that minimum allows. The desktop is not grown to hold it: `xrandr --fb` on Xvfb changes the screen size by disabling the output, and a screen with no active output has no RandR monitor, which makes Minecraft fail at launch with `Failed to locate a primary monitor`. Instead the session's toolkits are scaled by `UI_SCALE`, derived from the framebuffer (1.0 at 800×500, 0.8 at 640×400, 0.64 at 512×320): the scale shrinks that minimum along with the rest of the layout, so the dialog fits, and the layout keeps the same proportion of the screen at every size.

Environment variables that control the cost of the desktop and the streamer:

- `SESSION=lite|xfce` — which desktop to run (default `lite`).
- `AUTOSTART_PRISM=0` — do not start the launcher with the session.
- `FIT_GAME_WINDOW=0` — stop forcing Minecraft's window to the full screen geometry. Mouse look keeps working either way, because it sends relative motion; this is only about how much of the stream is game and how much is desktop furniture.
- `VNC_WAIT` and `VNC_DEFER` (default `12` and `16` ms when the stream is at 80% of the screen or less, `16` and `30` at full size) — how often x11vnc polls the framebuffer and how long it batches damage before encoding. At full size the pair puts the stream at about 20 updates a second and lets one encode carry a whole batch instead of two encodes carrying half of it each, which is noticeably less CPU than the old `8`/`12` for the same picture. A smaller stream is cheap enough to ship more often, so it gets a 28 ms cadence and a ceiling well above the 20 fps target. Lower values cost more CPU and buy a few milliseconds of latency; `VNC_WAIT=5 VNC_DEFER=5` is the twitchy old setting if the stream feels laggy on a fast app allocation.
- `STREAM_SCALE` (default `80` on a container with fewer than 3 cores, `100` otherwise) — how much of the framebuffer the stream carries, as a percentage, which is also the size Minecraft's window is given. It is the lever that moves the frame rate; see [The stream is a rectangle](#the-stream-is-a-rectangle). `100` turns the whole thing off.
- `MALLOC_ARENA_MAX` (default `2`) — caps glibc's per-thread allocation arenas. Java, Mesa and GTK all allocate from many threads and the default is one arena per core, which costs RSS and page faults for nothing here.
- `LP_NUM_THREADS` — llvmpipe's worker count, already derived from the container's CPU quota.
- `PIXEL_OFFLOAD` — `1` or `2` shrinks the framebuffer to 640×400 or 512×320 when `SCREEN_WIDTH` / `SCREEN_HEIGHT` still hold the shipped 800×500. That is 36% and 59% fewer pixels for llvmpipe to shade and for x11vnc to read and encode, which is the only pixel-side saving left once RenderScale has already cut the world. Pair it with the **GPU** upscale in the browser, which is what stops the smaller picture looking soft. An explicit `SCREEN_WIDTH` / `SCREEN_HEIGHT` always wins over the preset. Every window is fitted to the new size on top of that — Prism Launcher included — so shrinking the framebuffer cannot leave a window shown cropped.
- `UI_SCALE` (default derived from the framebuffer) — the scale Qt and GTK draw at, so a smaller desktop shows the same layout at the same proportion instead of the same pixels on less screen. It also shrinks the minimum size a dialog insists on, which is what keeps Prism's Settings dialog inside a 512×320 desktop; lower it (for example `UI_SCALE=0.5`) if a dialog still does not fit, or set `UI_SCALE=1` for full-size text.
- `WINDOW_MARGIN` (default `8`) and `WINDOW_TITLEBAR` (default `24`) — the desktop kept visible around every window, and the titlebar height allowed for above it.
- `FIT_WINDOWS=0` — stop fitting windows and leave each one at the size the application asks for.

## Resource recommendations for a 6 GB / 150% CPU team pool

- Give CloudPC about 4 GB RAM and 125% CPU only if the rest of your team has enough left.
- Java heap: 2.5 GiB is what the instance ships with and 3 GiB is a comfortable ceiling for this scene; a 4 GiB maximum is fine but is headroom, not speed. The heap does not make frames faster — it only avoids collection stalls and running out of memory while chunks generate — and a heap that is allowed to grow to 4 GiB can press the whole container against its 6 GB limit, where the out-of-memory killer usually takes the game or the X server. If the app restarts by itself while you play, lower it first.
- Start with 2–4 chunks render distance, low graphics, no shaders and a small modpack.
- Close other desktop applications while Minecraft is running.
- The container's virtual display uses software rendering. `glxinfo -B` can help identify the renderer; if it reports llvmpipe, rendering is CPU-based.

## Minecraft performance

The desktop has no GPU, so Minecraft draws through Mesa's llvmpipe CPU rasteriser. Every frame is calculated on the CPU, and the CPU time the container is allowed is the ceiling: at 125% CPU (about one core) modern Minecraft is a few frames per second at full size no matter which mods are installed — which is why the stream is allowed to shrink below the screen; see [The stream is a rectangle](#the-stream-is-a-rectangle).

What CloudPC already does for you:

- `LP_NUM_THREADS` is derived from the container's CPU quota, so llvmpipe uses the cores the app is actually allowed instead of spawning a worker per host core and thrashing.
- The Mesa shader cache lives in `/data/.cache/mesa`, so shaders compiled by the LLVM JIT survive restarts.
- The desktop itself runs at 800×500 rather than 1280×800 or 1024×640: 400,000 pixels against 819,200 and 655,360. Every one of them is shaded by the CPU and then read and encoded by x11vnc, and the browser upscales the stream to the device, so the smaller framebuffer is nearly free to look at — just softer.
- The seeded instance runs fullscreen, with a 2.5 GiB heap because 1.21.x plus mods thrashes a 1.5 GiB heap. Fullscreen is now about the picture rather than the controls — every pixel the encoder sends should be game, at the resolution the stream is designed for. Touch look does not need it any more, because it sends relative motion. If you switch fullscreen off with F11, the game falls back to the 800×500 window in `instance.cfg`.
- A fresh instance starts at render distance 3, simulation distance 3, fast graphics, smooth lighting off, no clouds, no entity shadows, minimal particles, a 30 fps cap and vsync off. The cap matters because the stream cannot show more than about 20 updates a second anyway: an uncapped menu or sky renders frames nobody ever sees, on the core the encoder and the game share. Entity distance scaling is 0.5, so entities are only drawn at half the usual range, and biome blend radius is 0, which removes per-block colour blending work; both are ordinary video settings and the in-game sliders win once you change them.
- Minecraft runs on **Serial GC** rather than G1, with `-XX:ActiveProcessorCount` set to the container's CPU budget and the JIT capped at two threads (`-XX:+UseSerialGC -XX:+PerfDisableSharedMem -XX:CICompilerCount=2 -XX:ActiveProcessorCount=N` in the instance's Java arguments). The JVM sizes its thread pools from the host's core count rather than the cgroup quota, so on an eight-core host each of them — Minecraft's background executor, Sodium's chunk builders, the ForkJoin pool, the GC — was built for eight cores and then fought for one and a bit; `ActiveProcessorCount` is what stops that. Serial GC below about two cores matters for the same reason G1's concurrent marking, refinement threads and per-store barrier are work the JVM has to fit into the same core the game is drawing on; Serial GC collects in one stop-the-world pass with no background threads and no barrier, which is the standard choice at this size. The other two flags stop the JVM writing its perf counters through a memory-mapped file and cap the JIT compilers at two threads, so a host with dozens of cores cannot fill this container with compiler threads. Prism reads the value from the instance, so **Settings → Java → Java arguments** overrides it.
- The image ships pinned **performance mods** for exactly that Minecraft and NeoForge, every jar checksummed at build time and copied into any compatible instance on boot: **RenderScale** 1.3.6 (plus the Cloth Config it needs) preset to `scale: 0.33`, so the world is drawn at a third of the window resolution and upscaled — about a ninth of the pixels, HUD still sharp; **Sodium** 0.8.15, which replaces the chunk renderer and issues far fewer GL calls per frame; **Lithium** 0.21.4 for cheaper entity, AI and collision ticking; **ImmediatelyFast** 1.14.3 for batched HUD, text and entity drawing; **EntityCulling** 1.12.2 to skip entities that terrain hides anyway; and **BadOptimizations** 2.4.1 for assorted micro-optimisations. RenderScale's author documents it as compatible with Sodium. Jars only go to instances that are NeoForge 1.21.11 with NeoForge 21.11.6 or newer (the builds are pinned to that, and a mismatched loader mod stops Minecraft from starting), and never to an instance that already has its own build of that mod. Change the scale in game under **Mods → RenderScale → Config → Scale factor** (0.25 goes further, 0.5 is sharper); a factor CloudPC did not write is never overwritten. Set `MODS=0` (or the older `RENDERSCALE=0`) in the app environment to ship an untouched instance.
- Minecraft is switched to fullscreen on start, and on top of that the container re-fits every Minecraft window it sees to the whole screen at 0,0 with decorations off. Relying on the game's own fullscreen request alone was not enough here: GLFW picks an XRandR video mode, which Xvfb offers few of, and the window manager can still add a titlebar afterwards, leaving desktop around the game. That is a picture problem, not a control problem any more, because look sends relative motion and works in a window too; a fitted window is simply what makes the stream all game. Fullscreen also survives F11: CloudPC flips the setting once, so switching it off yourself is respected.
- If you would rather have the cheaper windowed game, set `fullscreen:false` in `<instance>/options.txt` or press F11. Drag-look (🎮) keeps working in a window, and the window is still fitted to the screen unless `FIT_GAME_WINDOW=0`.

### The stream is a rectangle

Every stage after the world is drawn costs pixels, and all of them run on this container's CPU: llvmpipe shades the HUD and blits the world onto the window, the driver copies the frame out, x11vnc reads the damaged rectangles, JPEGs them, and websockify ships them. RenderScale made the *world* cheap by drawing it at a third of the window; everything else still ran at 800×500, and 400,000 pixels at each of those stages is what a frame costs however small the world is.

So CloudPC streams a rectangle instead of a screen. x11vnc's `-clip` sends exactly that sub-region as the VNC framebuffer, and Minecraft's window is sized to the same rectangle at 0,0, so while you play the desktop behind it is never read, JPEGed or shipped. At 62% the stream is 496×310 — 38% of the pixels — and at 50% it is 400×250, a quarter. The device upscales what arrives with the WebGPU stage it already had, which is what keeps a smaller stream usable rather than just soft.

The **Detail** button in the toolbar changes that rectangle live. It posts the percentage to `mouseproxy.py`, which resizes the game window and asks the running x11vnc for the new region through its remote-control channel — an X property, not a new connection — so the session is not interrupted and noVNC simply resizes its canvas. Nothing restarts.

**Auto** (the default) aims the rectangle at a frame rate instead of picking one: it steps down while the measured rate stays under 17 fps, and back up once it is over 28 fps, with a settling period after each change so one adjustment is never judged by the hitch it caused. It only acts while a game window is open, because a still desktop has nothing to measure. Tapping the button pins a level and stops Auto; the last tap in the cycle hands control back. The choice is remembered in `/data/.config/cloudpc-stream`, so a redeploy keeps the size you picked.

The rate Auto uses is the game's own, not the stream's. x11vnc sends only pixels that changed, so with a still camera it sends nothing at all, and the old counter read zero — which looked like a measurement of the game and was really a measurement of nothing. `fpswatch.py` counts the frames Minecraft presents instead: one large damage event on the game's window per frame, whether or not a pixel of it differs, published as a number `mouseproxy.py` serves with the stream state. The stream's own update rate still caps the reading while the picture moves, because a game drawing 30 fps that reaches the device at 12 is a 12 fps view. If the counter ever stops, the page silently falls back to counting stream updates. The toolbar says `still` when nothing is drawn and nothing is reported, and `-- fps` before the first update; neither is a slow game.

When the game closes the stream goes back to the whole desktop: the launcher and every window fitted to the screen need all of it, and they get it back.

### What the browser does, and what it cannot do

Minecraft's own rendering cannot be moved into the iPad or phone browser: the game runs on the desktop, the desktop has no GPU, so llvmpipe shades every pixel on the container's CPU. Handing the world to the browser would mean replacing the client renderer outright — WebGPU is not OpenGL, and Sodium's fast path leans on GL features WebGPU does not have (multi-draw, persistent mapped buffers, direct state access) — so what CloudPC offloads is everything that happens *after* the pixels exist.

That last stage is now the device's job, and it is the one part of this pipeline a phone does better than the container: it has a real GPU and battery budget, the container has neither.

- noVNC decompresses each update in a worker and hands the picture to the **GPU stage**, a WebGPU pass that upscales the stream to the device's own pixel grid and then applies a five-tap adaptive unsharp — the same shape as FidelityFX CAS, backing off near black and white so sharpening cannot draw a dark halo around text. The **GPU** button in the toolbar toggles it and the choice is remembered per browser.
- Because the device can afford that pass, the container can afford to render less: that is what `PIXEL_OFFLOAD` is for, and why a smaller framebuffer is a real saving rather than just a softer picture.
- The **Detail** button is the other half of that trade, and the one that actually moves the frame rate: it changes how many pixels the container has to produce per frame while you watch. 800×500 → 640×400 is 36% fewer pixels at every stage, 512×320 is 59%, 400×250 is 75%. See [The stream is a rectangle](#the-stream-is-a-rectangle).
- With the GPU stage off — or on a browser with no WebGPU, or after a lost device, in which case the stage removes itself — noVNC's canvas is shown directly and the compositor does the scaling, exactly as before. Nothing about input depends on it: the overlay takes no pointer events, so taps still reach the canvas underneath.
- The **stream quality** button in the toolbar (Fast → Balanced → Sharp) decides how much compression is left to the desktop. All three send JPEG at quality 8 or 9 on the shipped 800×500 stream, one step higher at the smaller `PIXEL_OFFLOAD` sizes, because the device magnifies an 800×500 picture past 2000 pixels wide: one 8×8 JPEG block then covers several device pixels, and the sharpening pass makes its edges visible. At the old Fast setting (JPEG 5) that is exactly what Minecraft's terrain looked like — grain. What the modes still trade is zlib, which is the part that costs the container CPU: **Fast** (the default) sends none, **Balanced** noVNC's usual level 2, **Sharp** level 6 for the smallest stream and the most server CPU. The cheapest mode to encode is therefore still the default, and bandwidth is what it costs. The choice is remembered per browser.
- The toolbar's **fps** readout is the game's own frame rate, from the damage its window receives (`fpswatch.py`), capped by the updates the stream actually delivers while the picture is moving. It reads `still` when nothing is being drawn. A still picture is not a slow one, which is exactly what the old stream-only counter got wrong.
- The trackpad sends at most one pointer event per animation frame and the look pad one small request per 50 ms, because Minecraft only reads the mouse 20 times a second. The desktop gets a fraction of the input events it used to have to process, and a look request is handled in-process by `mouseproxy.py` (libXtst), so it costs no process spawn per event.

What this does not do is make the CPU draw faster. If you want the frame rate up, the levers are still more CPU for the app, a smaller RenderScale factor, and turning fullscreen off.

How the numbers behave: at `scale 0.33` a fullscreen 800×500 game shades the world over about 264×165, near 43,000 pixels, against 90,000 for the original 800×450 window at `scale 0.5` and 71,000 for the 1024×640 fullscreen that came after it. Dropping the desktop from 1024×640 to 800×500 also cut the HUD, the final upscale and every static pixel x11vnc has to encode by 39%. The win comes from rendering less, not from showing less. Nothing reaches 30 fps on one core, because independent of pixel count the CPU also has to build chunk meshes, tick the world, run the JVM's GC and encode the VNC stream — and the first two of those do not shrink when the stream does, which is why the Detail control stops paying past a very small window.

If it is still slow:

0. **Use the Detail button** in the toolbar, or leave it on Auto. It is the only lever that changes how many pixels the container has to produce per frame, it is live, and it is the difference between a slideshow and a playable picture on a small allocation.
1. **Give the app more CPU.** This is the change that scales. 125% is about one core; 300–400% usually makes Minecraft playable, if your team pool has that spare.
2. In game, **Mods → RenderScale → Config**: drop the scale factor to 0.25. Each step is another large cut in shaded pixels, at the cost of a softer picture.
3. **Esc → Options → Video**: render distance 2–3 and simulation distance 4 is the floor; every extra chunk ring is new geometry to build and draw.
4. Turn fullscreen off (F11) and keep the game window small: every pixel of the window is shaded on the CPU. Drag-look keeps working in a window.
5. Close other desktop programs while playing.
6. Check the container log at boot. The `CloudPC: performance --` line puts the CPU budget, the host's core count, llvmpipe's thread count, the stream timing and the GC choice in one place, and the renderer line above it says who is drawing: `llvmpipe` means no GPU is visible to the container and the CPU is doing all of it; `virgl`, `zink` or a real GPU name means the app does have hardware acceleration and the numbers should be much better. A `softpipe` renderer is a bug worth reporting — it is Mesa's slow fallback, several times slower than llvmpipe.

One lever sits on the device rather than the container: keep the **GPU** upscale on (it is on by default wherever WebGPU exists) and set `PIXEL_OFFLOAD=1` or `2`. That trades framebuffer pixels — and therefore CPU — for upscaling the iPad does itself. It is the cheapest win left, but it is a pixel-side win: it does not touch the JVM, chunk meshing or entity ticking, which is why the numbered list above comes first.

About the mods: **Sodium** is the biggest single change. It replaces Mojang's chunk renderer with one that batches terrain into far fewer GL calls and does much less per-frame work on the CPU, which is the bottleneck here; on a software rasteriser that is usually a clear win, though scenes differ, so if something looks wrong try one session with the Sodium jar removed from `<instance>/.minecraft/mods`. **Lithium** only makes world ticking cheaper and cannot change how anything looks. **ImmediatelyFast** and **BadOptimizations** change nothing you can see. None of them adds CPU: they lower the cost of a frame.

Two extra knobs, off by default because they depend on the machine. `GLTHREAD=1` in the app environment enables Mesa's threaded GL dispatch, the feature behind the widely reported ~30% Minecraft gain on Mesa drivers — it needs a core to spare, so try it and keep it only if it helps. Independently, CloudPC runs x11vnc one notch below Minecraft in CPU priority so the encoder waits instead of the renderer, and sets `vblank_mode=0` so a software swap never waits for a display refresh.

Run `glxinfo -B` in a desktop terminal to confirm the renderer: when it reports `llvmpipe (LLVM ...)`, the CPU is doing all the drawing.

### How mouse look works, and what to read if it does not

Look no longer sends a pointer position. Each drag's travel is posted to `/cloudpc/mouse`, and `mouseproxy.py` — the small server on the app's one exposed port, in front of websockify — turns it into real relative pointer motion through XTEST (`XTestFakeRelativeMotionEvent`, in this process, so there is no `xdotool` fork per event). Minecraft reads the mouse as a delta, so this is the same kind of motion a real mouse makes: a swipe left and a swipe right of the same size are exact opposites, and the view comes back.

That matters because every earlier attempt sent an absolute point, and absolute points have two ways to lose the direction of a drag:

1. **The point is not the centre of the game's window.** Minecraft pins the hidden cursor to that centre and reads the mouse as the offset from it, so any constant gap between the injected point and the centre is added to every single update. A drag the other way only subtracts a little from that walk.
2. **The point is clamped to an edge.** noVNC clamps anything outside the canvas to the canvas's bottom-right pixel, and a clamped point has no direction left in it.

Neither can happen to a delta, so the measuring, the centre-tracking and the clamping are gone. With them went `cloudpc-game.json`, the `win` debug line and parking the pointer on the centre: there is nothing left in the path that can be wrong about direction. `fit_game_window` stays, because it is what makes the stream all game rather than a window with desktop around it.

To see the whole path, turn the game overlay (🎮) on. A small monospace line in the top-left corner then shows three things:

- `look dx,dy` — the travel just sent, in desktop pixels. Swipe left and it must be negative; swipe right, positive. If it keeps its sign, the gesture handling is at fault.
- `pointer x,y` — where the desktop says the pointer is after that move. It should move the way you swiped. If it never moves, the request is not reaching the container, or XTEST is not working there. A `?` means the container answered without a pointer position, which the line below explains.
- `sent` / `failed` — update counts, and after them the container's own reason for the last failure: `no X display`, `injection failed`, `http 503`, `bad request` or `no reply`. `no X display` is retried every three seconds instead of disabling look for the life of the container, and a request with no reply in two seconds is abandoned so one lost packet cannot leave the camera dead until a reload.

Before a delta is injected, the container also checks — once a second, not per update — that the game window has the input focus and that the pointer is inside it. A game that lost focus reads no mouse at all and pauses, and a tap on the desktop beside a windowed game is enough to take it; relative motion with no client grab goes to the window under the pointer, so a pointer parked on the desktop turns nothing.

If all three look right and the camera still turns one way, the motion is arriving and the game is not reading it. Check the container log for the `mouseproxy` startup line, for `CloudPC: game window ... fitted to ...`, and for `CloudPC: the game's frame rate is measured from its window damage`, and report them.

### Stale halves or torn pictures

If parts of the picture stop updating — a stale half of a window, or a torn frame while the game redraws — x11vnc is polling the framebuffer instead of using the XDAMAGE extension. Polling re-reads the whole 800×500 screen every pass, which on ~1 CPU catches only part of each redraw and competes with Minecraft for CPU. CloudPC uses XDAMAGE by default, so only the rectangles that actually changed are read and sent, and updates leave within about 12 ms (`-wait 8 -defer 12`). If some GL application ever stops updating the picture under XDAMAGE, set the app environment variable `VNC_NO_DAMAGE=1` to return to full-screen polling.

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
