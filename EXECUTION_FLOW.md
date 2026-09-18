# Execution flow: from `begin` to a trudging walker

A step-by-step trace of what happens from `program LemmingsOverlay` through host initialisation and timer startup, down to how an individual walker is moved, collided, and drawn.

Default launch (`make run`) opens the **macOS overlay**. `make windows` / `make linux` use the same model and renderer; only the present step and the window list change. This trace is **macOS** (`uhostcocoa`) unless a step says otherwise.

One thread does everything after startup:

- **main (Pascal, then Cocoa run loop)** — `HostRun`, `setup`, `tick:`, `redraw`, AppKit drawing

There is no Swing EDT. `NSTimer` and `NSWindow` run on the same thread that called `NSApplication.run`.

---

## Phase A — process entry

**1.** The OS loads `LemmingsOverlay.app/Contents/MacOS/LemmingsOverlay` (or `./build/LemmingsOverlay`). FPC unit initialisation runs (`TLemmingModel` is not constructed yet).

**2.** `program LemmingsOverlay` executes `HostRun`.

```pascal
{ src/lemmings.pas }
begin
  HostRun;
end.
```

**3.** `HostRun` (Cocoa):

```pascal
procedure HostRun;
begin
  ...
  App.setActivationPolicy(NSApplicationActivationPolicyAccessory);
  SharedApp := TAppDelegate.alloc.init;
  App.setDelegate(SharedApp);
  SharedApp.setup;
  App.run;
end.
```

Accessory policy (and `LSUIElement` in `Info.plist`) means: **no Dock icon**, no Cmd-Tab. The menu extra is how you quit. `App.run` does not return until Quit.

Windows: `HostRun` registers a window class, `CreateWindowEx` with `WS_EX_LAYERED or WS_EX_TRANSPARENT or WS_EX_TOPMOST`, `SetTimer(33)`, a tray icon, then `GetMessage`.
Linux: `gtk_init`, an undecorated keep-above window, empty input shape, `g_timeout_add(33, ...)`, `gtk_main`.

---

## Phase B — overlay initialisation (`setup`)

**4.** `TAppDelegate.setup` is idempotent (`if ready then Exit`). `applicationDidFinishLaunching` calls it again after `App.run` has started; the second call is a no-op.

**5.** Pixel scale: `NSScreen.mainScreen.backingScaleFactor` (typically `2` on Sonoma retina). The controller buffers are in **pixels**; the overlay window is in **points** (the main screen's `frame`).

**6.** Original WAV stings are built once (`BuildSfxWav` for trudge / oh-no / slide / umbrella / splat / yippee). They sit in memory; nothing is read from disk.

**7.** `controller := TLemmingsController.Create(screenW * scale, …, LoadConfig)`:

- `TLemmingModel.Create` — xorshift seed, pool sized to density (default 3)
- Each slot starts `lsGone` with a staggered `SpawnIn` so they do not all drop at once
- Overlay `TPixelBuffer` allocated (RGBA, will be cleared to alpha 0)
- Bar buffer allocated for the menu extra
- `NeedsPresent := True` so the first paint happens before the timer

**8.** Menu extra: Pause, Mute, More / Fewer, Show Ledges, Hide HUD, About, Quit. `NSStatusItem` length 22 pt, image only.

**9.** Overlay window: **borderless**, `setOpaque(False)`, `clearColor`, **`setIgnoresMouseEvents(True)`**, `NSStatusWindowLevel`, joins all Spaces. Content view is `TOverlayView` (`isOpaque = False`). Clicks pass through to the apps underneath.

**10.** `collectDesktop` asks `CGWindowListCopyWindowInfo` for on-screen, non-desktop windows, skips this process and layer ≠ 0, converts `kCGWindowBounds` (top-left points) into overlay pixels, and adds the menu-bar strip / Dock as extra ledges. If that list is empty (no Screen Recording permission), `MakeFallbackDesktop` supplies three staggered rectangles.

**11.** `redraw` → `controller.Render` → `RenderLemmings` → copy into a fresh `NSImage` → `setNeedsDisplay`. The extra gets a tiny walker icon.

**12.** Timer is armed at **1/30 s**.

```pascal
animTimer := NSTimer.scheduledTimerWithTimeInterval_target_selector_userInfo_repeats(
  1.0 / 30.0, self, objcselector('tick:'), nil, True);
```

---

## Phase C — one animation tick

**13.** `tick:` wraps an `NSAutoreleasePool` (30 Hz `NSImage` traffic must not leak), then `syncCanvasSize`, `collectDesktop`, `controller.Tick`, `drainAudio`, `redraw`.

**14.** `Tick` samples `GetTickCount64`, converts to seconds, **caps `dt` at 0.05** (same hitch guard as Flying Toasters), then `Model.Update(dt)`.

**15.** For each walker, the state machine runs. A typical first life:

```
lsGone, SpawnIn hits 0
  → spawn on a random walkable top edge, Dir ±1
  → lsWalk
      X += Dir * WalkSpeed * dt
      every 0.26 s: queue sfxTrudge
      top edge gone? → lsFall + sfxOhNo
      reached left/right end?
          68%: lsSlide + sfxSlide, X locked to that face
          32%: lsFall + sfxOhNo
  → lsSlide
      Y += SlideSpeed * dt down the window frame
      crosses a lower top edge? land (sometimes lsCheer)
      reaches the bottom of the frame? lsFall
  → lsFall
      VY += Gravity * dt
      sweep PrevY→NewY against every top edge
      drop ≥ FloatDistance? lsFloat + sfxUmbrella
      land after SplatDistance? lsSplat + sfxSplat
  → lsFloat
      slower VY, red brolly in the renderer
      land → lsCheer + sfxYippee
  → lsSplat (0.85 s) → lsGone, SpawnIn ~1–3 s
  → lsCheer (0.80 s hop) → lsWalk on the same ledge
```

The array slot is reused; nothing is allocated per walker.

**16.** `drainAudio` pops the sfx queue. If not muted, each sting becomes an `NSSound` from the pre-built WAV. Trudges are throttled to 10 Hz so three walkers do not machine-gun the clomp. Windows uses `PlaySound(..., SND_MEMORY or SND_ASYNC)`. Linux writes the same bytes to `/tmp` and shells out to `paplay` / `aplay`.

**17.** `NeedsPresent` is set. `redraw` paints:

1. Clear to transparent
2. Optional ledge outlines (`Show Ledges`)
3. Each living walker (original geometry, not a sprite sheet)
4. Optional HUD (`Lemmings 3  sfx`)

Cocoa copies the RGBA bytes into an `NSImage` and invalidates the view. Windows uses `CopyBGRA` + `UpdateLayeredWindow`. GTK copies into a `GdkPixbuf`.

---

## Phase D — a menu extra click

**18.** Pause / Mute / `[` `]` / Ledges / HUD reach `TLemmingsController.ApplyChar`. Density rebuilds the pool (new slots spawn staggered; shrinking drops the tail). Mute only stops the host playing; the model still queues events. Settings are written to the INI when the controller is destroyed (Quit).

**19.** About runs a modal `NSAlert` after `activateIgnoringOtherApps` (accessory apps otherwise have no key window). Quit calls `terminate`.

---

## Headless paths

`make test` never opens a window. It `ForceLemming`s a walker onto a known rectangle and checks slide, fall, splat, yippee, and trudge, then `PlaceCataloguePose` for the six poses.

`make snap` builds a controller with `Persist=False`, calls `PlaceCataloguePose`, and writes PPM files so the original sprites can be inspected without AppKit.
