unit ulemmingrender;

{$mode objfpc}{$H+}

{ Software RGBA canvas for the overlay. Hosts only upload the bytes.
  Sprites are original geometry — green hair, blue robe, pale face —
  not DMA Design / Psygnosis bitmaps. }

interface

uses
  ulemmingmodel;

type
  TPixelBuffer = class
  private
    FWidth, FHeight: Integer;
    FData: array of Byte;
  public
    constructor Create(AWidth, AHeight: Integer);
    procedure Resize(AWidth, AHeight: Integer);
    procedure Clear(R, G, B, A: Byte);
    function Ptr: PByte;
    property Width: Integer read FWidth;
    property Height: Integer read FHeight;
  end;

procedure RenderLemmings(Buf: TPixelBuffer; Model: TLemmingModel);
procedure RenderBarIcon(Buf: TPixelBuffer);
procedure CopyBGRA(Buf: TPixelBuffer; Dest: PByte);

implementation

uses
  Math, SysUtils, ubitmapfont, ulemmingdesktop, ulemmingconfig;

type
  TColor = record
    R, G, B: Byte;
  end;

function C(R, G, B: Byte): TColor;
begin
  Result.R := R;
  Result.G := G;
  Result.B := B;
end;

constructor TPixelBuffer.Create(AWidth, AHeight: Integer);
begin
  inherited Create;
  Resize(AWidth, AHeight);
end;

procedure TPixelBuffer.Resize(AWidth, AHeight: Integer);
begin
  if AWidth < 1 then
    AWidth := 1;
  if AHeight < 1 then
    AHeight := 1;
  FWidth := AWidth;
  FHeight := AHeight;
  SetLength(FData, FWidth * FHeight * 4);
end;

procedure TPixelBuffer.Clear(R, G, B, A: Byte);
var
  I: Integer;
  P: PByte;
begin
  P := @FData[0];
  I := 0;
  while I < Length(FData) do
  begin
    P[I] := R;
    P[I + 1] := G;
    P[I + 2] := B;
    P[I + 3] := A;
    Inc(I, 4);
  end;
end;

function TPixelBuffer.Ptr: PByte;
begin
  Result := @FData[0];
end;

procedure CopyBGRA(Buf: TPixelBuffer; Dest: PByte);
var
  I, N: Integer;
  S, D: PByte;
begin
  S := Buf.Ptr;
  D := Dest;
  N := Buf.Width * Buf.Height;
  for I := 0 to N - 1 do
  begin
    D[0] := S[2];
    D[1] := S[1];
    D[2] := S[0];
    D[3] := S[3];
    Inc(S, 4);
    Inc(D, 4);
  end;
end;

procedure BlendPixel(P: PByte; R, G, B: Byte; A: Double);
var
  SA, DA, OutA, Inv: Double;
begin
  if A <= 0.001 then
    Exit;
  if A > 1 then
    A := 1;
  SA := A;
  DA := P[3] / 255.0;
  Inv := 1.0 - SA;
  OutA := SA + DA * Inv;
  if OutA <= 0.001 then
    Exit;
  P[0] := Round((R * SA + P[0] * DA * Inv) / OutA);
  P[1] := Round((G * SA + P[1] * DA * Inv) / OutA);
  P[2] := Round((B * SA + P[2] * DA * Inv) / OutA);
  P[3] := Round(OutA * 255.0);
end;

procedure Plot(Buf: TPixelBuffer; X, Y: Integer; Col: TColor; A: Double);
var
  P: PByte;
begin
  if (X < 0) or (Y < 0) or (X >= Buf.Width) or (Y >= Buf.Height) then
    Exit;
  P := Buf.Ptr + (Y * Buf.Width + X) * 4;
  BlendPixel(P, Col.R, Col.G, Col.B, A);
end;

function CoverEllipse(PX, PY, CX, CY, RX, RY: Double): Double;
var
  NX, NY, D, Edge: Double;
begin
  if (RX <= 0.2) or (RY <= 0.2) then
    Exit(0);
  NX := (PX - CX) / RX;
  NY := (PY - CY) / RY;
  D := Sqrt(NX * NX + NY * NY);
  Edge := (D - 1.0) * Min(RX, RY);
  if Edge <= -0.6 then
    Result := 1
  else if Edge >= 0.6 then
    Result := 0
  else
    Result := 1.0 - (Edge + 0.6) / 1.2;
end;

procedure FillEllipse(Buf: TPixelBuffer; CX, CY, RX, RY: Double; Col: TColor; Alpha: Double);
var
  X0, Y0, X1, Y1, X, Y: Integer;
  Cov: Double;
  P: PByte;
begin
  if (Alpha <= 0) or (RX <= 0) or (RY <= 0) then
    Exit;
  X0 := Max(0, Floor(CX - RX - 1));
  Y0 := Max(0, Floor(CY - RY - 1));
  X1 := Min(Buf.Width - 1, Ceil(CX + RX + 1));
  Y1 := Min(Buf.Height - 1, Ceil(CY + RY + 1));
  for Y := Y0 to Y1 do
    for X := X0 to X1 do
    begin
      Cov := CoverEllipse(X + 0.5, Y + 0.5, CX, CY, RX, RY);
      if Cov > 0 then
      begin
        P := Buf.Ptr + (Y * Buf.Width + X) * 4;
        BlendPixel(P, Col.R, Col.G, Col.B, Alpha * Cov);
      end;
    end;
end;

procedure FillRect(Buf: TPixelBuffer; X0, Y0, X1, Y1: Double; Col: TColor; Alpha: Double);
var
  XA, XB, YA, YB, X, Y: Integer;
  P: PByte;
begin
  XA := Max(0, Floor(X0));
  YA := Max(0, Floor(Y0));
  XB := Min(Buf.Width - 1, Floor(X1));
  YB := Min(Buf.Height - 1, Floor(Y1));
  if (XB < XA) or (YB < YA) then
    Exit;
  for Y := YA to YB do
    for X := XA to XB do
    begin
      P := Buf.Ptr + (Y * Buf.Width + X) * 4;
      BlendPixel(P, Col.R, Col.G, Col.B, Alpha);
    end;
end;

procedure StrokeRect(Buf: TPixelBuffer; X0, Y0, X1, Y1: Double; Col: TColor; Alpha: Double);
var
  T: Double;
begin
  T := 1.2;
  FillRect(Buf, X0, Y0, X1, Y0 + T, Col, Alpha);
  FillRect(Buf, X0, Y1 - T, X1, Y1, Col, Alpha);
  FillRect(Buf, X0, Y0, X0 + T, Y1, Col, Alpha);
  FillRect(Buf, X1 - T, Y0, X1, Y1, Col, Alpha);
end;

function HairColor(Hair: Integer): TColor;
begin
  case Hair of
    1: Result := C(48, 196, 176);
    2: Result := C(220, 132, 36);
    else Result := C(46, 176, 48);
  end;
end;

function RobeColor: TColor;
begin
  Result := C(48, 72, 196);
end;

function SkinColor: TColor;
begin
  Result := C(240, 198, 158);
end;

procedure DrawLeg(Buf: TPixelBuffer; HipX, HipY, FootX, FootY, Thick: Double; Col: TColor);
var
  I, N: Integer;
  T, X, Y: Double;
begin
  N := Max(3, Round(Hypot(FootX - HipX, FootY - HipY)));
  for I := 0 to N do
  begin
    T := I / N;
    X := HipX + (FootX - HipX) * T;
    Y := HipY + (FootY - HipY) * T;
    FillEllipse(Buf, X, Y, Thick, Thick, Col, 1);
  end;
end;

procedure DrawLemming(Buf: TPixelBuffer; L: TLemming; S: Single);
var
  FeetX, FeetY, Dir: Double;
  HipY, BodyCX, BodyCY, HeadCX, HeadCY: Double;
  Frame: Integer;
  Hair, Robe, Skin, Shoe, White, Black, Red, Shade: TColor;
  LegL, LegR, ArmX, ArmY, Hop: Double;
  UmbrellaY: Double;
begin
  if L.State = lsGone then
    Exit;
  Dir := L.Dir;
  if Dir = 0 then
    Dir := 1;
  FeetX := L.X;
  FeetY := L.Y;
  Hop := 0;
  if L.State = lsCheer then
    Hop := Abs(Sin(L.Anim * 2.2)) * 4 * S;
  FeetY := FeetY - Hop;

  Hair := HairColor(L.Hair);
  Robe := RobeColor;
  Skin := SkinColor;
  Shoe := C(28, 28, 36);
  White := C(245, 245, 248);
  Black := C(16, 16, 20);
  Red := C(196, 48, 48);
  Shade := C(32, 48, 140);

  if L.State = lsSplat then
  begin
    FillEllipse(Buf, FeetX, FeetY - 3 * S, 10 * S, 3.2 * S, Robe, 1);
    FillEllipse(Buf, FeetX - 3 * S, FeetY - 5.5 * S, 3.2 * S, 2.4 * S, Skin, 1);
    FillEllipse(Buf, FeetX + 2 * S, FeetY - 6 * S, 4.2 * S, 2.2 * S, Hair, 1);
    FillEllipse(Buf, FeetX - 4.2 * S, FeetY - 5.8 * S, 0.9 * S, 0.9 * S, Black, 1);
    FillEllipse(Buf, FeetX - 1.8 * S, FeetY - 5.8 * S, 0.9 * S, 0.9 * S, Black, 1);
    Exit;
  end;

  Frame := WalkFrameOf(L.Anim);
  HipY := FeetY - 5.5 * S;
  BodyCX := FeetX;
  BodyCY := HipY - 3.2 * S;
  HeadCX := FeetX + Dir * 0.8 * S;
  HeadCY := BodyCY - 5.6 * S;

  if L.State = lsSlide then
  begin
    BodyCX := FeetX - L.SlideSide * 1.5 * S;
    HeadCX := BodyCX + Dir * 0.4 * S;
  end;
  if L.State = lsFall then
    HeadCY := HeadCY - 0.6 * S;

  { Legs — a four-frame waddle. Falling tucks them; sliding trails one. }
  LegL := 0;
  LegR := 0;
  case L.State of
    lsWalk, lsCheer:
      case Frame of
        0:
          begin
            LegL := -2.2 * S;
            LegR := 2.4 * S;
          end;
        1:
          begin
            LegL := -0.4 * S;
            LegR := 0.6 * S;
          end;
        2:
          begin
            LegL := 2.4 * S;
            LegR := -2.2 * S;
          end;
        else
          begin
            LegL := 0.6 * S;
            LegR := -0.4 * S;
          end;
      end;
    lsSlide:
      begin
        LegL := -1.0 * S;
        LegR := 2.8 * S;
      end;
    lsFall, lsFloat:
      begin
        LegL := -0.8 * S;
        LegR := 0.8 * S;
      end;
  end;
  DrawLeg(Buf, BodyCX - 1.4 * S, HipY, FeetX + LegL, FeetY - 0.4 * S, 1.05 * S, Robe);
  DrawLeg(Buf, BodyCX + 1.4 * S, HipY, FeetX + LegR, FeetY - 0.4 * S, 1.05 * S, Robe);
  FillEllipse(Buf, FeetX + LegL, FeetY - 0.3 * S, 1.5 * S, 0.8 * S, Shoe, 1);
  FillEllipse(Buf, FeetX + LegR, FeetY - 0.3 * S, 1.5 * S, 0.8 * S, Shoe, 1);

  { Tunic. }
  FillEllipse(Buf, BodyCX, BodyCY, 4.4 * S, 5.2 * S, Robe, 1);
  FillEllipse(Buf, BodyCX + Dir * 0.6 * S, BodyCY + 0.8 * S, 3.2 * S, 3.6 * S, Shade, 0.35);

  { Arm. }
  ArmX := BodyCX + Dir * 4.4 * S;
  ArmY := BodyCY;
  if L.State = lsFall then
  begin
    ArmX := BodyCX + Dir * 1.2 * S;
    ArmY := HeadCY - 3.5 * S;
  end
  else if L.State = lsCheer then
  begin
    ArmX := BodyCX + Dir * 1.0 * S;
    ArmY := HeadCY - 4.2 * S;
  end
  else if L.State = lsSlide then
  begin
    ArmX := BodyCX + L.SlideSide * 4.6 * S;
    ArmY := BodyCY - 1.2 * S;
  end
  else if L.State = lsWalk then
  begin
    ArmX := BodyCX + Dir * (3.6 + Frame * 0.35) * S;
    ArmY := BodyCY + (Frame - 1.5) * 0.6 * S;
  end;
  DrawLeg(Buf, BodyCX + Dir * 2.0 * S, BodyCY - 0.8 * S, ArmX, ArmY, 0.95 * S, Robe);

  { Head + hair tuft. }
  FillEllipse(Buf, HeadCX, HeadCY, 3.4 * S, 3.2 * S, Skin, 1);
  FillEllipse(Buf, HeadCX - Dir * 0.4 * S, HeadCY - 2.8 * S, 3.6 * S, 2.4 * S, Hair, 1);
  FillEllipse(Buf, HeadCX + Dir * 1.4 * S, HeadCY - 3.4 * S, 2.2 * S, 2.0 * S, Hair, 1);
  FillEllipse(Buf, HeadCX + Dir * 1.8 * S, HeadCY + 0.4 * S, 1.5 * S, 1.1 * S, Skin, 1); { nose }

  { Eye. }
  FillEllipse(Buf, HeadCX + Dir * 1.1 * S, HeadCY - 0.2 * S, 0.85 * S, 0.95 * S, White, 1);
  FillEllipse(Buf, HeadCX + Dir * 1.35 * S, HeadCY - 0.15 * S, 0.45 * S, 0.5 * S, Black, 1);

  if L.State = lsFloat then
  begin
    UmbrellaY := HeadCY - 7.5 * S;
    FillEllipse(Buf, HeadCX, UmbrellaY, 7.2 * S, 3.4 * S, Red, 1);
    FillEllipse(Buf, HeadCX, UmbrellaY + 0.6 * S, 6.2 * S, 2.2 * S, C(160, 32, 32), 0.5);
    DrawLeg(Buf, HeadCX, UmbrellaY + 2.5 * S, HeadCX, HeadCY - 2.5 * S, 0.55 * S, C(90, 70, 50));
  end;
end;

procedure RenderLemmings(Buf: TPixelBuffer; Model: TLemmingModel);
var
  I: Integer;
  L: TLemming;
  R: TDeskRect;
  S: Single;
  Hud, MuteStr: string;
  Fs: Integer;
  Col: TColor;
begin
  Buf.Clear(0, 0, 0, 0);
  S := Model.Scale;
  if Model.Config.ShowLedges then
    for I := 0 to Model.Desk.Count - 1 do
    begin
      R := Model.Desk.Rects[I];
      case R.Kind of
        dkFallback: Col := C(80, 200, 120);
        dkScreenTop: Col := C(200, 180, 80);
        dkDock: Col := C(80, 160, 220);
        else Col := C(90, 200, 255);
      end;
      StrokeRect(Buf, R.X, R.Y, R.X + R.W, R.Y + R.H, Col, 0.35);
      FillRect(Buf, R.X, R.Y, R.X + R.W, R.Y + 2, Col, 0.55);
    end;

  for I := 0 to Model.LemmingCount - 1 do
  begin
    L := Model.Lemming(I);
    DrawLemming(Buf, L, S);
  end;

  if Model.Config.ShowHUD then
  begin
    Fs := Max(1, Round(S));
    if Model.Config.Muted then
      MuteStr := 'mute'
    else
      MuteStr := 'sfx';
    Hud := Format('Lemmings %d  %s', [Model.AliveCount, MuteStr]);
    if Model.Paused then
      Hud := Hud + '  paused';
    FillRect(Buf, 6, 6, 6 + TextWidth(Hud, Fs) + 10, 6 + TextHeight(Fs) + 8,
      C(8, 12, 24), 0.45);
    DrawText(Buf.Ptr, Buf.Width, Buf.Height, 11, 10, Hud, 220, 230, 210, Fs);
  end;
end;

procedure RenderBarIcon(Buf: TPixelBuffer);
var
  L: TLemming;
  S: Single;
begin
  Buf.Clear(0, 0, 0, 0);
  FillChar(L, SizeOf(L), 0);
  L.State := lsWalk;
  L.Dir := 1;
  L.Hair := 0;
  L.Anim := 1;
  L.X := Buf.Width * 0.50;
  L.Y := Buf.Height * 0.88;
  S := Buf.Height / 22.0;
  DrawLemming(Buf, L, S);
end;

end.
