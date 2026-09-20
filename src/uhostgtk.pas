unit uhostgtk;

{$mode objfpc}{$H+}

{ Linux GTK 2 click-through overlay + panel status icon. Same
  TLemmingsController as macOS. FPC's gtk2 unit often omits status-icon
  and a few Gdk symbols (same as Eyes), so those are cdecl externals.
  Window bounds come from libX11, not the x / xlib Pascal units. }

interface

procedure HostRun;

implementation

{$IF DEFINED(UNIX) AND NOT DEFINED(DARWIN)}

uses
  SysUtils, Unix, ctypes, gtk2, gdk2, gdk2pixbuf, gdk2x, glib2,
  ulemmingconfig, ulemmingdesktop, ulemmingapp, ulemmingaudio, ulemmingrender;

type
  PGtkStatusIcon = Pointer;
  TXDisplay = Pointer;
  TXWindow = culong;
  PXWindow = ^TXWindow;
  TXAtom = culong;
  TXWindowAttributes = record
    x, y: cint;
    width, height: cint;
    border_width: cint;
    depth: cint;
    visual: Pointer;
    root: TXWindow;
    class_: cint;
    bit_gravity: cint;
    win_gravity: cint;
    backing_store: cint;
    backing_planes: culong;
    backing_pixel: culong;
    save_under: cint;
    colormap: culong;
    map_installed: cint;
    map_state: cint;
    all_event_masks: clong;
    your_event_mask: clong;
    do_not_propagate_mask: clong;
    override_redirect: cint;
    screen: Pointer;
  end;

function gtk_status_icon_new: PGtkStatusIcon; cdecl; external;
procedure gtk_status_icon_set_from_pixbuf(icon: PGtkStatusIcon; pixbuf: PGdkPixbuf); cdecl; external;
procedure gtk_status_icon_set_visible(icon: PGtkStatusIcon; visible: gboolean); cdecl; external;
procedure gtk_status_icon_set_tooltip_text(icon: PGtkStatusIcon; text: Pgchar); cdecl; external;
function gtk_widget_get_window(widget: PGtkWidget): PGdkWindow; cdecl; external;
function gdk_screen_get_rgba_colormap(screen: PGdkScreen): PGdkColormap; cdecl; external;
procedure gdk_window_input_shape_combine_region(window: PGdkWindow;
  shape_region: PGdkRegion; offset_x, offset_y: gint); cdecl; external;
procedure gdk_window_shape_combine_region(window: PGdkWindow;
  shape_region: PGdkRegion; offset_x, offset_y: gint); cdecl; external;
function gdk_x11_get_default_xdisplay: TXDisplay; cdecl; external;

function XDefaultRootWindow(dpy: TXDisplay): TXWindow; cdecl; external 'libX11.so.6';
function XInternAtom(dpy: TXDisplay; name: PChar; onlyIfExists: LongInt): TXAtom; cdecl; external 'libX11.so.6';
function XGetWindowProperty(dpy: TXDisplay; w: TXWindow; prop: TXAtom;
  long_offset, long_length: clong; delete: LongInt; req_type: TXAtom;
  actual_type: Pointer; actual_format: Pointer; nitems: Pointer;
  bytes_after: Pointer; prop_return: Pointer): cint; cdecl; external 'libX11.so.6';
function XGetWindowAttributes(dpy: TXDisplay; w: TXWindow; attr: Pointer): cint; cdecl; external 'libX11.so.6';
function XFree(p: Pointer): cint; cdecl; external 'libX11.so.6';
function XGetSelectionOwner(dpy: TXDisplay; selection: TXAtom): TXWindow; cdecl; external 'libX11.so.6';
function XTranslateCoordinates(dpy: TXDisplay; src, dest: TXWindow;
  src_x, src_y: cint; dest_x, dest_y: Pcint; child_return: Pointer): LongInt;
  cdecl; external 'libX11.so.6';
function gdk_x11_drawable_get_xid(drawable: PGdkDrawable): TXWindow; cdecl; external;

const
  BarW = 24;
  BarH = 24;
  TickMs = 33;
  XA_WINDOW = 33;
  XA_CARDINAL = 6;
  XIsViewable = 2;
  { Pixels below this stay out of the 1-bit mask and are not blitted. Ledge
    outlines are ~0.35 (89), so 48 keeps them without the AA fringe. }
  ShapeAlpha = 48;

var
  Controller: TLemmingsController;
  Overlay: PGtkWidget;
  DrawArea: PGtkWidget;
  StatusIcon: PGtkStatusIcon;
  TrayWin: PGtkWidget;
  TrayBadge: PGdkPixbuf;
  OverlayPix: PGdkPixbuf;
  BarPix: PGdkPixbuf;
  OverlayPm: PGdkPixmap;
  OverlayPmW, OverlayPmH: Integer;
  SfxWav: array[sfxTrudge..sfxYippee] of TBytes;
  SfxPath: array[sfxTrudge..sfxYippee] of string;
  LastTrudge: QWord;
  Popup: PGtkWidget;
  OverlayXid: TXWindow;
  ScreenWpx, ScreenHpx: Integer;
  NeedShapeMask: Boolean;
  PanelTopPx: Integer;

procedure DestroyPix(var Pix: PGdkPixbuf);
begin
  if Pix <> nil then
  begin
    g_object_unref(Pix);
    Pix := nil;
  end;
end;

procedure EnsurePix(var Pix: PGdkPixbuf; W, H: Integer);
begin
  if (W < 1) or (H < 1) then
    Exit;
  if (Pix <> nil) and (gdk_pixbuf_get_width(Pix) = W) and
     (gdk_pixbuf_get_height(Pix) = H) then
    Exit;
  DestroyPix(Pix);
  Pix := gdk_pixbuf_new(GDK_COLORSPACE_RGB, True, 8, W, H);
end;

procedure PixbufFromBuffer(Pix: PGdkPixbuf; Buf: TPixelBuffer);
var
  Pixels: PByte;
  Row: Integer;
  Src, Dst: PByte;
  BufW: Integer;
begin
  if Pix = nil then
    Exit;
  BufW := Buf.Width;
  Pixels := PByte(gdk_pixbuf_get_pixels(Pix));
  for Row := 0 to Buf.Height - 1 do
  begin
    Src := Buf.Ptr + Row * BufW * 4;
    Dst := Pixels + Row * gdk_pixbuf_get_rowstride(Pix);
    Move(Src^, Dst^, BufW * 4);
  end;
end;

procedure WriteSfxFiles;
var
  Kind: TSfxKind;
  Path: string;
  F: File;
begin
  for Kind := sfxTrudge to sfxYippee do
  begin
    SfxWav[Kind] := BuildSfxWav(Kind);
    Path := IncludeTrailingPathDelimiter(GetTempDir) + 'lemming-' + SfxName(Kind) + '.wav';
    SfxPath[Kind] := Path;
    AssignFile(F, Path);
    Rewrite(F, 1);
    if Length(SfxWav[Kind]) > 0 then
      BlockWrite(F, SfxWav[Kind][0], Length(SfxWav[Kind]));
    CloseFile(F);
  end;
end;

procedure PlaySfx(Kind: TSfxKind);
var
  Cmd: string;
begin
  if (Kind < sfxTrudge) or (Kind > sfxYippee) then
    Exit;
  if SfxPath[Kind] = '' then
    Exit;
  Cmd := '(paplay ' + SfxPath[Kind] + ' || aplay -q ' + SfxPath[Kind] +
    ') >/dev/null 2>&1 &';
  fpSystem(Cmd);
end;

procedure DrainAudio;
var
  Kind: TSfxKind;
  NowMs: QWord;
begin
  if Controller = nil then
    Exit;
  if Controller.Model.Config.Muted then
  begin
    while Controller.Model.DrainSfx(Kind) do
      ;
    Exit;
  end;
  NowMs := GetTickCount64;
  while Controller.Model.DrainSfx(Kind) do
  begin
    if Kind = sfxTrudge then
    begin
      if NowMs - LastTrudge < 100 then
        Continue;
      LastTrudge := NowMs;
    end;
    PlaySfx(Kind);
  end;
end;

procedure CollectX11Windows(var Desk: TDeskSnapshot);
var
  Dpy: TXDisplay;
  Root: TXWindow;
  I: Integer;
  Attr: TXWindowAttributes;
  AtomList, AtomType: TXAtom;
  Format: cint;
  NItems, BytesAfter: culong;
  Prop: Pointer;
  Wins: PXWindow;
  Win, Child: TXWindow;
  RootX, RootY: cint;
begin
  Dpy := gdk_x11_get_default_xdisplay;
  if Dpy = nil then
    Exit;
  Root := XDefaultRootWindow(Dpy);
  AtomList := XInternAtom(Dpy, '_NET_CLIENT_LIST', 0);
  Prop := nil;
  if XGetWindowProperty(Dpy, Root, AtomList, 0, 256, 0, XA_WINDOW,
     @AtomType, @Format, @NItems, @BytesAfter, @Prop) <> 0 then
    Exit;
  if (Prop = nil) or (NItems = 0) then
  begin
    if Prop <> nil then
      XFree(Prop);
    Exit;
  end;
  Wins := PXWindow(Prop);
  for I := 0 to Integer(NItems) - 1 do
  begin
    Win := Wins[I];
    if (OverlayXid <> 0) and (Win = OverlayXid) then
      Continue;
    FillChar(Attr, SizeOf(Attr), 0);
    if XGetWindowAttributes(Dpy, Win, @Attr) = 0 then
      Continue;
    if Attr.map_state <> XIsViewable then
      Continue;
    if Attr.override_redirect <> 0 then
      Continue;
    { Client x/y are relative to the WM frame; ledges need root coords. }
    RootX := Attr.x;
    RootY := Attr.y;
    Child := 0;
    XTranslateCoordinates(Dpy, Win, Root, 0, 0, @RootX, @RootY, @Child);
    if (Attr.width < 80) or (Attr.height < 48) then
      Continue;
    { Fullscreen clients (including this overlay) are not walkable floors. }
    if (Attr.width >= ScreenWpx - 8) and (Attr.height >= ScreenHpx - 8) then
      Continue;
    AddDeskRect(Desk, Integer(Win), RootX, RootY, Attr.width, Attr.height, dkWindow);
  end;
  XFree(Prop);
end;

procedure CollectDesktop;
var
  Desk: TDeskSnapshot;
  Screen: PGdkScreen;
  W, H, WinBefore: Integer;
begin
  if Controller = nil then
    Exit;
  Screen := gdk_screen_get_default;
  W := gdk_screen_get_width(Screen);
  H := gdk_screen_get_height(Screen);
  Controller.Resize(W, H);
  ScreenWpx := W;
  ScreenHpx := H;
  ClearDesktop(Desk, Controller.Overlay.Width, Controller.Overlay.Height);
  AddDeskRect(Desk, 8001, 0, 24, Desk.ScreenW, 6, dkScreenTop);
  { Always a floor: without it, walkers who land at ScreenH bounce fall/walk. }
  AddDeskRect(Desk, 8002, 0, Desk.ScreenH - 48, Desk.ScreenW, 48, dkDock);
  WinBefore := Desk.Count;
  CollectX11Windows(Desk);
  if Desk.Count <= WinBefore then
    Desk := MakeFallbackDesktop(Desk.ScreenW, Desk.ScreenH);
  Controller.SetDesktop(Desk);
end;

function WindowCardinalAt(Dpy: TXDisplay; Win: TXWindow; Name: PChar;
  Index: Integer): Integer;
var
  Atom, AtomType: TXAtom;
  Format: cint;
  NItems, BytesAfter: culong;
  Prop: Pointer;
  Vals: pculong;
begin
  Result := -1;
  Atom := XInternAtom(Dpy, Name, 1);
  if Atom = 0 then
    Exit;
  Prop := nil;
  if XGetWindowProperty(Dpy, Win, Atom, 0, 16, 0, XA_CARDINAL,
     @AtomType, @Format, @NItems, @BytesAfter, @Prop) <> 0 then
    Exit;
  if (Prop <> nil) and (Integer(NItems) > Index) then
  begin
    Vals := pculong(Prop);
    Result := Integer(Vals[Index]);
  end;
  if Prop <> nil then
    XFree(Prop);
end;

function WindowIsDock(Dpy: TXDisplay; Win: TXWindow): Boolean;
var
  AtomType, AtomDock, GotType: TXAtom;
  Format: cint;
  NItems, BytesAfter: culong;
  Prop: Pointer;
  Atoms: ^TXAtom;
  I: Integer;
begin
  Result := False;
  AtomType := XInternAtom(Dpy, '_NET_WM_WINDOW_TYPE', 1);
  AtomDock := XInternAtom(Dpy, '_NET_WM_WINDOW_TYPE_DOCK', 1);
  if (AtomType = 0) or (AtomDock = 0) then
    Exit;
  Prop := nil;
  { 4 = XA_ATOM }
  if XGetWindowProperty(Dpy, Win, AtomType, 0, 8, 0, 4,
     @GotType, @Format, @NItems, @BytesAfter, @Prop) <> 0 then
    Exit;
  if (Prop <> nil) and (NItems > 0) then
  begin
    Atoms := Prop;
    for I := 0 to Integer(NItems) - 1 do
      if Atoms[I] = AtomDock then
      begin
        Result := True;
        Break;
      end;
  end;
  if Prop <> nil then
    XFree(Prop);
end;

function ReadPanelTop: Integer;
var
  Dpy: TXDisplay;
  Root: TXWindow;
  AtomList, AtomType: TXAtom;
  Format: cint;
  NItems, BytesAfter: culong;
  Prop: Pointer;
  Wins: PXWindow;
  Win, Child: TXWindow;
  I, V, RootX, RootY: Integer;
  Attr: TXWindowAttributes;
begin
  { Use the real panel height. 36px left a white strip over the Pi tray
    (the blank slot sitting above the language icon). }
  Result := 0;
  Dpy := gdk_x11_get_default_xdisplay;
  if Dpy = nil then
    Exit;
  Root := XDefaultRootWindow(Dpy);
  V := WindowCardinalAt(Dpy, Root, '_NET_WORKAREA', 1);
  if V > Result then
    Result := V;
  Prop := nil;
  AtomList := XInternAtom(Dpy, '_NET_CLIENT_LIST', 0);
  if (AtomList <> 0) and (XGetWindowProperty(Dpy, Root, AtomList, 0, 256, 0,
     XA_WINDOW, @AtomType, @Format, @NItems, @BytesAfter, @Prop) = 0) and
     (Prop <> nil) then
  begin
    Wins := PXWindow(Prop);
    for I := 0 to Integer(NItems) - 1 do
    begin
      Win := Wins[I];
      V := WindowCardinalAt(Dpy, Win, '_NET_WM_STRUT_PARTIAL', 2);
      if V < 0 then
        V := WindowCardinalAt(Dpy, Win, '_NET_WM_STRUT', 2);
      if V > Result then
        Result := V;
      FillChar(Attr, SizeOf(Attr), 0);
      if XGetWindowAttributes(Dpy, Win, @Attr) = 0 then
        Continue;
      if Attr.map_state <> XIsViewable then
        Continue;
      RootX := Attr.x;
      RootY := Attr.y;
      Child := 0;
      XTranslateCoordinates(Dpy, Win, Root, 0, 0, @RootX, @RootY, @Child);
      if (RootY <= 4) and (Attr.width >= ScreenWpx - 16) and
         (Attr.height > 8) and (Attr.height <= 96) then
        if Attr.height > Result then
          Result := Attr.height;
      if WindowIsDock(Dpy, Win) and (RootY <= 8) and (Attr.height > Result) and
         (Attr.height <= 96) then
        Result := Attr.height;
    end;
  end;
  if Prop <> nil then
    XFree(Prop);
  if Result < 48 then
    Result := 48;
  if Result > 96 then
    Result := 52;
end;

procedure HardenPixbufAlpha(Pix: PGdkPixbuf; Threshold: Integer);
var
  Pixels, P: PByte;
  W, H, Stride, X, Y: Integer;
begin
  { 1-bit shaped windows cannot composite. Semi-transparent pixels (walker
    edges, ledge outlines) were blended onto black and showed as silhouettes. }
  if (Pix = nil) or (not gdk_pixbuf_get_has_alpha(Pix)) then
    Exit;
  W := gdk_pixbuf_get_width(Pix);
  H := gdk_pixbuf_get_height(Pix);
  Stride := gdk_pixbuf_get_rowstride(Pix);
  Pixels := PByte(gdk_pixbuf_get_pixels(Pix));
  for Y := 0 to H - 1 do
  begin
    P := Pixels + Y * Stride;
    for X := 0 to W - 1 do
    begin
      if P[3] < Threshold then
      begin
        P[0] := 0;
        P[1] := 0;
        P[2] := 0;
        P[3] := 0;
      end
      else
        P[3] := 255;
      Inc(P, 4);
    end;
  end;
end;

procedure HideAllPixels(GdkWin: PGdkWindow);
var
  Region: PGdkRegion;
begin
  { Empty shape: the X window occupies no pixels, so the desktop (and the
    menu bar) stay visible until the first walker frame. }
  if GdkWin = nil then
    Exit;
  Region := gdk_region_new;
  gdk_window_shape_combine_region(GdkWin, Region, 0, 0);
  gdk_region_destroy(Region);
end;

function OverlaySrcY: Integer;
begin
  { The overlay window sits below the panel, so we skip those pixbuf rows. }
  Result := PanelTopPx;
  if Result < 0 then
    Result := 0;
end;

function OverlayViewH(PixH: Integer): Integer;
begin
  Result := PixH - OverlaySrcY;
  if Result < 1 then
    Result := PixH;
end;

function CompositorIsRunning: Boolean;
var
  Dpy: TXDisplay;
  Atom: TXAtom;
begin
  { RGBA visuals without a compositor become an opaque white sheet on the Pi. }
  Result := False;
  Dpy := gdk_x11_get_default_xdisplay;
  if Dpy = nil then
    Exit;
  Atom := XInternAtom(Dpy, '_NET_WM_CM_S0', 1);
  if Atom = 0 then
    Exit;
  Result := XGetSelectionOwner(Dpy, Atom) <> 0;
end;

procedure ShapeToPixbuf(GdkWin: PGdkWindow; Pix: PGdkPixbuf);
var
  Mask: PGdkPixmap;
  DestW, DestH, SrcY: Integer;
begin
  if GdkWin = nil then
    Exit;
  if Pix = nil then
  begin
    HideAllPixels(GdkWin);
    Exit;
  end;
  SrcY := OverlaySrcY;
  DestW := gdk_pixbuf_get_width(Pix);
  DestH := OverlayViewH(gdk_pixbuf_get_height(Pix));
  Mask := gdk_pixmap_new(GdkWin, DestW, DestH, 1);
  if Mask = nil then
    Exit;
  gdk_pixbuf_render_threshold_alpha(Pix, Mask, 0, SrcY, 0, 0, DestW, DestH, ShapeAlpha);
  gdk_window_shape_combine_mask(GdkWin, Mask, 0, 0);
  g_object_unref(Mask);
end;

procedure ShapeOverlayWindows;
var
  TopWin, DrawWin: PGdkWindow;
begin
  { Shape the toplevel. Shaping only the drawing-area child leaves the parent
    as a fullscreen white rectangle over the desktop and menu bar. }
  TopWin := nil;
  DrawWin := nil;
  if Overlay <> nil then
    TopWin := gtk_widget_get_window(Overlay);
  if DrawArea <> nil then
    DrawWin := gtk_widget_get_window(DrawArea);
  if TopWin <> nil then
    ShapeToPixbuf(TopWin, OverlayPix);
  if (DrawWin <> nil) and (DrawWin <> TopWin) then
    ShapeToPixbuf(DrawWin, OverlayPix);
end;

procedure DestroyColorPixmap;
begin
  if OverlayPm <> nil then
  begin
    g_object_unref(OverlayPm);
    OverlayPm := nil;
  end;
  OverlayPmW := 0;
  OverlayPmH := 0;
end;

procedure EnsureColorPixmap(GdkWin: PGdkWindow; W, H: Integer);
begin
  if (GdkWin = nil) or (W < 1) or (H < 1) then
    Exit;
  if (OverlayPm <> nil) and (OverlayPmW = W) and (OverlayPmH = H) then
    Exit;
  DestroyColorPixmap;
  OverlayPm := gdk_pixmap_new(GdkWin, W, H, -1);
  if OverlayPm <> nil then
  begin
    OverlayPmW := W;
    OverlayPmH := H;
  end;
end;

procedure FillColorPixmap;
var
  Gc: PGdkGC;
  Src: Pguchar;
  Stride, SrcY: Integer;
begin
  if (OverlayPm = nil) or (OverlayPix = nil) then
    Exit;
  Gc := gdk_gc_new(OverlayPm);
  if Gc = nil then
    Exit;
  Stride := gdk_pixbuf_get_rowstride(OverlayPix);
  SrcY := OverlaySrcY;
  Src := gdk_pixbuf_get_pixels(OverlayPix);
  if SrcY > 0 then
    Inc(Src, SrcY * Stride);
  gdk_draw_rgb_32_image(OverlayPm, Gc, 0, 0, OverlayPmW, OverlayPmH,
    GDK_RGB_DITHER_NONE, Src, Stride);
  g_object_unref(Gc);
end;

procedure ApplyShapedPixmap(GdkWin: PGdkWindow);
begin
  { Install the colour pixmap as the X background BEFORE reshaping. Expose
    then copies that pixmap instead of filling the GTK theme white — the
    DirectX-style white flicker. }
  if GdkWin = nil then
    Exit;
  if OverlayPm <> nil then
    gdk_window_set_back_pixmap(GdkWin, OverlayPm, False);
  ShapeToPixbuf(GdkWin, OverlayPix);
  if OverlayPm <> nil then
    gdk_window_clear(GdkWin);
end;

procedure PresentShaped;
var
  TopWin, DrawWin: PGdkWindow;
  W, H: Integer;
begin
  if OverlayPix = nil then
    Exit;
  TopWin := nil;
  DrawWin := nil;
  if Overlay <> nil then
    TopWin := gtk_widget_get_window(Overlay);
  if DrawArea <> nil then
    DrawWin := gtk_widget_get_window(DrawArea);
  if TopWin = nil then
    Exit;
  W := gdk_pixbuf_get_width(OverlayPix);
  H := OverlayViewH(gdk_pixbuf_get_height(OverlayPix));
  EnsureColorPixmap(TopWin, W, H);
  FillColorPixmap;
  ApplyShapedPixmap(TopWin);
  if (DrawWin <> nil) and (DrawWin <> TopWin) then
    ApplyShapedPixmap(DrawWin);
end;

procedure PushStatusIcon;
var
  Badge: PGdkPixbuf;
  SW, SH, SS, DS, SD, X, Y: Integer;
  S, D: PByte;
begin
  { RGB (no alpha) badge. lxpanel leaves a blank slot for an RGBA tray
    image, and a keep-above overlay over the panel ate the clicks. }
  if (StatusIcon = nil) or (BarPix = nil) then
    Exit;
  SW := gdk_pixbuf_get_width(BarPix);
  SH := gdk_pixbuf_get_height(BarPix);
  Badge := gdk_pixbuf_new(GDK_COLORSPACE_RGB, False, 8, SW, SH);
  if Badge = nil then
    Exit;
  SS := gdk_pixbuf_get_rowstride(BarPix);
  DS := gdk_pixbuf_get_rowstride(Badge);
  SD := gdk_pixbuf_get_n_channels(Badge);
  for Y := 0 to SH - 1 do
  begin
    S := PByte(gdk_pixbuf_get_pixels(BarPix)) + Y * SS;
    D := PByte(gdk_pixbuf_get_pixels(Badge)) + Y * DS;
    for X := 0 to SW - 1 do
    begin
      if S[3] >= 32 then
      begin
        D[0] := S[0];
        D[1] := S[1];
        D[2] := S[2];
      end
      else
      begin
        D[0] := 48;
        D[1] := 110;
        D[2] := 190;
      end;
      Inc(S, 4);
      Inc(D, SD);
    end;
  end;
  gtk_status_icon_set_from_pixbuf(StatusIcon, Badge);
  { The XEmbed plug was clipping to a few pixels above the language icon,
    off the top of the screen. Keep it hidden; TrayWin is the menu extra. }
  gtk_status_icon_set_visible(StatusIcon, False);
  DestroyPix(TrayBadge);
  TrayBadge := Badge;
  if TrayWin <> nil then
    gtk_widget_queue_draw(TrayWin);
end;

procedure SilenceBackground(Win: PGtkWidget);
var
  GdkWin: PGdkWindow;
begin
  if Win = nil then
    Exit;
  GdkWin := gtk_widget_get_window(Win);
  if GdkWin = nil then
    Exit;
  gdk_window_set_back_pixmap(GdkWin, nil, False);
end;

procedure Present;
begin
  Controller.Render;
  EnsurePix(OverlayPix, Controller.Overlay.Width, Controller.Overlay.Height);
  EnsurePix(BarPix, Controller.Bar.Width, Controller.Bar.Height);
  PixbufFromBuffer(OverlayPix, Controller.Overlay);
  PixbufFromBuffer(BarPix, Controller.Bar);
  if NeedShapeMask then
    HardenPixbufAlpha(OverlayPix, ShapeAlpha);
  Controller.ConsumePresent;
  if NeedShapeMask then
    PresentShaped
  else
  begin
    ShapeOverlayWindows;
    if Overlay <> nil then
      gtk_widget_queue_draw(Overlay);
    if DrawArea <> nil then
      gtk_widget_queue_draw(DrawArea);
  end;
  PushStatusIcon;
end;

procedure OnQuit(Widget: PGtkWidget; Data: gpointer); cdecl;
begin
  gtk_main_quit;
end;

procedure OnAbout(Widget: PGtkWidget; Data: gpointer); cdecl;
var
  Dlg: PGtkWidget;
begin
  Dlg := gtk_message_dialog_new(nil, GTK_DIALOG_MODAL, GTK_MESSAGE_INFO,
    GTK_BUTTONS_OK, PChar(LemmingsAboutText));
  gtk_window_set_title(PGtkWindow(Dlg), LemmingsAboutTitle);
  gtk_dialog_run(PGtkDialog(Dlg));
  gtk_widget_destroy(Dlg);
end;

procedure OnPause(Widget: PGtkWidget; Data: gpointer); cdecl;
begin
  Controller.ApplyChar(' ');
end;

procedure OnMute(Widget: PGtkWidget; Data: gpointer); cdecl;
begin
  Controller.ApplyChar('M');
end;

procedure OnMore(Widget: PGtkWidget; Data: gpointer); cdecl;
begin
  Controller.ApplyChar(']');
end;

procedure OnFewer(Widget: PGtkWidget; Data: gpointer); cdecl;
begin
  Controller.ApplyChar('[');
end;

procedure OnLedges(Widget: PGtkWidget; Data: gpointer); cdecl;
begin
  Controller.ApplyChar('D');
end;

procedure OnHud(Widget: PGtkWidget; Data: gpointer); cdecl;
begin
  Controller.ApplyChar('H');
end;

function BuildPopup: PGtkWidget;
var
  Menu, Item: PGtkWidget;
begin
  { Linux FPC gtk2 has TGCallback (glib GCallback), not TG_SIGNAL_FUNC. }
  Menu := gtk_menu_new;
  Item := gtk_menu_item_new_with_label('Pause / Resume');
  g_signal_connect(G_OBJECT(Item), 'activate', TGCallback(@OnPause), nil);
  gtk_menu_shell_append(PGtkMenuShell(Menu), Item);
  Item := gtk_menu_item_new_with_label('Mute Sounds');
  g_signal_connect(G_OBJECT(Item), 'activate', TGCallback(@OnMute), nil);
  gtk_menu_shell_append(PGtkMenuShell(Menu), Item);
  Item := gtk_separator_menu_item_new;
  gtk_menu_shell_append(PGtkMenuShell(Menu), Item);
  Item := gtk_menu_item_new_with_label('More Lemmings');
  g_signal_connect(G_OBJECT(Item), 'activate', TGCallback(@OnMore), nil);
  gtk_menu_shell_append(PGtkMenuShell(Menu), Item);
  Item := gtk_menu_item_new_with_label('Fewer Lemmings');
  g_signal_connect(G_OBJECT(Item), 'activate', TGCallback(@OnFewer), nil);
  gtk_menu_shell_append(PGtkMenuShell(Menu), Item);
  Item := gtk_menu_item_new_with_label('Show Ledges');
  g_signal_connect(G_OBJECT(Item), 'activate', TGCallback(@OnLedges), nil);
  gtk_menu_shell_append(PGtkMenuShell(Menu), Item);
  Item := gtk_menu_item_new_with_label('Hide HUD');
  g_signal_connect(G_OBJECT(Item), 'activate', TGCallback(@OnHud), nil);
  gtk_menu_shell_append(PGtkMenuShell(Menu), Item);
  Item := gtk_separator_menu_item_new;
  gtk_menu_shell_append(PGtkMenuShell(Menu), Item);
  Item := gtk_menu_item_new_with_label('About Lemmings Overlay');
  g_signal_connect(G_OBJECT(Item), 'activate', TGCallback(@OnAbout), nil);
  gtk_menu_shell_append(PGtkMenuShell(Menu), Item);
  Item := gtk_menu_item_new_with_label('Quit');
  g_signal_connect(G_OBJECT(Item), 'activate', TGCallback(@OnQuit), nil);
  gtk_menu_shell_append(PGtkMenuShell(Menu), Item);
  gtk_widget_show_all(Menu);
  Result := Menu;
end;

procedure OnStatusPopup(Icon: PGtkStatusIcon; Button: guint; ActivateTime: guint32; Data: gpointer); cdecl;
begin
  if Popup = nil then
    Popup := BuildPopup;
  gtk_menu_popup(PGtkMenu(Popup), nil, nil, nil, nil, Button, ActivateTime);
end;

procedure OnStatusActivate(Icon: PGtkStatusIcon; Data: gpointer); cdecl;
begin
  OnStatusPopup(Icon, 0, gtk_get_current_event_time(), Data);
end;

procedure PlaceOverlay;
var
  GdkWin: PGdkWindow;
  H: Integer;
begin
  if Overlay = nil then
    Exit;
  H := ScreenHpx - PanelTopPx;
  if H < 1 then
    H := ScreenHpx;
  gtk_window_move(PGtkWindow(Overlay), 0, PanelTopPx);
  gtk_window_resize(PGtkWindow(Overlay), ScreenWpx, H);
  GdkWin := gtk_widget_get_window(Overlay);
  if GdkWin = nil then
    Exit;
  { libgtk omitted gtk_window_set_override_redirect; GDK still has this. }
  gdk_window_set_override_redirect(GdkWin, 1);
  gdk_window_move(GdkWin, 0, PanelTopPx);
  gdk_window_resize(GdkWin, ScreenWpx, H);
end;

procedure PlaceTray;
var
  X, Y: Integer;
  GdkWin: PGdkWindow;
begin
  if TrayWin = nil then
    Exit;
  X := ScreenWpx - BarW - 8;
  if X < 0 then
    X := 0;
  Y := (PanelTopPx - BarH) div 2;
  if Y < 2 then
    Y := 2;
  if Y + BarH > PanelTopPx then
  begin
    Y := PanelTopPx - BarH - 2;
    if Y < 2 then
      Y := 2;
  end;
  gtk_window_move(PGtkWindow(TrayWin), X, Y);
  gtk_window_resize(PGtkWindow(TrayWin), BarW, BarH);
  GdkWin := gtk_widget_get_window(TrayWin);
  if GdkWin <> nil then
  begin
    gdk_window_set_override_redirect(GdkWin, 1);
    gdk_window_move(GdkWin, X, Y);
    gdk_window_resize(GdkWin, BarW, BarH);
    gdk_window_raise(GdkWin);
  end;
end;

function OnTrayExpose(Widget: PGtkWidget; Event: PGdkEvent; Data: gpointer): gboolean; cdecl;
var
  Gc: PGdkGC;
  W, H: Integer;
begin
  Result := True;
  if (Widget^.window = nil) or (TrayBadge = nil) then
    Exit;
  W := gdk_pixbuf_get_width(TrayBadge);
  H := gdk_pixbuf_get_height(TrayBadge);
  Gc := gdk_gc_new(Widget^.window);
  if Gc = nil then
    Exit;
  gdk_draw_rgb_image(Widget^.window, Gc, 0, 0, W, H, GDK_RGB_DITHER_NONE,
    gdk_pixbuf_get_pixels(TrayBadge), gdk_pixbuf_get_rowstride(TrayBadge));
  g_object_unref(Gc);
end;

function OnTrayClick(Widget: PGtkWidget; Event: PGdkEvent; Data: gpointer): gboolean; cdecl;
begin
  OnStatusPopup(StatusIcon, Event^.button.button, Event^.button.time, Data);
  Result := True;
end;

function OnTick(Data: gpointer): gboolean; cdecl;
begin
  CollectDesktop;
  Controller.Tick;
  DrainAudio;
  if Controller.NeedsPresent then
    Present;
  Result := True;
end;

function OnExpose(Widget: PGtkWidget; Event: PGdkEvent; Data: gpointer): gboolean; cdecl;
begin
  Result := True; { do not let GTK paint the default white/grey background }
  if Widget^.window = nil then
    Exit;
  if NeedShapeMask then
    ApplyShapedPixmap(Widget^.window)
  else
    ShapeOverlayWindows;
end;

procedure MakeClickThrough(Win: PGtkWidget);
var
  Region: PGdkRegion;
  GdkWin: PGdkWindow;
begin
  GdkWin := gtk_widget_get_window(Win);
  if GdkWin = nil then
    Exit;
  Region := gdk_region_new;
  gdk_window_input_shape_combine_region(GdkWin, Region, 0, 0);
  gdk_region_destroy(Region);
end;

procedure MakeOverlayClickThrough;
begin
  { The drawing-area child has its own X window. Shaping only the toplevel
    still lets the child eat clicks on the panel icon. }
  MakeClickThrough(Overlay);
  MakeClickThrough(DrawArea);
end;

procedure OnRealize(Widget: PGtkWidget; Data: gpointer); cdecl;
begin
  { None background + a 1-bit shape leaves unpainted pixels as stale VRAM. }
  if not NeedShapeMask then
    SilenceBackground(Widget);
  MakeOverlayClickThrough;
  { Do not punch an empty hole if the first frame is already in OverlayPix —
    show_all can realize the drawing area after Present. }
  if OverlayPix = nil then
  begin
    if gtk_widget_get_window(Widget) <> nil then
      HideAllPixels(gtk_widget_get_window(Widget));
  end
  else
    ShapeOverlayWindows;
end;

function OnMap(Widget: PGtkWidget; Event: PGdkEvent; Data: gpointer): gboolean; cdecl;
var
  GdkWin: PGdkWindow;
begin
  MakeOverlayClickThrough;
  if not NeedShapeMask then
  begin
    SilenceBackground(Overlay);
    SilenceBackground(DrawArea);
  end;
  GdkWin := gtk_widget_get_window(Widget);
  if GdkWin <> nil then
    OverlayXid := gdk_x11_drawable_get_xid(GdkWin);
  { Re-apply walker shape if Present already ran; otherwise stay empty. }
  ShapeOverlayWindows;
  Result := False;
end;

procedure HostRun;
var
  Screen: PGdkScreen;
  Colormap: PGdkColormap;
  W, H: Integer;
begin
  gtk_init(@argc, @argv);
  LastTrudge := 0;
  OverlayPix := nil;
  BarPix := nil;
  TrayBadge := nil;
  TrayWin := nil;
  OverlayPm := nil;
  OverlayPmW := 0;
  OverlayPmH := 0;
  Popup := nil;
  OverlayXid := 0;
  Screen := gdk_screen_get_default;
  W := gdk_screen_get_width(Screen);
  H := gdk_screen_get_height(Screen);
  ScreenWpx := W;
  ScreenHpx := H;
  NeedShapeMask := not CompositorIsRunning;
  PanelTopPx := ReadPanelTop;
  WriteSfxFiles;

  Controller := TLemmingsController.Create(W, H, BarW, BarH, LoadConfig);

  { Embed the tray icon before the fullscreen overlay exists. Some panels
    drop GtkStatusIcon once a keep-above screen-sized window is mapped. }
  StatusIcon := gtk_status_icon_new;
  gtk_status_icon_set_tooltip_text(StatusIcon, 'Lemmings Overlay');
  gtk_status_icon_set_visible(StatusIcon, False);
  g_signal_connect(G_OBJECT(StatusIcon), 'popup-menu', TGCallback(@OnStatusPopup), nil);
  g_signal_connect(G_OBJECT(StatusIcon), 'activate', TGCallback(@OnStatusActivate), nil);

  TrayWin := gtk_window_new(GTK_WINDOW_TOPLEVEL);
  gtk_window_set_title(PGtkWindow(TrayWin), 'Lemmings Overlay');
  gtk_window_set_decorated(PGtkWindow(TrayWin), False);
  gtk_window_set_keep_above(PGtkWindow(TrayWin), True);
  gtk_window_set_skip_taskbar_hint(PGtkWindow(TrayWin), True);
  gtk_window_set_skip_pager_hint(PGtkWindow(TrayWin), True);
  gtk_window_set_accept_focus(PGtkWindow(TrayWin), False);
  gtk_widget_set_app_paintable(TrayWin, True);
  gtk_widget_set_double_buffered(TrayWin, False);
  gtk_widget_add_events(TrayWin, GDK_BUTTON_PRESS_MASK);
  gtk_window_resize(PGtkWindow(TrayWin), BarW, BarH);
  g_signal_connect(G_OBJECT(TrayWin), 'expose-event', TGCallback(@OnTrayExpose), nil);
  g_signal_connect(G_OBJECT(TrayWin), 'button-press-event', TGCallback(@OnTrayClick), nil);
  Controller.Render;
  EnsurePix(BarPix, Controller.Bar.Width, Controller.Bar.Height);
  PixbufFromBuffer(BarPix, Controller.Bar);
  PushStatusIcon;

  Overlay := gtk_window_new(GTK_WINDOW_TOPLEVEL);
  gtk_window_set_title(PGtkWindow(Overlay), 'Lemmings Overlay');
  gtk_window_set_decorated(PGtkWindow(Overlay), False);
  gtk_window_set_keep_above(PGtkWindow(Overlay), True);
  gtk_window_set_skip_taskbar_hint(PGtkWindow(Overlay), True);
  gtk_window_set_skip_pager_hint(PGtkWindow(Overlay), True);
  gtk_window_set_accept_focus(PGtkWindow(Overlay), False);
  gtk_widget_set_app_paintable(Overlay, True);
  gtk_widget_set_double_buffered(Overlay, False);
  { Only use ARGB if a compositor is actually compositing. On the Pi the
    rgba colormap exists but is painted as an opaque white screen. }
  if not NeedShapeMask then
  begin
    Colormap := gdk_screen_get_rgba_colormap(Screen);
    if Colormap <> nil then
      gtk_widget_set_colormap(Overlay, Colormap);
  end;
  gtk_window_move(PGtkWindow(Overlay), 0, PanelTopPx);
  gtk_window_resize(PGtkWindow(Overlay), W, H - PanelTopPx);
  g_signal_connect(G_OBJECT(Overlay), 'delete-event', TGCallback(@OnQuit), nil);
  g_signal_connect(G_OBJECT(Overlay), 'map-event', TGCallback(@OnMap), nil);
  g_signal_connect(G_OBJECT(Overlay), 'realize', TGCallback(@OnRealize), nil);
  g_signal_connect(G_OBJECT(Overlay), 'expose-event', TGCallback(@OnExpose), nil);

  DrawArea := gtk_drawing_area_new;
  gtk_widget_set_app_paintable(DrawArea, True);
  gtk_widget_set_double_buffered(DrawArea, False);
  gtk_container_add(PGtkContainer(Overlay), DrawArea);
  g_signal_connect(G_OBJECT(DrawArea), 'realize', TGCallback(@OnRealize), nil);
  g_signal_connect(G_OBJECT(DrawArea), 'expose-event', TGCallback(@OnExpose), nil);

  g_timeout_add(TickMs, TGSourceFunc(@OnTick), nil);
  { Realize first so we can punch an empty shape before the window maps.
    Otherwise the first frames are a white sheet over the desktop/panel. }
  gtk_widget_realize(Overlay);
  gtk_widget_realize(DrawArea);
  PlaceOverlay;
  if not NeedShapeMask then
  begin
    SilenceBackground(Overlay);
    SilenceBackground(DrawArea);
  end;
  if gtk_widget_get_window(Overlay) <> nil then
    HideAllPixels(gtk_widget_get_window(Overlay));
  if gtk_widget_get_window(DrawArea) <> nil then
    HideAllPixels(gtk_widget_get_window(DrawArea));
  CollectDesktop;
  Present;
  gtk_widget_show_all(Overlay);
  MakeOverlayClickThrough;
  if NeedShapeMask then
    PresentShaped
  else
    ShapeOverlayWindows;
  gtk_widget_realize(TrayWin);
  PlaceTray;
  gtk_widget_show_all(TrayWin);
  PlaceTray;
  gtk_main;
  DestroyPix(OverlayPix);
  DestroyPix(BarPix);
  DestroyPix(TrayBadge);
  DestroyColorPixmap;
  Controller.Free;
end;

{$ELSE}

procedure HostRun;
begin
end;

{$ENDIF}

end.
