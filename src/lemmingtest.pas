program lemmingtest;

{$mode objfpc}{$H+}

{ Headless checks for walk / slide / fall / splat / sfx. No window. }

uses
  SysUtils, Math, ulemmingconfig, ulemmingdesktop, ulemmingmodel,
  ulemmingaudio, ulemmingapp;

procedure ExpectNear(const LabelText: string; Got, Want, Eps: Double);
begin
  if Abs(Got - Want) > Eps then
  begin
    WriteLn('FAIL ', LabelText, ': got ', Got:0:6, ' want ', Want:0:6);
    Halt(1);
  end;
  WriteLn('ok   ', LabelText);
end;

procedure ExpectEq(const LabelText: string; Got, Want: Integer);
begin
  if Got <> Want then
  begin
    WriteLn('FAIL ', LabelText, ': got ', Got, ' want ', Want);
    Halt(1);
  end;
  WriteLn('ok   ', LabelText);
end;

procedure ExpectTrue(const LabelText: string; Ok: Boolean);
begin
  if not Ok then
  begin
    WriteLn('FAIL ', LabelText);
    Halt(1);
  end;
  WriteLn('ok   ', LabelText);
end;

var
  M: TLemmingModel;
  C: TLemmingsController;
  Cfg: TLemmingConfig;
  Desk: TDeskSnapshot;
  Wav: TBytes;
  SawSlide, SawFall, SawSplat, SawYippee, SawOhNo, SawTrudge: Boolean;
  K: TSfxKind;
  I: Integer;
begin
  ExpectEq('walk frame 0', WalkFrameOf(0), 0);
  ExpectEq('walk frame 4', WalkFrameOf(4), 0);
  ExpectEq('walk frame 2', WalkFrameOf(2), 2);
  ExpectTrue('state walk name', StateName(lsWalk) = 'walk');
  ExpectTrue('sfx yippee name', SfxName(sfxYippee) = 'yippee');

  Cfg := DefaultConfig;
  SetDensity(Cfg, 100);
  ExpectEq('density clamp high', Cfg.Density, MaxDensity);
  SetDensity(Cfg, 0);
  ExpectEq('density clamp low', Cfg.Density, MinDensity);

  Wav := BuildSfxWav(sfxTrudge);
  ExpectTrue('trudge wav header', (Length(Wav) > 44) and (Chr(Wav[0]) = 'R'));
  Wav := BuildSfxWav(sfxYippee);
  ExpectTrue('yippee wav size', Length(Wav) > 1000);

  M := TLemmingModel.Create;
  try
    M.Seed(42);
    M.SetScale(1);
    Cfg := DefaultConfig;
    Cfg.Density := 1;
    Cfg.Muted := True;
    M.SetConfig(Cfg);
    ExpectEq('pool size', M.LemmingCount, 1);

    ClearDesktop(Desk, 800, 500);
    AddDeskRect(Desk, 1, 100, 120, 400, 80, dkWindow);
    AddDeskRect(Desk, 2, 180, 280, 350, 90, dkWindow);
    M.SetDesktop(Desk);

    M.SlideChance := 1.0;
    M.FloaterEnabled := False;
    M.ForceLemming(0, lsWalk, 200, 120, 1, 0, 0);
    ExpectEq('forced walk', Ord(M.Lemming(0).State), Ord(lsWalk));
    ExpectTrue('alive after place', M.AliveCount >= 1);

    { A few steps from the right edge, always grab the frame. }
    M.ForceLemming(0, lsWalk, 480, 120, 1, 0, 0);
    SawSlide := False;
    for I := 0 to 90 do
    begin
      if M.Lemming(0).State = lsSlide then
        SawSlide := True;
      M.Update(1 / 30);
    end;
    ExpectTrue('reached slide on a ledge', SawSlide);

    { Same edge, but never slide — they step off. }
    M.SlideChance := 0.0;
    M.ForceLemming(0, lsWalk, 490, 120, 1, 0, 0);
    SawFall := False;
    SawOhNo := False;
    for I := 0 to 60 do
    begin
      if M.Lemming(0).State = lsFall then
        SawFall := True;
      while M.DrainSfx(K) do
        if K = sfxOhNo then
          SawOhNo := True;
      M.Update(1 / 30);
    end;
    ExpectTrue('fall when slide chance is 0', SawFall);
    ExpectTrue('oh-no on walk to fall', SawOhNo);

    { Long drop onto a low ledge without a brolly → splat. }
    ClearDesktop(Desk, 800, 500);
    AddDeskRect(Desk, 11, 200, 40, 200, 40, dkWindow);
    AddDeskRect(Desk, 12, 200, 360, 200, 40, dkWindow);
    M.SetDesktop(Desk);
    M.FloaterEnabled := False;
    M.ForceLemming(0, lsFall, 300, 42, 1, -1, 0);
    SawSplat := False;
    for I := 0 to 80 do
    begin
      if M.Lemming(0).State = lsSplat then
        SawSplat := True;
      M.Update(1 / 30);
    end;
    ExpectTrue('splat after a long drop', SawSplat);

    { Floater landing is a yippee. }
    M.FloaterEnabled := True;
    M.ForceLemming(0, lsFloat, 300, 80, 1, -1, 0);
    SawYippee := False;
    for I := 0 to 120 do
    begin
      while M.DrainSfx(K) do
        if K = sfxYippee then
          SawYippee := True;
      M.Update(1 / 30);
    end;
    ExpectTrue('yippee when a floater lands', SawYippee);

    { Trudge while walking a wide ledge. }
    ClearDesktop(Desk, 800, 500);
    AddDeskRect(Desk, 31, 0, 200, 800, 100, dkWindow);
    M.SetDesktop(Desk);
    M.SlideChance := 1.0;
    M.ForceLemming(0, lsWalk, 200, 200, 1, 0, 0);
    SawTrudge := False;
    for I := 0 to 40 do
    begin
      while M.DrainSfx(K) do
        if K = sfxTrudge then
          SawTrudge := True;
      M.Update(1 / 30);
    end;
    ExpectTrue('trudge while walking', SawTrudge);

    M.PlaceCataloguePose(800, 500);
    ExpectEq('catalogue count', M.LemmingCount, 6);
    ExpectEq('catalogue walk', Ord(M.Lemming(0).State), Ord(lsWalk));
    ExpectEq('catalogue slide', Ord(M.Lemming(1).State), Ord(lsSlide));
    ExpectEq('catalogue fall', Ord(M.Lemming(2).State), Ord(lsFall));
    ExpectEq('catalogue float', Ord(M.Lemming(3).State), Ord(lsFloat));
    ExpectEq('catalogue splat', Ord(M.Lemming(4).State), Ord(lsSplat));
    ExpectEq('catalogue cheer', Ord(M.Lemming(5).State), Ord(lsCheer));
  finally
    M.Free;
  end;

  C := TLemmingsController.Create(800, 500, 44, 22, DefaultConfig, False);
  try
    C.SetDesktop(MakeFallbackDesktop(800, 500));
    C.ApplyChar(']');
    ExpectEq('more density', C.Model.Config.Density, DefaultDensity + 1);
    C.ApplyChar('[');
    ExpectEq('less density', C.Model.Config.Density, DefaultDensity);
    C.ApplyChar('m');
    ExpectTrue('muted', C.Model.Config.Muted);
    C.ApplyChar(' ');
    ExpectTrue('paused', C.Model.Paused);
    C.Tick;
    C.Render;
    ExpectTrue('overlay pixels', C.Overlay.Width = 800);
    C.ConsumePresent;
  finally
    C.Free;
  end;

  WriteLn('all tests passed');
end.
