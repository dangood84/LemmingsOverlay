unit ulemmingmodel;

{$mode objfpc}{$H+}

{ Lemming pool, walk / slide / fall / float / splat / cheer. No pixels,
  no Cocoa/Win32/GTK. Desktop rectangles are a TDeskSnapshot the host
  refreshes; collision is all "is this foot on that top edge?" }

interface

uses
  ulemmingconfig, ulemmingdesktop, ulemmingaudio;

const
  MaxSfxQueue = 24;
  WalkFrameCount = 4;

type
  TLemmingState = (lsGone, lsWalk, lsSlide, lsFall, lsFloat, lsSplat, lsCheer);

  TLemming = record
    State: TLemmingState;
    X, Y: Single;       { feet, canvas pixels, Y down }
    VX, VY: Single;
    Dir: Integer;       { +1 right, -1 left }
    Anim: Single;
    StateAge: Single;
    FallStartY: Single;
    Platform: Integer;  { index into current snapshot, -1 none }
    PlatformId: Integer;
    SlideSide: Integer; { -1 left face, +1 right face }
    Hair: Integer;      { 0 green, 1 cyan, 2 ginger — original palette }
    TrudgeAcc: Single;
    SpawnIn: Single;
  end;

  TLemmingModel = class
  private
    FRng: Cardinal;
    FLemmings: array of TLemming;
    FConfig: TLemmingConfig;
    FDesk: TDeskSnapshot;
    FPrevDesk: TDeskSnapshot;
    FPaused: Boolean;
    FScale: Single;
    FSlideChance: Single;
    FFloaterEnabled: Boolean;
    FSfx: array[0..MaxSfxQueue - 1] of TSfxKind;
    FSfxCount: Integer;
    function NextU32: Cardinal;
    function NextFloat: Single;
    procedure SyncPoolToConfig;
    procedure Emit(Kind: TSfxKind);
    procedure ChangeState(var L: TLemming; NewState: TLemmingState);
    procedure SpawnLemming(Index: Integer);
    procedure FollowMovedPlatform(var L: TLemming);
    function PlatformUnderFeet(X, FeetY: Single; IgnoreIdx: Integer): Integer;
    function LandedOnTop(X, PrevY, NewY: Single; out Hit: Integer): Boolean;
    procedure BeginWalk(var L: TLemming; OnIdx: Integer);
    procedure BeginSlide(var L: TLemming);
    procedure BeginFall(var L: TLemming; PlayOhNo: Boolean);
    procedure TickWalk(var L: TLemming; Dt: Single);
    procedure TickSlide(var L: TLemming; Dt: Single);
    procedure TickFall(var L: TLemming; Dt: Single; CanFloat: Boolean);
    procedure TickSplat(var L: TLemming; Dt: Single);
    procedure TickCheer(var L: TLemming; Dt: Single);
  public
    constructor Create;
    procedure Seed(Value: Cardinal);
    procedure SetConfig(const Cfg: TLemmingConfig);
    procedure SetScale(Value: Single);
    procedure SetDesktop(const Desk: TDeskSnapshot);
    procedure Update(Dt: Double);
    procedure PlaceCataloguePose(ViewW, ViewH: Integer);
    procedure ForceLemming(Index: Integer; State: TLemmingState; X, Y: Single;
      Dir, PlatformIdx, SlideSide: Integer);
    procedure TogglePaused;
    function LemmingCount: Integer;
    function Lemming(Index: Integer): TLemming;
    function AliveCount: Integer;
    function DrainSfx(out Kind: TSfxKind): Boolean;
    function WalkSpeed: Single;
    function Gravity: Single;
    function SlideSpeed: Single;
    function SplatDistance: Single;
    function FloatDistance: Single;
    function BodyWidth: Single;
    function BodyHeight: Single;
    property Config: TLemmingConfig read FConfig;
    property Paused: Boolean read FPaused;
    property Scale: Single read FScale;
    property SlideChance: Single read FSlideChance write FSlideChance;
    property FloaterEnabled: Boolean read FFloaterEnabled write FFloaterEnabled;
    property Desk: TDeskSnapshot read FDesk;
  end;

function WalkFrameOf(Anim: Single): Integer;
function StateName(S: TLemmingState): string;

implementation

uses
  Math, SysUtils;

constructor TLemmingModel.Create;
begin
  inherited Create;
  FRng := 2463534242;
  FConfig := DefaultConfig;
  FScale := 1;
  FSlideChance := 0.68;
  FFloaterEnabled := True;
  FPaused := False;
  FSfxCount := 0;
  ClearDesktop(FDesk, 800, 500);
  ClearDesktop(FPrevDesk, 800, 500);
  SyncPoolToConfig;
end;

procedure TLemmingModel.Seed(Value: Cardinal);
begin
  if Value = 0 then
    Value := 1;
  FRng := Value;
end;

function TLemmingModel.NextU32: Cardinal;
begin
  { xorshift32 — same scramble as Flying Toasters / Eyes spawn. }
  FRng := FRng xor (FRng shl 13);
  FRng := FRng xor (FRng shr 17);
  FRng := FRng xor (FRng shl 5);
  Result := FRng;
end;

function TLemmingModel.NextFloat: Single;
begin
  Result := NextU32 * (1.0 / 4294967295.0);
end;

function TLemmingModel.WalkSpeed: Single;
begin
  Result := 54 * FScale;
end;

function TLemmingModel.Gravity: Single;
begin
  Result := 560 * FScale;
end;

function TLemmingModel.SlideSpeed: Single;
begin
  Result := 86 * FScale;
end;

function TLemmingModel.SplatDistance: Single;
begin
  { Classic "too far" is about 60 sprite-pixels; we scale to canvas. }
  Result := 118 * FScale;
end;

function TLemmingModel.FloatDistance: Single;
begin
  Result := 72 * FScale;
end;

function TLemmingModel.BodyWidth: Single;
begin
  Result := 12 * FScale;
end;

function TLemmingModel.BodyHeight: Single;
begin
  Result := 18 * FScale;
end;

procedure TLemmingModel.SetConfig(const Cfg: TLemmingConfig);
var
  C: TLemmingConfig;
begin
  C := Cfg;
  ClampConfig(C);
  FConfig := C;
  SyncPoolToConfig;
end;

procedure TLemmingModel.SetScale(Value: Single);
begin
  if Value < 0.5 then
    Value := 0.5;
  if Value > 4 then
    Value := 4;
  FScale := Value;
end;

procedure TLemmingModel.SetDesktop(const Desk: TDeskSnapshot);
begin
  FPrevDesk := FDesk;
  FDesk := Desk;
end;

procedure TLemmingModel.SyncPoolToConfig;
var
  OldN, N, I: Integer;
begin
  OldN := Length(FLemmings);
  N := FConfig.Density;
  SetLength(FLemmings, N);
  for I := OldN to N - 1 do
  begin
    FillChar(FLemmings[I], SizeOf(TLemming), 0);
    FLemmings[I].State := lsGone;
    FLemmings[I].Dir := 1;
    FLemmings[I].Platform := -1;
    { Stagger first appearances so they do not all drop at once. }
    FLemmings[I].SpawnIn := 0.15 + I * 0.85 + NextFloat * 0.6;
    FLemmings[I].Hair := Integer(NextU32 mod 3);
  end;
end;

procedure TLemmingModel.Emit(Kind: TSfxKind);
begin
  if Kind = sfxNone then
    Exit;
  if FSfxCount >= MaxSfxQueue then
    Exit;
  FSfx[FSfxCount] := Kind;
  Inc(FSfxCount);
end;

function TLemmingModel.DrainSfx(out Kind: TSfxKind): Boolean;
var
  I: Integer;
begin
  Result := FSfxCount > 0;
  if not Result then
  begin
    Kind := sfxNone;
    Exit;
  end;
  Kind := FSfx[0];
  for I := 1 to FSfxCount - 1 do
    FSfx[I - 1] := FSfx[I];
  Dec(FSfxCount);
end;

procedure TLemmingModel.ChangeState(var L: TLemming; NewState: TLemmingState);
begin
  { One place for every transition so audio stays event-driven: the render
    loop never starts a sample, it only drains the queue the host plays. }
  if L.State = NewState then
    Exit;
  case NewState of
    lsFall:
      if L.State in [lsWalk, lsSlide, lsCheer] then
        Emit(sfxOhNo);
    lsSlide:
      Emit(sfxSlide);
    lsFloat:
      Emit(sfxUmbrella);
    lsSplat:
      Emit(sfxSplat);
    lsCheer:
      Emit(sfxYippee);
  end;
  L.State := NewState;
  L.StateAge := 0;
  if NewState <> lsWalk then
    L.TrudgeAcc := 0;
end;

procedure TLemmingModel.SpawnLemming(Index: Integer);
var
  Cands: array of Integer;
  N, I, Pick: Integer;
  R: TDeskRect;
  MinW, Pad: Single;
  L: TLemming;
begin
  { Prefer a window top wide enough to take a few steps before an edge. }
  MinW := 70 * FScale;
  SetLength(Cands, 0);
  N := 0;
  for I := 0 to FDesk.Count - 1 do
    if (FDesk.Rects[I].W >= MinW) and (FDesk.Rects[I].H >= 16 * FScale) then
    begin
      SetLength(Cands, N + 1);
      Cands[N] := I;
      Inc(N);
    end;
  FillChar(L, SizeOf(L), 0);
  L.Hair := Integer(NextU32 mod 3);
  L.Anim := NextFloat * WalkFrameCount;
  L.SpawnIn := 0;
  L.Platform := -1;
  L.Dir := 1;
  if NextFloat < 0.5 then
    L.Dir := -1;
  if N = 0 then
  begin
    { Empty desk: drop them in from the top-left and let gravity find a ledge. }
    L.X := FDesk.ScreenW * (0.15 + NextFloat * 0.7);
    L.Y := 8 * FScale;
    L.FallStartY := L.Y;
    FLemmings[Index] := L;
    ChangeState(FLemmings[Index], lsFall);
    Exit;
  end;
  Pick := Cands[NextU32 mod Cardinal(N)];
  R := FDesk.Rects[Pick];
  Pad := BodyWidth;
  L.X := R.X + Pad + NextFloat * Max(8, R.W - Pad * 2);
  L.Y := R.Y;
  L.VX := WalkSpeed * L.Dir;
  L.VY := 0;
  FLemmings[Index] := L;
  BeginWalk(FLemmings[Index], Pick);
end;

procedure TLemmingModel.FollowMovedPlatform(var L: TLemming);
var
  OldIdx, NewIdx: Integer;
  OldR, NewR: TDeskRect;
begin
  { If the user drags a window, keep the walker glued to that same Id
    rather than letting them hover in empty air until the next fall check. }
  if L.PlatformId = 0 then
    Exit;
  OldIdx := FindDeskId(FPrevDesk, L.PlatformId);
  NewIdx := FindDeskId(FDesk, L.PlatformId);
  if (OldIdx < 0) or (NewIdx < 0) then
    Exit;
  OldR := FPrevDesk.Rects[OldIdx];
  NewR := FDesk.Rects[NewIdx];
  L.X := L.X + (NewR.X - OldR.X);
  L.Y := L.Y + (NewR.Y - OldR.Y);
  L.Platform := NewIdx;
end;

function TLemmingModel.PlatformUnderFeet(X, FeetY: Single; IgnoreIdx: Integer): Integer;
var
  I: Integer;
  R: TDeskRect;
  BestH: Single;
  Tol: Single;
begin
  { A "floor" is the TOP edge of a desktop rectangle. Feet sit on that
    edge, not inside the window, so the sprite appears to walk the title
    bar / chrome rather than clipping through the document. }
  Result := -1;
  BestH := 1e9;
  Tol := 3.5 * FScale;
  for I := 0 to FDesk.Count - 1 do
  begin
    if I = IgnoreIdx then
      Continue;
    R := FDesk.Rects[I];
    if (X < R.X) or (X > R.X + R.W) then
      Continue;
    if Abs(FeetY - R.Y) <= Tol then
      if R.H < BestH then
      begin
        BestH := R.H;
        Result := I;
      end;
  end;
end;

function TLemmingModel.LandedOnTop(X, PrevY, NewY: Single; out Hit: Integer): Boolean;
var
  I: Integer;
  R: TDeskRect;
  BestY: Single;
begin
  { Discrete sweep: if the feet crossed a top edge this tick, we landed.
    Checking only the new position would tunnel through thin title bars
    when dt is large. }
  Result := False;
  Hit := -1;
  BestY := 1e9;
  if NewY < PrevY then
    Exit;
  for I := 0 to FDesk.Count - 1 do
  begin
    R := FDesk.Rects[I];
    if (X < R.X + 2) or (X > R.X + R.W - 2) then
      Continue;
    if (PrevY <= R.Y + 0.5) and (NewY >= R.Y) then
      if R.Y < BestY then
      begin
        BestY := R.Y;
        Hit := I;
        Result := True;
      end;
  end;
end;

procedure TLemmingModel.BeginWalk(var L: TLemming; OnIdx: Integer);
var
  R: TDeskRect;
begin
  L.Platform := OnIdx;
  if OnIdx >= 0 then
  begin
    R := FDesk.Rects[OnIdx];
    L.PlatformId := R.Id;
    L.Y := R.Y;
  end
  else
    L.PlatformId := 0;
  L.VY := 0;
  L.VX := WalkSpeed * L.Dir;
  ChangeState(L, lsWalk);
end;

procedure TLemmingModel.BeginSlide(var L: TLemming);
var
  R: TDeskRect;
begin
  if L.Platform < 0 then
  begin
    BeginFall(L, True);
    Exit;
  end;
  R := FDesk.Rects[L.Platform];
  { Which face they step onto is the direction they were walking: a
    rightward walker reaches the right edge and slides that side. }
  if L.Dir >= 0 then
  begin
    L.SlideSide := 1;
    L.X := R.X + R.W;
  end
  else
  begin
    L.SlideSide := -1;
    L.X := R.X;
  end;
  L.VY := SlideSpeed;
  L.VX := 0;
  ChangeState(L, lsSlide);
end;

procedure TLemmingModel.BeginFall(var L: TLemming; PlayOhNo: Boolean);
begin
  L.FallStartY := L.Y;
  L.VY := Max(L.VY, 20 * FScale);
  L.VX := L.Dir * WalkSpeed * 0.15;
  L.Platform := -1;
  L.PlatformId := 0;
  if PlayOhNo then
    ChangeState(L, lsFall)
  else
  begin
    { Used when a floater folds the brolly — no second "oh no". }
    L.State := lsFall;
    L.StateAge := 0;
  end;
end;

procedure TLemmingModel.TickWalk(var L: TLemming; Dt: Single);
var
  NextX: Single;
  R: TDeskRect;
  StillOn: Integer;
  AtEdge: Boolean;
begin
  FollowMovedPlatform(L);
  L.Anim := L.Anim + Dt * 8.5;
  L.TrudgeAcc := L.TrudgeAcc + Dt;
  if L.TrudgeAcc >= 0.26 then
  begin
    L.TrudgeAcc := L.TrudgeAcc - 0.26;
    Emit(sfxTrudge);
  end;

  NextX := L.X + L.Dir * WalkSpeed * Dt;

  { Window closed / moved out from under them → empty air, unless they are
    already on the screen floor. Landing with Platform=-1 then immediately
    falling again is why walkers "struggled" along the bottom on the Pi. }
  StillOn := PlatformUnderFeet(L.X, L.Y, -1);
  if StillOn < 0 then
  begin
    if L.Y >= FDesk.ScreenH - Max(8.0, 8.0 * FScale) then
    begin
      L.Y := FDesk.ScreenH - 2;
      L.Platform := -1;
      L.PlatformId := 0;
      if (NextX < -20 * FScale) or (NextX > FDesk.ScreenW + 20 * FScale) then
      begin
        L.State := lsGone;
        L.SpawnIn := 0.8 + NextFloat * 1.4;
      end
      else
        L.X := NextX;
      Exit;
    end;
    BeginFall(L, True);
    Exit;
  end;
  L.Platform := StillOn;
  L.PlatformId := FDesk.Rects[StillOn].Id;
  R := FDesk.Rects[StillOn];
  L.Y := R.Y;

  AtEdge := False;
  if (L.Dir > 0) and (NextX >= R.X + R.W - 1) then
    AtEdge := True;
  if (L.Dir < 0) and (NextX <= R.X + 1) then
    AtEdge := True;

  if AtEdge then
  begin
    { The gimmick: most walkers grab the window frame and slide; a few
      step off into space. Tests pin this with SlideChance 0 or 1. }
    if NextFloat < FSlideChance then
      BeginSlide(L)
    else
    begin
      L.X := NextX;
      BeginFall(L, True);
    end;
    Exit;
  end;

  L.X := NextX;
  L.VX := L.Dir * WalkSpeed;
end;

procedure TLemmingModel.TickSlide(var L: TLemming; Dt: Single);
var
  R: TDeskRect;
  Idx, Hit: Integer;
  NewY: Single;
begin
  Idx := FindDeskId(FDesk, L.PlatformId);
  if Idx < 0 then
  begin
    BeginFall(L, True);
    Exit;
  end;
  R := FDesk.Rects[Idx];
  L.Platform := Idx;
  if L.SlideSide >= 0 then
    L.X := R.X + R.W
  else
    L.X := R.X;
  L.Anim := L.Anim + Dt * 6;
  NewY := L.Y + SlideSpeed * Dt;

  { A lower window's top can interrupt the slide — they hop aboard. }
  if LandedOnTop(L.X, L.Y + 1, NewY, Hit) and (Hit <> Idx) then
  begin
    L.Y := FDesk.Rects[Hit].Y;
    if NextFloat < 0.22 then
    begin
      L.Platform := Hit;
      L.PlatformId := FDesk.Rects[Hit].Id;
      ChangeState(L, lsCheer);
    end
    else
      BeginWalk(L, Hit);
    Exit;
  end;

  if NewY >= R.Y + R.H - 1 then
  begin
    L.Y := R.Y + R.H;
    BeginFall(L, True);
    Exit;
  end;
  L.Y := NewY;
end;

procedure TLemmingModel.TickFall(var L: TLemming; Dt: Single; CanFloat: Boolean);
var
  PrevY, Drop: Single;
  Hit: Integer;
  FloorY: Single;
begin
  L.Anim := L.Anim + Dt * 10;
  L.VY := L.VY + Gravity * Dt;
  if L.VY > 320 * FScale then
    L.VY := 320 * FScale;
  if CanFloat then
    L.VX := L.Dir * WalkSpeed * 0.12
  else
    L.VX := L.Dir * WalkSpeed * 0.35; { umbrella drift }
  PrevY := L.Y;
  L.X := L.X + L.VX * Dt;
  L.Y := L.Y + L.VY * Dt;
  Drop := L.Y - L.FallStartY;

  if CanFloat and FFloaterEnabled and (Drop >= FloatDistance) and (L.StateAge > 0.28) then
  begin
    ChangeState(L, lsFloat);
    L.VY := 48 * FScale;
    Exit;
  end;

  FloorY := FDesk.ScreenH - 2;
  if LandedOnTop(L.X, PrevY, L.Y, Hit) then
  begin
    L.Y := FDesk.Rects[Hit].Y;
    if CanFloat and (Drop >= SplatDistance) then
    begin
      L.Platform := Hit;
      ChangeState(L, lsSplat);
    end
    else if (not CanFloat) or (NextFloat < 0.12) then
    begin
      L.Platform := Hit;
      L.PlatformId := FDesk.Rects[Hit].Id;
      ChangeState(L, lsCheer);
    end
    else
      BeginWalk(L, Hit);
    Exit;
  end;

  if L.Y >= FloorY then
  begin
    L.Y := FloorY;
    if CanFloat and (Drop >= SplatDistance) then
      ChangeState(L, lsSplat)
    else if not CanFloat then
      ChangeState(L, lsCheer)
    else
    begin
      { Soft landing on the bottom of the screen: walk along the dock line. }
      L.Platform := -1;
      L.PlatformId := 0;
      L.VY := 0;
      ChangeState(L, lsWalk);
    end;
  end;
end;

procedure TLemmingModel.TickSplat(var L: TLemming; Dt: Single);
begin
  L.Anim := L.Anim + Dt * 8;
  L.VX := 0;
  L.VY := 0;
  if L.StateAge >= 0.85 then
  begin
    L.State := lsGone;
    L.StateAge := 0;
    L.SpawnIn := 1.2 + NextFloat * 2.0;
  end;
end;

procedure TLemmingModel.TickCheer(var L: TLemming; Dt: Single);
begin
  { Feet stay on the ledge; the renderer uses Anim for the hop. }
  L.Anim := L.Anim + Dt * 7;
  L.VX := 0;
  L.VY := 0;
  if L.StateAge >= 0.80 then
  begin
    if L.Platform >= 0 then
      BeginWalk(L, L.Platform)
    else
      BeginWalk(L, PlatformUnderFeet(L.X, L.Y, -1));
  end;
end;

procedure TLemmingModel.TogglePaused;
begin
  FPaused := not FPaused;
end;

function TLemmingModel.LemmingCount: Integer;
begin
  Result := Length(FLemmings);
end;

function TLemmingModel.Lemming(Index: Integer): TLemming;
begin
  FillChar(Result, SizeOf(Result), 0);
  if (Index < 0) or (Index >= Length(FLemmings)) then
    Exit;
  Result := FLemmings[Index];
end;

function TLemmingModel.AliveCount: Integer;
var
  I: Integer;
begin
  Result := 0;
  for I := 0 to High(FLemmings) do
    if FLemmings[I].State <> lsGone then
      Inc(Result);
end;

function WalkFrameOf(Anim: Single): Integer;
var
  P: Integer;
begin
  P := Trunc(Anim) mod WalkFrameCount;
  if P < 0 then
    P := P + WalkFrameCount;
  Result := P;
end;

function StateName(S: TLemmingState): string;
begin
  case S of
    lsGone: Result := 'gone';
    lsWalk: Result := 'walk';
    lsSlide: Result := 'slide';
    lsFall: Result := 'fall';
    lsFloat: Result := 'float';
    lsSplat: Result := 'splat';
    lsCheer: Result := 'cheer';
    else Result := '?';
  end;
end;

procedure TLemmingModel.Update(Dt: Double);
var
  I: Integer;
  L: TLemming;
begin
  if Dt > 0.05 then
    Dt := 0.05;
  if Dt < 0 then
    Dt := 0;
  if FPaused then
    Exit;
  for I := 0 to High(FLemmings) do
  begin
    L := FLemmings[I];
    L.StateAge := L.StateAge + Dt;
    case L.State of
      lsGone:
        begin
          L.SpawnIn := L.SpawnIn - Dt;
          if L.SpawnIn <= 0 then
          begin
            FLemmings[I] := L;
            SpawnLemming(I);
            Continue;
          end;
        end;
      lsWalk:
        TickWalk(L, Dt);
      lsSlide:
        TickSlide(L, Dt);
      lsFall:
        TickFall(L, Dt, True);
      lsFloat:
        TickFall(L, Dt, False);
      lsSplat:
        TickSplat(L, Dt);
      lsCheer:
        TickCheer(L, Dt);
    end;
    if (L.State <> lsGone) and (L.State <> lsSplat) then
    begin
      if L.X < -40 * FScale then
      begin
        L.State := lsGone;
        L.SpawnIn := 0.8 + NextFloat * 1.4;
      end
      else if L.X > FDesk.ScreenW + 40 * FScale then
      begin
        L.State := lsGone;
        L.SpawnIn := 0.8 + NextFloat * 1.4;
      end;
    end;
    FLemmings[I] := L;
  end;
end;

procedure TLemmingModel.ForceLemming(Index: Integer; State: TLemmingState; X, Y: Single;
  Dir, PlatformIdx, SlideSide: Integer);
var
  L: TLemming;
begin
  if (Index < 0) or (Index >= Length(FLemmings)) then
    Exit;
  FillChar(L, SizeOf(L), 0);
  L.State := State;
  L.X := X;
  L.Y := Y;
  L.Dir := Dir;
  if L.Dir = 0 then
    L.Dir := 1;
  L.Platform := PlatformIdx;
  L.SlideSide := SlideSide;
  L.Hair := Index mod 3;
  if (PlatformIdx >= 0) and (PlatformIdx < FDesk.Count) then
    L.PlatformId := FDesk.Rects[PlatformIdx].Id;
  if State = lsWalk then
    L.VX := WalkSpeed * L.Dir;
  if State in [lsFall, lsFloat] then
    L.FallStartY := Y;
  FLemmings[Index] := L;
end;

procedure TLemmingModel.PlaceCataloguePose(ViewW, ViewH: Integer);
var
  Shot: TDeskSnapshot;
  Cfg: TLemmingConfig;
  I: Integer;
  L: TLemming;
begin
  { Frozen showcase for PPM snapshots: one of each pose on fake ledges. }
  Cfg := FConfig;
  Cfg.Density := 6;
  FConfig := Cfg;
  SyncPoolToConfig;
  Shot := MakeFallbackDesktop(ViewW, ViewH);
  SetDesktop(Shot);
  for I := 0 to High(FLemmings) do
  begin
    FillChar(L, SizeOf(L), 0);
    L.Dir := 1;
    L.Hair := I mod 3;
    L.Platform := 0;
    L.PlatformId := Shot.Rects[0].Id;
    case I of
      0:
        begin
          L.State := lsWalk;
          L.X := Shot.Rects[0].X + Shot.Rects[0].W * 0.35;
          L.Y := Shot.Rects[0].Y;
          L.Anim := 1.2;
        end;
      1:
        begin
          L.State := lsSlide;
          L.Platform := 1;
          L.PlatformId := Shot.Rects[1].Id;
          L.SlideSide := 1;
          L.X := Shot.Rects[1].X + Shot.Rects[1].W;
          L.Y := Shot.Rects[1].Y + Shot.Rects[1].H * 0.35;
          L.Anim := 2;
        end;
      2:
        begin
          L.State := lsFall;
          L.X := ViewW * 0.55;
          L.Y := ViewH * 0.28;
          L.Anim := 0.4;
          L.FallStartY := ViewH * 0.10;
        end;
      3:
        begin
          L.State := lsFloat;
          L.X := ViewW * 0.72;
          L.Y := ViewH * 0.50;
          L.Anim := 1.5;
        end;
      4:
        begin
          L.State := lsSplat;
          L.X := Shot.Rects[2].X + Shot.Rects[2].W * 0.45;
          L.Y := Shot.Rects[2].Y;
          L.Anim := 2;
        end;
      else
        begin
          L.State := lsCheer;
          L.X := Shot.Rects[2].X + Shot.Rects[2].W * 0.72;
          L.Y := Shot.Rects[2].Y;
          L.Anim := 1;
        end;
    end;
    FLemmings[I] := L;
  end;
end;

end.
