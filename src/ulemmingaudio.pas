unit ulemmingaudio;

{$mode objfpc}{$H+}

{ Original 8-bit style PCM stings. Not DMA Design / Psygnosis samples —
  those recordings are still theirs. Each cue is a short WAV the host
  plays asynchronously when the state machine says so. }

interface

uses
  SysUtils;

type
  TSfxKind = (sfxNone, sfxTrudge, sfxOhNo, sfxSlide, sfxUmbrella, sfxSplat, sfxYippee);

function BuildSfxWav(Kind: TSfxKind): TBytes;
function SfxName(Kind: TSfxKind): string;

implementation

uses
  Math;

const
  Rate = 22050;

procedure WriteWavHeader(var Bytes: TBytes; Samples: Integer);
var
  P: Integer;
begin
  SetLength(Bytes, 44 + Samples * 2);
  FillChar(Bytes[0], Length(Bytes), 0);
  Bytes[0] := Ord('R'); Bytes[1] := Ord('I'); Bytes[2] := Ord('F'); Bytes[3] := Ord('F');
  P := 36 + Samples * 2;
  Bytes[4] := Byte(P); Bytes[5] := Byte(P shr 8);
  Bytes[6] := Byte(P shr 16); Bytes[7] := Byte(P shr 24);
  Bytes[8] := Ord('W'); Bytes[9] := Ord('A'); Bytes[10] := Ord('V'); Bytes[11] := Ord('E');
  Bytes[12] := Ord('f'); Bytes[13] := Ord('m'); Bytes[14] := Ord('t'); Bytes[15] := Ord(' ');
  Bytes[16] := 16;
  Bytes[20] := 1;
  Bytes[22] := 1;
  Bytes[24] := 34; Bytes[25] := 86; { 22050 }
  Bytes[28] := 68; Bytes[29] := 172; { 44100 B/s }
  Bytes[32] := 2;
  Bytes[34] := 16;
  Bytes[36] := Ord('d'); Bytes[37] := Ord('a'); Bytes[38] := Ord('t'); Bytes[39] := Ord('a');
  P := Samples * 2;
  Bytes[40] := Byte(P); Bytes[41] := Byte(P shr 8);
  Bytes[42] := Byte(P shr 16); Bytes[43] := Byte(P shr 24);
end;

procedure PutSample(var Bytes: TBytes; Index: Integer; Amp: Double);
var
  V: SmallInt;
begin
  if Amp > 0.95 then
    Amp := 0.95;
  if Amp < -0.95 then
    Amp := -0.95;
  V := Round(Amp * 32767);
  Bytes[44 + Index * 2] := Byte(V);
  Bytes[45 + Index * 2] := Byte(V shr 8);
end;

function Square(Phase, Duty: Double): Double;
begin
  if Phase < Duty then
    Result := 1
  else
    Result := -1;
end;

function Noise(I: Integer): Double;
begin
  { Cheap xorshift-ish hash; stable across runs so tests can sniff WAV size. }
  Result := (((I * 1103515245 + 12345) shr 16) and $7FFF) / 16384.0 - 1.0;
end;

function BuildSfxWav(Kind: TSfxKind): TBytes;
var
  Samples, I: Integer;
  T, Hz, Phase, Env, Acc: Double;
begin
  Result := nil;
  case Kind of
    sfxTrudge:
      begin
        { Two-step boot clomp: low square thud, then a slightly higher one. }
        Samples := Round(Rate * 0.16);
        WriteWavHeader(Result, Samples);
        for I := 0 to Samples - 1 do
        begin
          T := I / Rate;
          if T < 0.07 then
          begin
            Env := Exp(-T * 28);
            Hz := 92;
          end
          else
          begin
            Env := Exp(-(T - 0.08) * 26);
            Hz := 118;
          end;
          Phase := Frac(T * Hz);
          PutSample(Result, I, Square(Phase, 0.38) * Env * 0.55 + Noise(I) * Env * 0.12);
        end;
      end;
    sfxOhNo:
      begin
        { Descending "oh no" — not the original sample, just a falling square. }
        Samples := Round(Rate * 0.42);
        WriteWavHeader(Result, Samples);
        for I := 0 to Samples - 1 do
        begin
          T := I / Rate;
          Env := 0.7 * (1.0 - T / 0.42);
          Hz := 620 * Power(0.35, T / 0.42);
          Phase := Frac(T * Hz);
          PutSample(Result, I, Square(Phase, 0.45) * Env);
        end;
      end;
    sfxSlide:
      begin
        { Dry scrape down a window frame. }
        Samples := Round(Rate * 0.22);
        WriteWavHeader(Result, Samples);
        for I := 0 to Samples - 1 do
        begin
          T := I / Rate;
          Env := 0.35 * (1.0 - T / 0.22);
          Acc := Noise(I) * Env + Square(Frac(T * 210), 0.2) * Env * 0.25;
          PutSample(Result, I, Acc);
        end;
      end;
    sfxUmbrella:
      begin
        { Soft rising whoosh when the brolly pops. }
        Samples := Round(Rate * 0.28);
        WriteWavHeader(Result, Samples);
        for I := 0 to Samples - 1 do
        begin
          T := I / Rate;
          Env := Sin(Pi * T / 0.28) * 0.4;
          Hz := 180 + T * 420;
          Phase := Frac(T * Hz);
          PutSample(Result, I, Square(Phase, 0.3) * Env * 0.5 + Noise(I) * Env * 0.2);
        end;
      end;
    sfxSplat:
      begin
        { Noise burst plus a dull thump. }
        Samples := Round(Rate * 0.30);
        WriteWavHeader(Result, Samples);
        for I := 0 to Samples - 1 do
        begin
          T := I / Rate;
          Env := Exp(-T * 14);
          Acc := Noise(I) * Env * 0.7 + Square(Frac(T * 70), 0.5) * Env * 0.35;
          PutSample(Result, I, Acc);
        end;
      end;
    sfxYippee:
      begin
        { Rising C–E–G–C arpeggio. Original fanfare, not the 1991 sample. }
        Samples := Round(Rate * 0.55);
        WriteWavHeader(Result, Samples);
        for I := 0 to Samples - 1 do
        begin
          T := I / Rate;
          if T < 0.11 then
            Hz := 523.25
          else if T < 0.22 then
            Hz := 659.25
          else if T < 0.33 then
            Hz := 783.99
          else
            Hz := 1046.50;
          Env := 0.55 * Exp(-(T - Trunc(T / 0.11) * 0.11) * 8);
          if T > 0.33 then
            Env := 0.62 * Exp(-(T - 0.33) * 5);
          Phase := Frac(T * Hz);
          PutSample(Result, I, Square(Phase, 0.42) * Env);
        end;
      end;
    else
      begin
        Samples := 64;
        WriteWavHeader(Result, Samples);
      end;
  end;
end;

function SfxName(Kind: TSfxKind): string;
begin
  case Kind of
    sfxTrudge: Result := 'trudge';
    sfxOhNo: Result := 'ohno';
    sfxSlide: Result := 'slide';
    sfxUmbrella: Result := 'umbrella';
    sfxSplat: Result := 'splat';
    sfxYippee: Result := 'yippee';
    else Result := 'none';
  end;
end;

end.
