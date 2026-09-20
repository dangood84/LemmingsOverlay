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
function gdk_x11_get_default_xdisplay: TXDisplay; cdecl; external;

function XDefaultRootWindow(dpy: TXDisplay): TXWindow; cdecl; external 'libX11.so.6';
function XInternAtom(dpy: TXDisplay; name: PChar; onlyIfExists: LongInt): TXAtom; cdecl; external 'libX11.so.6';
function XGetWindowProperty(dpy: TXDisplay; w: TXWindow; prop: TXAtom;
  long_offset, long_length: clong; delete: LongInt; req_type: TXAtom;
  actual_type: Pointer; actual_format: Pointer; nitems: Pointer;
  bytes_after: Pointer; prop_return: Pointer): cint; cdecl; external 'libX11.so.6';
function XGetWindowAttributes(dpy: TXDisplay; w: TXWindow; attr: Pointer): cint; cdecl; external 'libX11.so.6';
function XFree(p: Pointer): cint; cdecl; external 'libX11.so.6';
function XTranslateCoordinates(dpy: TXDisplay; src, dest: TXWindow;
  src_x, src_y: cint; dest_x, dest_y: Pcint; child_return: Pointer): LongInt;
  cdecl; external 'libX11.so.6';
function gdk_x11_drawable_get_xid(drawable: PGdkDrawable): TXWindow; cdecl; external;

const
  BarW = 24;
  BarH = 24;
  TickMs = 33;
  XA_WINDOW = 33;
  XIsViewable = 2;

var
  Controller: TLemmingsController;
  Overlay: PGtkWidget;
  DrawArea: PGtkWidget;
  StatusIcon: PGtkStatusIcon;
  OverlayPix: PGdkPixbuf;
  BarPix: PGdkPixbuf;
  SfxWav: array[sfxTrudge..sfxYippee] of TBytes;
  SfxPath: array[sfxTrudge..sfxYippee] of string;
  LastTrudge: QWord;
  Popup: PGtkWidget;
  OverlayXid: TXWindow;
  ScreenWpx, ScreenHpx: Integer;

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

procedure Present;
begin
  Controller.Render;
  EnsurePix(OverlayPix, Controller.Overlay.Width, Controller.Overlay.Height);
  EnsurePix(BarPix, Controller.Bar.Width, Controller.Bar.Height);
  PixbufFromBuffer(OverlayPix, Controller.Overlay);
  PixbufFromBuffer(BarPix, Controller.Bar);
  Controller.ConsumePresent;
  if DrawArea <> nil then
    gtk_widget_queue_draw(DrawArea);
  if (StatusIcon <> nil) and (BarPix <> nil) then
    gtk_status_icon_set_from_pixbuf(StatusIcon, BarPix);
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
var
  DestW, DestH: Integer;
  Mask: PGdkPixmap;
begin
  Result := True; { stop GTK filling the overlay with the theme background (white on Pi). }
  if (OverlayPix = nil) or (Widget^.window = nil) then
    Exit;
  DestW := gdk_pixbuf_get_width(OverlayPix);
  DestH := gdk_pixbuf_get_height(OverlayPix);
  { Pi / LXDE usually has no compositor, so RGBA pixels become an opaque white
    sheet. A 1-bit shape mask punches the window to only the walker pixels. }
  Mask := gdk_pixmap_new(Widget^.window, DestW, DestH, 1);
  if Mask <> nil then
  begin
    gdk_pixbuf_render_threshold_alpha(OverlayPix, Mask, 0, 0, 0, 0, DestW, DestH, 12);
    gdk_window_shape_combine_mask(Widget^.window, Mask, 0, 0);
    g_object_unref(Mask);
  end;
  gdk_pixbuf_render_to_drawable(OverlayPix, Widget^.window,
    Widget^.style^.fg_gc[GTK_WIDGET_STATE(Widget)],
    0, 0, 0, 0, DestW, DestH, GDK_RGB_DITHER_NONE, 0, 0);
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

function OnMap(Widget: PGtkWidget; Event: PGdkEvent; Data: gpointer): gboolean; cdecl;
var
  GdkWin: PGdkWindow;
begin
  MakeClickThrough(Widget);
  GdkWin := gtk_widget_get_window(Widget);
  if GdkWin <> nil then
  begin
    gdk_window_set_back_pixmap(GdkWin, nil, False);
    OverlayXid := gdk_x11_drawable_get_xid(GdkWin);
  end;
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
  Popup := nil;
  OverlayXid := 0;
  WriteSfxFiles;

  Screen := gdk_screen_get_default;
  W := gdk_screen_get_width(Screen);
  H := gdk_screen_get_height(Screen);
  ScreenWpx := W;
  ScreenHpx := H;
  Controller := TLemmingsController.Create(W, H, BarW, BarH, LoadConfig);

  Overlay := gtk_window_new(GTK_WINDOW_TOPLEVEL);
  gtk_window_set_title(PGtkWindow(Overlay), 'Lemmings Overlay');
  gtk_window_set_decorated(PGtkWindow(Overlay), False);
  gtk_window_set_keep_above(PGtkWindow(Overlay), True);
  gtk_window_set_skip_taskbar_hint(PGtkWindow(Overlay), True);
  gtk_window_set_skip_pager_hint(PGtkWindow(Overlay), True);
  gtk_window_set_accept_focus(PGtkWindow(Overlay), False);
  gtk_widget_set_app_paintable(Overlay, True);
  Colormap := gdk_screen_get_rgba_colormap(Screen);
  if Colormap <> nil then
    gtk_widget_set_colormap(Overlay, Colormap);
  gtk_window_move(PGtkWindow(Overlay), 0, 0);
  gtk_window_resize(PGtkWindow(Overlay), W, H);
  g_signal_connect(G_OBJECT(Overlay), 'delete-event', TGCallback(@OnQuit), nil);
  g_signal_connect(G_OBJECT(Overlay), 'map-event', TGCallback(@OnMap), nil);

  DrawArea := gtk_drawing_area_new;
  gtk_widget_set_app_paintable(DrawArea, True);
  gtk_container_add(PGtkContainer(Overlay), DrawArea);
  g_signal_connect(G_OBJECT(DrawArea), 'expose-event', TGCallback(@OnExpose), nil);

  StatusIcon := gtk_status_icon_new;
  gtk_status_icon_set_tooltip_text(StatusIcon, 'Lemmings Overlay');
  gtk_status_icon_set_visible(StatusIcon, True);
  g_signal_connect(G_OBJECT(StatusIcon), 'popup-menu', TGCallback(@OnStatusPopup), nil);

  g_timeout_add(TickMs, TGSourceFunc(@OnTick), nil);
  CollectDesktop;
  Present;
  gtk_widget_show_all(Overlay);
  MakeClickThrough(Overlay);
  gtk_main;
  DestroyPix(OverlayPix);
  DestroyPix(BarPix);
  Controller.Free;
end;

{$ELSE}

procedure HostRun;
begin
end;

{$ENDIF}

end.
