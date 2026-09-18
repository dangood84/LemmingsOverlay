unit ulemmingdesktop;

{$mode objfpc}{$H+}

{ Window rectangles in overlay-canvas pixels (origin top-left, Y down).
  Hosts fill this from CGWindowList / EnumWindows / X11; the model never
  talks to Cocoa, Win32, or GTK. }

interface

type
  TDeskKind = (dkWindow, dkScreenTop, dkDock, dkFallback);

  TDeskRect = record
    Id: Integer;
    X, Y, W, H: Single;
    Kind: TDeskKind;
  end;

  TDeskSnapshot = record
    ScreenW, ScreenH: Integer;
    Count: Integer;
    Rects: array of TDeskRect;
  end;

procedure ClearDesktop(var Desk: TDeskSnapshot; ScreenW, ScreenH: Integer);
procedure AddDeskRect(var Desk: TDeskSnapshot; Id: Integer; X, Y, W, H: Single;
  Kind: TDeskKind);
function MakeFallbackDesktop(ScreenW, ScreenH: Integer): TDeskSnapshot;
function DeskRectAt(const Desk: TDeskSnapshot; Index: Integer): TDeskRect;
function FindDeskId(const Desk: TDeskSnapshot; Id: Integer): Integer;
function WalkableCount(const Desk: TDeskSnapshot; MinW, MinH: Single): Integer;

implementation

procedure ClearDesktop(var Desk: TDeskSnapshot; ScreenW, ScreenH: Integer);
begin
  Desk.ScreenW := ScreenW;
  Desk.ScreenH := ScreenH;
  Desk.Count := 0;
  SetLength(Desk.Rects, 0);
end;

procedure AddDeskRect(var Desk: TDeskSnapshot; Id: Integer; X, Y, W, H: Single;
  Kind: TDeskKind);
var
  N: Integer;
begin
  if (W < 8) or (H < 4) then
    Exit;
  N := Desk.Count;
  if N >= Length(Desk.Rects) then
    SetLength(Desk.Rects, N + 8);
  Desk.Rects[N].Id := Id;
  Desk.Rects[N].X := X;
  Desk.Rects[N].Y := Y;
  Desk.Rects[N].W := W;
  Desk.Rects[N].H := H;
  Desk.Rects[N].Kind := Kind;
  Desk.Count := N + 1;
end;

function MakeFallbackDesktop(ScreenW, ScreenH: Integer): TDeskSnapshot;
var
  W, H: Single;
begin
  { Used by tests, snapshots, and hosts that cannot see other windows
    (no Screen Recording permission, empty desktop). Staggered ledges
    so a walker has something to step off. }
  Result.ScreenW := 0;
  Result.ScreenH := 0;
  Result.Count := 0;
  Result.Rects := nil;
  ClearDesktop(Result, ScreenW, ScreenH);
  W := ScreenW;
  H := ScreenH;
  AddDeskRect(Result, 9001, W * 0.08, H * 0.18, W * 0.46, H * 0.16, dkFallback);
  AddDeskRect(Result, 9002, W * 0.42, H * 0.40, W * 0.44, H * 0.18, dkFallback);
  AddDeskRect(Result, 9003, W * 0.14, H * 0.64, W * 0.52, H * 0.14, dkFallback);
  AddDeskRect(Result, 9004, 0, H * 0.90, W, H * 0.10, dkDock);
end;

function DeskRectAt(const Desk: TDeskSnapshot; Index: Integer): TDeskRect;
begin
  FillChar(Result, SizeOf(Result), 0);
  if (Index < 0) or (Index >= Desk.Count) then
    Exit;
  Result := Desk.Rects[Index];
end;

function FindDeskId(const Desk: TDeskSnapshot; Id: Integer): Integer;
var
  I: Integer;
begin
  Result := -1;
  if Id = 0 then
    Exit;
  for I := 0 to Desk.Count - 1 do
    if Desk.Rects[I].Id = Id then
    begin
      Result := I;
      Exit;
    end;
end;

function WalkableCount(const Desk: TDeskSnapshot; MinW, MinH: Single): Integer;
var
  I: Integer;
begin
  Result := 0;
  for I := 0 to Desk.Count - 1 do
    if (Desk.Rects[I].W >= MinW) and (Desk.Rects[I].H >= MinH) then
      Inc(Result);
end;

end.
