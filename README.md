# Lemmings Overlay

A nineties-style desktop gimmick: little walkers **stomp across the tops of your windows**, slide down the sides, and sometimes pop a brolly — or splat.

Written in **Free Pascal**. Lazarus and Delphi are not required — `fpc` plus the platform GUI libraries already on the machine are enough. There is no game engine and no widget-toolkit theme to fight. The overlay is a software RGBA canvas; each host only uploads those bytes into a click-through window.

Sprites and chip sounds are **original**. This is not affiliated with Lemmings, DMA Design, or Psygnosis, and it does not ship their bitmaps or samples.

The tribe:

- walks the **top edge** of on-screen windows
- usually **slides down** a side when they run out of title bar
- **falls**, and opens an umbrella if the drop is long enough
- **splats** if they don't
- **yippees** when a floater lands
- trudges with an original two-step clomp while walking

How the pieces fit together (same style as Eyes, Flying Toasters, and the calculator): `WORKINGS.md` for responsibilities and collision math, `EXECUTION_FLOW.md` for a tick-by-tick trace.

## Requirements

- **Free Pascal** 3.2+ (`fpc` on your `PATH`)

macOS (Homebrew), Sonoma-compatible:

```bash
brew install fpc
```

Debian / Raspberry Pi OS:

```bash
sudo apt install fpc libgtk2.0-dev
```

Windows 10+: a native Free Pascal install (the `Windows` unit ships with FPC).

On **macOS**, grant **Screen Recording** to Lemmings Overlay the first time it runs (System Settings → Privacy & Security). Without it the OS hides other apps' window bounds, so the walkers use a few fallback ledges instead of your real windows.

## Run

From the project root:

```bash
make
make run
```

That compiles to `build/` and opens `LemmingsOverlay.app` on macOS. There is **no Dock icon** (`LSUIElement`); look for the tiny walker in the **right-hand menu extras**.

Or with Make on other OSes:

```bash
make linux      # Linux / Raspberry Pi OS overlay + panel icon
make windows    # LemmingsOverlay.exe — overlay + tray icon
make test       # headless walk / slide / splat / sfx checks (no GUI)
make snap       # four PPM frames of the canvas
make clean      # remove build/
```

Manual compile on macOS (Make still has to wrap the binary in the `.app` bundle):

```bash
fpc -Mobjfpc -Scgi -O2 -Fusrc -FUbuild -FEbuild -obuild/LemmingsOverlay src/lemmings.pas
make app
open build/LemmingsOverlay.app
```

## Using it

1. A walker appears on a window top (or a fallback ledge) and trudges along.
2. At the end of the title bar they usually grab the frame and slide; sometimes they step off.
3. A long fall pops a red umbrella. A longer one without it splats, then another walker respawns.
4. Click the menu extra (macOS / Linux) or tray icon (Windows) for Pause, Mute, More / Fewer, Show Ledges, Hide HUD, About, and Quit.
5. The overlay **ignores mouse clicks**, so you can still use the apps underneath.

## Where it appears

| OS | Presence |
|----|----------|
| **macOS** | Full-screen click-through overlay + menu extra. No Dock icon. |
| **Windows** | Layered click-through overlay covering the primary monitor + notification-area icon. |
| **Linux** | GTK 2 click-through overlay (Raspberry Pi OS friendly) + panel status icon. |

Quit from the extra / tray. Closing is not a window close box — there isn't one.

## Project layout

```
src/
  lemmings.pas        # program; picks the host with {$IFDEF}
  ulemmingconfig.pas  # density, mute, HUD, INI load/save
  ulemmingdesktop.pas # window rectangles in canvas pixels
  ulemmingmodel.pas   # pool, walk / slide / fall / splat / cheer
  ulemmingrender.pas  # software RGBA canvas (original sprites)
  ulemmingapp.pas     # TLemmingsController: overlay + bar buffers
  ulemmingaudio.pas   # original WAV stings (trudge, oh-no, yippee…)
  uhostcocoa.pas      # macOS overlay + CGWindowList
  uhostwin.pas        # Windows layered HWND + EnumWindows
  uhostgtk.pas        # Linux GtkWindow + X11 client list
  lemmingtest.pas     # headless physics / sfx checks
  lemmingsnap.pas     # paints PPM frames without a window
  ubitmapfont.pas     # 8×8 HUD text
bundle/
  Info.plist          # LSUIElement menu extra, retina-capable
Makefile
```
