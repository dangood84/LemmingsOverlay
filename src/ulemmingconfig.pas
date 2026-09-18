unit ulemmingconfig;

{$mode objfpc}{$H+}

{ Appearance / density only. Positions and states live on TLemmingModel,
  so a saved INI cannot freeze a walker mid-stride. }

interface

type
  TLemmingConfig = record
    Density: Integer;
    Muted: Boolean;
    ShowHUD: Boolean;
    ShowLedges: Boolean;
  end;

const
  MinDensity = 1;
  MaxDensity = 12;
  DefaultDensity = 3;

function DefaultConfig: TLemmingConfig;
function LoadConfig: TLemmingConfig;
procedure SaveConfig(const Cfg: TLemmingConfig);
procedure ClampConfig(var Cfg: TLemmingConfig);

procedure SetDensity(var Cfg: TLemmingConfig; Value: Integer);

implementation

uses
  Classes, IniFiles, SysUtils;

const
  Section = 'display';

function ClampInt(Value, Lo, Hi: Integer): Integer;
begin
  if Value < Lo then
    Result := Lo
  else if Value > Hi then
    Result := Hi
  else
    Result := Value;
end;

function ConfigPath: string;
var
  Dir: string;
begin
  { Per-user OS config dir, not the repo, so relaunch keeps the last look. }
  Dir := GetAppConfigDir(False);
  ForceDirectories(Dir);
  Result := IncludeTrailingPathDelimiter(Dir) + 'lemmingsoverlay.ini';
end;

procedure ClampConfig(var Cfg: TLemmingConfig);
begin
  Cfg.Density := ClampInt(Cfg.Density, MinDensity, MaxDensity);
end;

function DefaultConfig: TLemmingConfig;
begin
  Result.Density := DefaultDensity;
  Result.Muted := False;
  Result.ShowHUD := True;
  Result.ShowLedges := False;
end;

function LoadConfig: TLemmingConfig;
var
  Ini: TIniFile;
begin
  Result := DefaultConfig;
  if not FileExists(ConfigPath) then
    Exit;
  Ini := TIniFile.Create(ConfigPath);
  try
    Result.Density := Ini.ReadInteger(Section, 'density', Result.Density);
    Result.Muted := Ini.ReadBool(Section, 'muted', Result.Muted);
    Result.ShowHUD := Ini.ReadBool(Section, 'hud', Result.ShowHUD);
    Result.ShowLedges := Ini.ReadBool(Section, 'ledges', Result.ShowLedges);
    ClampConfig(Result);
  finally
    Ini.Free;
  end;
end;

procedure SaveConfig(const Cfg: TLemmingConfig);
var
  C: TLemmingConfig;
  Ini: TIniFile;
begin
  C := Cfg;
  ClampConfig(C);
  Ini := TIniFile.Create(ConfigPath);
  try
    Ini.WriteInteger(Section, 'density', C.Density);
    Ini.WriteBool(Section, 'muted', C.Muted);
    Ini.WriteBool(Section, 'hud', C.ShowHUD);
    Ini.WriteBool(Section, 'ledges', C.ShowLedges);
  finally
    Ini.Free;
  end;
end;

procedure SetDensity(var Cfg: TLemmingConfig; Value: Integer);
begin
  Cfg.Density := ClampInt(Value, MinDensity, MaxDensity);
end;

end.
