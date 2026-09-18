unit ulemmingapp;

{$mode objfpc}{$H+}

{ One model, two canvases (fullscreen overlay + menu-bar icon). Hosts call
  SetDesktop when they have a window list, Tick on a timer, and present
  Overlay / Bar when NeedsPresent is set. }

interface

uses
  ulemmingconfig, ulemmingdesktop, ulemmingmodel, ulemmingrender, ulemmingaudio;

const
  LemmingsAboutTitle = 'Lemmings Overlay';
  LemmingsAboutText =
    'A nineties-style desktop gimmick: little walkers stomp across the tops ' +
    'of your windows, slide down the sides, and sometimes open a brolly — ' +
    'or splat.' + LineEnding + LineEnding +
    'Original sprites and chip sounds. Not affiliated with Lemmings, ' +
    'DMA Design, or Psygnosis.' + LineEnding + LineEnding +
    'From the menu extra / tray:' + LineEnding +
    '  [ ]   fewer / more walkers' + LineEnding +
    '  M     mute trudges and yippees' + LineEnding +
    '  D     outline the ledges they walk on' + LineEnding +
    '  H     hide the HUD' + LineEnding +
    '  Space pause' + LineEnding + LineEnding +
    'The overlay ignores mouse clicks so you can still use the apps underneath. ' +
    'Quit from the menu extra (macOS / Linux) or the tray icon (Windows).';

type
  TLemmingsController = class
  private
    FNeedsPresent: Boolean;
    FLastMs: QWord;
    FPersist: Boolean;
    FBarW, FBarH: Integer;
  public
    Model: TLemmingModel;
    Overlay: TPixelBuffer;
    Bar: TPixelBuffer;
    constructor Create(PixelW, PixelH, BarW, BarH: Integer; const Cfg: TLemmingConfig;
      Persist: Boolean = True);
    destructor Destroy; override;
    procedure Resize(PixelW, PixelH: Integer);
    procedure SetDesktop(const Desk: TDeskSnapshot);
    procedure Tick;
    procedure Render;
    procedure ApplyChar(Ch: Char);
    procedure ConsumePresent;
    procedure SaveIfNeeded;
    property NeedsPresent: Boolean read FNeedsPresent;
  end;

implementation

uses
  SysUtils, Math;

constructor TLemmingsController.Create(PixelW, PixelH, BarW, BarH: Integer;
  const Cfg: TLemmingConfig; Persist: Boolean);
begin
  inherited Create;
  FPersist := Persist;
  FBarW := BarW;
  FBarH := BarH;
  Model := TLemmingModel.Create;
  Model.SetConfig(Cfg);
  Overlay := TPixelBuffer.Create(PixelW, PixelH);
  Bar := TPixelBuffer.Create(BarW, BarH);
  Model.SetScale(Max(1.0, PixelH / 800.0));
  FNeedsPresent := True;
  FLastMs := 0;
end;

destructor TLemmingsController.Destroy;
begin
  SaveIfNeeded;
  Bar.Free;
  Overlay.Free;
  Model.Free;
  inherited Destroy;
end;

procedure TLemmingsController.SaveIfNeeded;
begin
  if FPersist then
    SaveConfig(Model.Config);
end;

procedure TLemmingsController.Resize(PixelW, PixelH: Integer);
begin
  if (PixelW = Overlay.Width) and (PixelH = Overlay.Height) then
    Exit;
  Overlay.Resize(PixelW, PixelH);
  Model.SetScale(Max(1.0, PixelH / 800.0));
  FNeedsPresent := True;
end;

procedure TLemmingsController.SetDesktop(const Desk: TDeskSnapshot);
begin
  Model.SetDesktop(Desk);
end;

procedure TLemmingsController.Tick;
var
  NowMs: QWord;
  Dt: Double;
begin
  NowMs := GetTickCount64;
  if FLastMs = 0 then
  begin
    FLastMs := NowMs;
    FNeedsPresent := True;
    Exit;
  end;
  Dt := (NowMs - FLastMs) / 1000.0;
  FLastMs := NowMs;
  if Dt > 0.05 then
    Dt := 0.05;
  Model.Update(Dt);
  FNeedsPresent := True;
end;

procedure TLemmingsController.Render;
begin
  RenderLemmings(Overlay, Model);
  RenderBarIcon(Bar);
end;

procedure TLemmingsController.ApplyChar(Ch: Char);
var
  Cfg: TLemmingConfig;
begin
  Cfg := Model.Config;
  case UpCase(Ch) of
    '[':
      SetDensity(Cfg, Cfg.Density - 1);
    ']':
      SetDensity(Cfg, Cfg.Density + 1);
    'M':
      Cfg.Muted := not Cfg.Muted;
    'H':
      Cfg.ShowHUD := not Cfg.ShowHUD;
    'D':
      Cfg.ShowLedges := not Cfg.ShowLedges;
    ' ':
      Model.TogglePaused;
  end;
  Model.SetConfig(Cfg);
  FNeedsPresent := True;
end;

procedure TLemmingsController.ConsumePresent;
begin
  FNeedsPresent := False;
end;

end.
