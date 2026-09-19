unit uhostwin;

{$mode objfpc}{$H+}

{ Windows layered click-through overlay + tray icon. Same
  TLemmingsController as macOS; this unit presents BGRA pixels with
  UpdateLayeredWindow, enumerates HWNDs, and plays original WAV stings. }

interface

procedure HostRun;

implementation

{$IFDEF WINDOWS}

uses
  Windows, Messages, ShellAPI, SysUtils, MMSystem, ulemmingconfig,
  ulemmingdesktop, ulemmingapp, ulemmingaudio, ulemmingrender;

{ FPC 3.2.2's Win32 Windows unit does not publish MonitorFromWindow /
  UpdateLayeredWindow / TMonitorInfo. Eyes avoids those APIs; we declare
  only the layered-window call and size the overlay with GetSystemMetrics. }

type
  TOverlaySize = packed record
    cx, cy: LongInt;
  end;
  TBlendFn = packed record
    BlendOp, BlendFlags, SourceConstantAlpha, AlphaFormat: Byte;
  end;
  TTrayIconData = packed record
    cbSize: DWORD;
    Wnd: HWND;
    uID: UINT;
    uFlags: UINT;
    uCallbackMessage: UINT;
    hIcon: HICON;
    szTip: array[0..63] of AnsiChar;
  end;

const
  AppName = 'LemmingsOverlayWnd';
  WmTray = WM_APP + 42;
  IdTray = 1;
  CmdPause = 1001;
  CmdMute = 1002;
  CmdMore = 1003;
  CmdFewer = 1004;
  CmdLedges = 1005;
  CmdHud = 1006;
  CmdAbout = 1007;
  CmdQuit = 1008;
  BarW = 32;
  BarH = 32;
  TickId = 1;
  TickMs = 33;
  UlwAlpha = 2;
  AcSrcOver = 0;
  AcSrcAlpha = 1;

function UpdateLayeredWindow(Wnd: HWND; hdcDst: HDC; pptDst: PPoint;
  psize: Pointer; hdcSrc: HDC; pptSrc: PPoint; crKey: COLORREF;
  pblend: Pointer; dwFlags: DWORD): BOOL; stdcall; external 'user32.dll' name 'UpdateLayeredWindow';

function ShellNotifyIcon(dwMessage: DWORD; lpData: Pointer): BOOL; stdcall;
  external 'shell32.dll' name 'Shell_NotifyIconA';

var
  Controller: TLemmingsController;
  OverlayWnd: HWND;
  TrayIcon: TTrayIconData;
  Bgra: array of Byte;
  SfxWav: array[sfxTrudge..sfxYippee] of TBytes;
  LastTrudge: QWord;
  SfxHold: array[0..5] of TBytes;
  SfxSlot: Integer;

function EnumAddWindow(Wnd: HWND; LParam: LPARAM): BOOL; stdcall;
var
  Desk: ^TDeskSnapshot;
  R, OverlayR: TRect;
  Ex: LONG;
  W, H: Integer;
begin
  Result := True;
  Desk := Pointer(LParam);
  if Wnd = OverlayWnd then
    Exit;
  if not IsWindowVisible(Wnd) then
    Exit;
  if IsIconic(Wnd) then
    Exit;
  Ex := GetWindowLong(Wnd, GWL_EXSTYLE);
  if (Ex and WS_EX_TOOLWINDOW) <> 0 then
    Exit;
  if not GetWindowRect(Wnd, R) then
    Exit;
  W := R.Right - R.Left;
  H := R.Bottom - R.Top;
  if (W < 80) or (H < 48) then
    Exit;
  if GetWindowRect(OverlayWnd, OverlayR) then
  begin
    { Translate into overlay-client pixels (primary-monitor overlay). }
    AddDeskRect(Desk^, Integer(Wnd),
      R.Left - OverlayR.Left, R.Top - OverlayR.Top, W, H, dkWindow);
  end
  else
    AddDeskRect(Desk^, Integer(Wnd), R.Left, R.Top, W, H, dkWindow);
end;

procedure CollectDesktop;
var
  Desk: TDeskSnapshot;
  Work: TRect;
  ScreenW, ScreenH, TaskH: Integer;
  WinCount: Integer;
begin
  if Controller = nil then
    Exit;
  ClearDesktop(Desk, Controller.Overlay.Width, Controller.Overlay.Height);
  ScreenW := GetSystemMetrics(SM_CXSCREEN);
  ScreenH := GetSystemMetrics(SM_CYSCREEN);
  FillChar(Work, SizeOf(Work), 0);
  if SystemParametersInfo(SPI_GETWORKAREA, 0, @Work, 0) then
  begin
    TaskH := ScreenH - Work.Bottom;
    if TaskH > 8 then
      AddDeskRect(Desk, 8002, 0, Desk.ScreenH - TaskH, Desk.ScreenW, TaskH, dkDock);
    if Work.Top > 2 then
      AddDeskRect(Desk, 8001, 0, Work.Top, Desk.ScreenW, 6, dkScreenTop);
  end;
  WinCount := Desk.Count;
  EnumWindows(@EnumAddWindow, LPARAM(@Desk));
  if Desk.Count <= WinCount then
    Desk := MakeFallbackDesktop(Desk.ScreenW, Desk.ScreenH);
  Controller.SetDesktop(Desk);
end;

procedure PlaySfx(Kind: TSfxKind);
begin
  if (Kind < sfxTrudge) or (Kind > sfxYippee) then
    Exit;
  if Length(SfxWav[Kind]) < 44 then
    Exit;
  SfxHold[SfxSlot] := SfxWav[Kind];
  PlaySound(PChar(@SfxHold[SfxSlot][0]), 0, SND_MEMORY or SND_ASYNC or SND_NODEFAULT);
  SfxSlot := (SfxSlot + 1) mod Length(SfxHold);
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

procedure PresentLayered(Wnd: HWND);
var
  ScreenDC, MemDC: HDC;
  Info: BITMAPINFO;
  Bits: Pointer;
  Dib, Old: HBITMAP;
  Blend: TBlendFn;
  LayerSize: TOverlaySize;
  SrcPt, DstPt: TPoint;
  R: TRect;
begin
  Controller.Render;
  SetLength(Bgra, Controller.Overlay.Width * Controller.Overlay.Height * 4);
  CopyBGRA(Controller.Overlay, @Bgra[0]);
  Controller.ConsumePresent;

  FillChar(Info, SizeOf(Info), 0);
  Info.bmiHeader.biSize := SizeOf(BITMAPINFOHEADER);
  Info.bmiHeader.biWidth := Controller.Overlay.Width;
  Info.bmiHeader.biHeight := -Controller.Overlay.Height;
  Info.bmiHeader.biPlanes := 1;
  Info.bmiHeader.biBitCount := 32;
  Info.bmiHeader.biCompression := BI_RGB;

  ScreenDC := GetDC(0);
  MemDC := CreateCompatibleDC(ScreenDC);
  Bits := nil;
  Dib := CreateDIBSection(ScreenDC, Info, DIB_RGB_COLORS, Bits, 0, 0);
  Old := SelectObject(MemDC, Dib);
  if (Bits <> nil) and (Length(Bgra) > 0) then
    Move(Bgra[0], Bits^, Length(Bgra));

  GetWindowRect(Wnd, R);
  LayerSize.cx := Controller.Overlay.Width;
  LayerSize.cy := Controller.Overlay.Height;
  SrcPt.X := 0;
  SrcPt.Y := 0;
  DstPt.X := R.Left;
  DstPt.Y := R.Top;
  FillChar(Blend, SizeOf(Blend), 0);
  Blend.BlendOp := AcSrcOver;
  Blend.SourceConstantAlpha := 255;
  Blend.AlphaFormat := AcSrcAlpha;
  UpdateLayeredWindow(Wnd, ScreenDC, @DstPt, @LayerSize, MemDC, @SrcPt, 0, @Blend, UlwAlpha);

  SelectObject(MemDC, Old);
  if Dib <> 0 then
    DeleteObject(Dib);
  DeleteDC(MemDC);
  ReleaseDC(0, ScreenDC);

  { Tray icon from the bar buffer. }
  if Length(Bgra) > 0 then
  begin
    { Recreate a small icon from Bar each tick would flicker; skip unless needed. }
  end;
end;

procedure UpdateTrayIcon;
var
  Icon: HICON;
  Info: BITMAPINFO;
  Bits: Pointer;
  DC: HDC;
  Dib, Mask: HBITMAP;
  II: TIconInfo;
  BgraBar: array of Byte;
begin
  Controller.Render;
  SetLength(BgraBar, Controller.Bar.Width * Controller.Bar.Height * 4);
  CopyBGRA(Controller.Bar, @BgraBar[0]);
  FillChar(Info, SizeOf(Info), 0);
  Info.bmiHeader.biSize := SizeOf(BITMAPINFOHEADER);
  Info.bmiHeader.biWidth := Controller.Bar.Width;
  Info.bmiHeader.biHeight := -Controller.Bar.Height;
  Info.bmiHeader.biPlanes := 1;
  Info.bmiHeader.biBitCount := 32;
  Info.bmiHeader.biCompression := BI_RGB;
  DC := GetDC(0);
  Bits := nil;
  Dib := CreateDIBSection(DC, Info, DIB_RGB_COLORS, Bits, 0, 0);
  if (Dib <> 0) and (Bits <> nil) then
    Move(BgraBar[0], Bits^, Length(BgraBar));
  Mask := CreateBitmap(Controller.Bar.Width, Controller.Bar.Height, 1, 1, nil);
  FillChar(II, SizeOf(II), 0);
  II.fIcon := True;
  II.hbmMask := Mask;
  II.hbmColor := Dib;
  Icon := CreateIconIndirect(II);
  if TrayIcon.hIcon <> 0 then
    DestroyIcon(TrayIcon.hIcon);
  TrayIcon.hIcon := Icon;
  TrayIcon.uFlags := NIF_ICON or NIF_MESSAGE or NIF_TIP;
  ShellNotifyIcon(NIM_MODIFY, @TrayIcon);
  if Dib <> 0 then
    DeleteObject(Dib);
  if Mask <> 0 then
    DeleteObject(Mask);
  ReleaseDC(0, DC);
end;

procedure CoverPrimary(Wnd: HWND);
var
  ScreenW, ScreenH: Integer;
begin
  ScreenW := GetSystemMetrics(SM_CXSCREEN);
  ScreenH := GetSystemMetrics(SM_CYSCREEN);
  if ScreenW < 1 then
    ScreenW := 800;
  if ScreenH < 1 then
    ScreenH := 500;
  SetWindowPos(Wnd, HWND_TOPMOST, 0, 0, ScreenW, ScreenH, SWP_SHOWWINDOW);
  Controller.Resize(ScreenW, ScreenH);
end;

procedure ShowAbout(Wnd: HWND);
begin
  MessageBox(Wnd, PChar(LemmingsAboutText), LemmingsAboutTitle, MB_OK or MB_ICONINFORMATION);
end;

procedure PopupMenuAtCursor(Wnd: HWND);
var
  Menu: HMENU;
  Pt: TPoint;
begin
  Menu := CreatePopupMenu;
  AppendMenu(Menu, MF_STRING, CmdPause, PChar('&Pause / Resume'));
  AppendMenu(Menu, MF_STRING, CmdMute, PChar('&Mute Sounds'));
  AppendMenu(Menu, MF_SEPARATOR, 0, nil);
  AppendMenu(Menu, MF_STRING, CmdMore, PChar('&More Lemmings'));
  AppendMenu(Menu, MF_STRING, CmdFewer, PChar('&Fewer Lemmings'));
  AppendMenu(Menu, MF_STRING, CmdLedges, PChar('Show &Ledges'));
  AppendMenu(Menu, MF_STRING, CmdHud, PChar('Hide &HUD'));
  AppendMenu(Menu, MF_SEPARATOR, 0, nil);
  AppendMenu(Menu, MF_STRING, CmdAbout, PChar('&About...'));
  AppendMenu(Menu, MF_STRING, CmdQuit, PChar('E&xit'));
  GetCursorPos(Pt);
  SetForegroundWindow(Wnd);
  TrackPopupMenu(Menu, TPM_RIGHTBUTTON, Pt.X, Pt.Y, 0, Wnd, nil);
  DestroyMenu(Menu);
end;

function WndProc(Wnd: HWND; Msg: UINT; WParam: WPARAM; LParam: LPARAM): LRESULT; stdcall;
begin
  Result := 0;
  case Msg of
    WM_CREATE:
      begin
        OverlayWnd := Wnd;
        SetTimer(Wnd, TickId, TickMs, nil);
        CoverPrimary(Wnd);
        CollectDesktop;
        PresentLayered(Wnd);
      end;
    WM_TIMER:
      if WParam = TickId then
      begin
        CoverPrimary(Wnd);
        CollectDesktop;
        Controller.Tick;
        DrainAudio;
        if Controller.NeedsPresent then
          PresentLayered(Wnd);
      end;
    WM_COMMAND:
      case LOWORD(WParam) of
        CmdPause: Controller.ApplyChar(' ');
        CmdMute: Controller.ApplyChar('M');
        CmdMore: Controller.ApplyChar(']');
        CmdFewer: Controller.ApplyChar('[');
        CmdLedges: Controller.ApplyChar('D');
        CmdHud: Controller.ApplyChar('H');
        CmdAbout: ShowAbout(Wnd);
        CmdQuit: PostQuitMessage(0);
      end;
    WmTray:
      if LParam = WM_RBUTTONUP then
        PopupMenuAtCursor(Wnd);
    WM_DESTROY:
      begin
        KillTimer(Wnd, TickId);
        ShellNotifyIcon(NIM_DELETE, @TrayIcon);
        PlaySound(nil, 0, 0);
        PostQuitMessage(0);
      end;
    else
      Result := DefWindowProc(Wnd, Msg, WParam, LParam);
  end;
end;

procedure HostRun;
var
  WC: WNDCLASS;
  Msg: TMsg;
  Kind: TSfxKind;
  Ex: DWORD;
begin
  LastTrudge := 0;
  SfxSlot := 0;
  for Kind := sfxTrudge to sfxYippee do
    SfxWav[Kind] := BuildSfxWav(Kind);

  Controller := TLemmingsController.Create(800, 500, BarW, BarH, LoadConfig);

  FillChar(WC, SizeOf(WC), 0);
  WC.lpfnWndProc := @WndProc;
  WC.hInstance := HInstance;
  WC.hCursor := LoadCursor(0, IDC_ARROW);
  WC.lpszClassName := AppName;
  WC.hbrBackground := 0;
  RegisterClass(WC);

  Ex := WS_EX_LAYERED or WS_EX_TRANSPARENT or WS_EX_TOPMOST or WS_EX_TOOLWINDOW;
  OverlayWnd := CreateWindowEx(Ex, AppName, 'Lemmings Overlay',
    WS_POPUP,
    0, 0, 800, 500,
    0, 0, HInstance, nil);

  FillChar(TrayIcon, SizeOf(TrayIcon), 0);
  TrayIcon.cbSize := SizeOf(TrayIcon);
  TrayIcon.Wnd := OverlayWnd;
  TrayIcon.uID := IdTray;
  TrayIcon.uFlags := NIF_MESSAGE or NIF_TIP;
  TrayIcon.uCallbackMessage := WmTray;
  FillChar(TrayIcon.szTip, SizeOf(TrayIcon.szTip), 0);
  StrPLCopy(@TrayIcon.szTip[0], 'Lemmings Overlay', High(TrayIcon.szTip));
  ShellNotifyIcon(NIM_ADD, @TrayIcon);
  UpdateTrayIcon;

  ShowWindow(OverlayWnd, SW_SHOW);

  while GetMessage(Msg, 0, 0, 0) do
  begin
    TranslateMessage(Msg);
    DispatchMessage(Msg);
  end;
  Controller.Free;
end;

{$ELSE}

procedure HostRun;
begin
end;

{$ENDIF}

end.
