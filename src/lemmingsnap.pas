program lemmingsnap;

{$mode objfpc}{$H+}

{ Writes PPM frames of the software canvas (no window).
  Usage: lemmingsnap out-dir }

uses
  SysUtils, ulemmingconfig, ulemmingapp, ulemmingdesktop;

procedure WritePPM(const Path: string; C: TLemmingsController);
var
  F: File;
  X, Y: Integer;
  P: PByte;
  RGB: array[0..2] of Byte;
  Header: string;
  A: Byte;
begin
  C.Render;
  Header := Format('P6'#10'%d %d'#10'255'#10, [C.Overlay.Width, C.Overlay.Height]);
  AssignFile(F, Path);
  Rewrite(F, 1);
  BlockWrite(F, Header[1], Length(Header));
  for Y := 0 to C.Overlay.Height - 1 do
  begin
    P := C.Overlay.Ptr + Y * C.Overlay.Width * 4;
    for X := 0 to C.Overlay.Width - 1 do
    begin
      { Composite onto a dim desktop-grey so transparent pixels are visible. }
      A := P[3];
      RGB[0] := (P[0] * A + 36 * (255 - A)) div 255;
      RGB[1] := (P[1] * A + 40 * (255 - A)) div 255;
      RGB[2] := (P[2] * A + 48 * (255 - A)) div 255;
      BlockWrite(F, RGB[0], 3);
      Inc(P, 4);
    end;
  end;
  CloseFile(F);
end;

var
  Dir: string;
  C: TLemmingsController;
  Cfg: TLemmingConfig;
begin
  if ParamCount >= 1 then
    Dir := ParamStr(1)
  else
    Dir := 'build';
  ForceDirectories(Dir);
  Cfg := DefaultConfig;
  Cfg.ShowHUD := False;
  Cfg.ShowLedges := True;
  C := TLemmingsController.Create(800, 500, 44, 22, Cfg, False);
  try
    C.Model.SetScale(1.6);
    C.Model.PlaceCataloguePose(800, 500);
    WritePPM(IncludeTrailingPathDelimiter(Dir) + 'snap-catalogue.ppm', C);

    Cfg.ShowLedges := False;
    C.Model.SetConfig(Cfg);
    C.Model.PlaceCataloguePose(800, 500);
    WritePPM(IncludeTrailingPathDelimiter(Dir) + 'snap-sprites.ppm', C);

    Cfg.ShowHUD := True;
    Cfg.ShowLedges := True;
    C.Model.SetConfig(Cfg);
    C.Model.PlaceCataloguePose(800, 500);
    WritePPM(IncludeTrailingPathDelimiter(Dir) + 'snap-hud.ppm', C);

    C.Resize(960, 540);
    C.Model.SetScale(1.8);
    C.Model.PlaceCataloguePose(960, 540);
    WritePPM(IncludeTrailingPathDelimiter(Dir) + 'snap-wide.ppm', C);
  finally
    C.Free;
  end;
end.
