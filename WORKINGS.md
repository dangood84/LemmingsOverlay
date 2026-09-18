# How Lemmings Overlay works

This note is for someone who wants to **build and run** the overlay on each OS, and to see how a small Free Pascal desktop gimmick is structured: where it starts, who owns motion, who paints pixels, and how a walker decides that a window top is a floor.

You do not need to be a Cocoa, Win32, or GTK expert. The same ideas show up in Eyes, Flying Toasters, and Moiré: an entry point, a model, a software canvas, and a native host that only presents bytes.

There is **no Lazarus form**. Each walker is a few numbers (feet, velocity, state, which window they are on). Each tick those numbers are turned into RGBA pixels. The host uploads that buffer to a click-through overlay.

## Build / run workflows

Work from the project root. `fpc` must be on `PATH`. Output always lands in `build/` (gitignored).

| What you want | Command | What you get |
|---------------|---------|--------------|
| macOS app | `make` then `make run` | `build/LemmingsOverlay.app`, opened; extra in the menu bar |
| Linux / Raspberry Pi OS | `sudo apt install fpc libgtk2.0-dev` then `make linux` then `./build/lemmingsoverlay` | GTK 2 overlay + panel icon |
| Windows 10+ | from a native FPC prompt: `make windows` then `build\LemmingsOverlay.exe` | layered overlay + tray icon |
| Headless checks | `make test` | prints `ok` lines; non-zero if walk / slide / splat / sfx are wrong |
| Frozen canvas frames | `make snap` | `build/snap-catalogue.ppm`, `snap-sprites.ppm`, `snap-hud.ppm`, `snap-wide.ppm` |
| Start over | `make clean` | deletes `build/` |

macOS (Homebrew, Sonoma+):

```bash
brew install fpc
make
make run
```

The first launch may ask for **Screen Recording**. That permission is how `CGWindowListCopyWindowInfo` learns other apps' window bounds. Deny it and the walkers still appear, on staggered fallback ledges.

Debian / Raspberry Pi OS:

```bash
sudo apt install fpc libgtk2.0-dev
make linux
./build/lemmingsoverlay
```

Windows: install FPC, open its command prompt so `fpc` is on `PATH`, then `make windows`. The `Windows` unit ships with FPC; no extra SDK is required for this app.

Only **one** host unit is compiled. `{$IFDEF DARWIN}` / `WINDOWS` / else picks `uhostcocoa`, `uhostwin`, or `uhostgtk`. Cross-compiling the GUI hosts is not a supported workflow — build on the OS you want to run on.

## Mental model

```
lemmings.pas begin
  → HostRun                    # uhostcocoa / uhostwin / uhostgtk
      → create TLemmingsController (model + overlay + bar buffers)
      → create click-through overlay + menu extra / tray
      → timer (~30 Hz)
           → host enumerates windows → Model.SetDesktop
           → Model.Update(dt)   # walk, slide, fall, splat
           → drain sfx queue → PlaySound / NSSound
           → RenderLemmings (RGBA pixels, alpha 0 between sprites)
           → host shows the buffer
```

| Layer | Unit | Tester-friendly analogy |
|-------|------|-------------------------|
| Entry / routing | `lemmings.pas` | Test runner that picks the OS host at compile time |
| Settings | `ulemmingconfig` | Fixture: density, mute, HUD, INI |
| Desktop | `ulemmingdesktop` | The "level": rectangles with a top edge you can walk |
| State | `ulemmingmodel` | The pool: spawn, collide, change state, queue sounds |
| Composer | `ulemmingapp` | Holds the model and two canvases; `NeedsPresent` is the dirty flag |
| View | `ulemmingrender` | Paints original walkers, optional ledge outlines, HUD |
| Audio | `ulemmingaudio` | Builds short original WAVs; does not play them |
| Window shell | `uhostcocoa` / `uhostwin` / `uhostgtk` | Overlay, extra/tray, window list, sfx playback |

The hosts are **event-driven**. Almost everything after `HostRun` runs on the GUI thread. That is why the walkers use `NSTimer` / `SetTimer` / `g_timeout_add` instead of a raw `while true` loop.

## Collision math

Canvas `Y` grows downward. A walker's `(X, Y)` is their **feet**, not their head.

A desktop rectangle is a window (or a fallback ledge). The **walkable floor is the top edge** `Y = Rect.Y`, for `X` between `Rect.X` and `Rect.X + Rect.W`. The sprite therefore stands on the title bar, not inside the document.

**Walk.** Each tick: `X += Dir * WalkSpeed * dt`. If the feet are no longer within a few pixels of a top edge (window closed or dragged away), the state becomes `lsFall`. If the next `X` would pass the left or right end of the current rectangle:

```
if random < SlideChance   { 0.68 live; tests pin this to 0 or 1 }
    slide down that face
else
    fall
```

**Slide.** `X` is locked to `Rect.X` (left face) or `Rect.X + Rect.W` (right face). `Y` increases at `SlideSpeed`. If a lower window's top is crossed on the way down, they hop aboard. If `Y` reaches `Rect.Y + Rect.H`, they fall off the bottom of the frame.

**Fall.** Gravity is added to `VY`. A discrete sweep (`PrevY → NewY`) detects a top edge so a 33 ms tick cannot tunnel through a thin title bar. After `FloatDistance` they become `lsFloat` (umbrella, slower `VY`). Hitting something after `SplatDistance` without a brolly is `lsSplat`.

**Follow.** Each rectangle has a stable `Id` (CG window number, HWND, X11 window). If that id is still in the next snapshot, the walker is translated by the window's delta so dragging a window drags its passenger.

Sounds are **not** started from the renderer. `ChangeState` pushes `sfxOhNo` / `sfxSlide` / `sfxUmbrella` / `sfxSplat` / `sfxYippee` onto a queue; walking also emits `sfxTrudge` every 0.26 s. The host drains the queue and plays original WAV bytes asynchronously.

## Unit responsibilities

### `lemmings.pas` — composition root

Picks one host with `{$IFDEF}` and calls `HostRun`. Nothing else.

### `ulemmingconfig` — the look

Density 1–12, mute, HUD, ledge outlines. `LoadConfig` / `SaveConfig` write `lemmingsoverlay.ini` under `GetAppConfigDir`.

### `ulemmingdesktop` — the level

`TDeskSnapshot` is a list of rectangles in overlay pixels. Hosts fill it. `MakeFallbackDesktop` is what tests, snapshots, and a permission-denied Mac use.

### `ulemmingmodel` — the tribe

`TLemming` records, xorshift spawn, `Update(dt)`, `ForceLemming` for tests, `PlaceCataloguePose` for snapshots. No pixels.

### `ulemmingrender` — the overlay

`TPixelBuffer` plus ellipses and rectangles. Original walker geometry (green / cyan / ginger hair, blue robe). Clear is RGBA `(0,0,0,0)` so the desktop shows through.

### `ulemmingapp` — glue

Timer → `Tick` → `Update` + dirty flag. Keys through `ApplyChar`. Hosts never touch the entity array.

### Hosts — present bytes and name the windows

Cocoa copies RGBA into an `NSImage` on a borderless, `ignoresMouseEvents` overlay. Windows uses `UpdateLayeredWindow` with per-pixel alpha (`WS_EX_TRANSPARENT` so clicks fall through). GTK paints a GdkPixbuf and an empty input shape.

Window lists: `CGWindowListCopyWindowInfo` (Mac), `EnumWindows` (Windows), `_NET_CLIENT_LIST` (Linux). Own process, layer ≠ 0, and tiny windows are skipped.
