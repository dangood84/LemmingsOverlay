unit uhostcocoa;

{$mode objfpc}{$H+}
{$modeswitch objectivec1}
{$linkframework Cocoa}
{$linkframework CoreGraphics}

{ macOS click-through overlay + menu extra. Accessory policy + LSUIElement
  = no Dock icon. Same TLemmingsController as Windows/Linux; this unit
  presents pixels, enumerates CG windows, and plays original WAV stings. }

interface

procedure HostRun;

implementation

uses
  SysUtils, Math, CocoaAll, ulemmingconfig, ulemmingdesktop, ulemmingapp,
  ulemmingaudio, ulemmingmodel;

const
  BarPointsW = 22;
  BarPointsH = 22;
  TickInterval = 1.0 / 30.0;
  kCGWindowListOptionOnScreenOnly = 1;
  kCGWindowListExcludeDesktopElements = 16;
  kCGNullWindowID = 0;

type
  TOverlayView = objcclass;
  TOverlayWindow = objcclass;

  NSBitmapImageRepLemming = objccategory external (NSBitmapImageRep)
    function initRGBA(planes: Pointer; aWidth: NSInteger; aHeight: NSInteger;
      aBits: NSInteger; aSamples: NSInteger; aAlpha: ObjCBOOL;
      aPlanar: ObjCBOOL; aSpace: NSString; aBpr: NSInteger;
      aBpp: NSInteger): id; message 'initWithBitmapDataPlanes:pixelsWide:pixelsHigh:bitsPerSample:samplesPerPixel:hasAlpha:isPlanar:colorSpaceName:bytesPerRow:bitsPerPixel:';
  end;

  TAppDelegate = objcclass(NSObject, NSApplicationDelegateProtocol)
  public
    controller: TLemmingsController;
    overlay: TOverlayWindow;
    view: TOverlayView;
    statusItem: NSStatusItem;
    frameImage: NSImage;
    barImage: NSImage;
    animTimer: NSTimer;
    scale: Double;
    ready: ObjCBOOL;
    askedCapture: ObjCBOOL;
    lastTrudge: NSTimeInterval;
    sfxSlot: Integer;
    procedure applicationDidFinishLaunching(notification: NSNotification); message 'applicationDidFinishLaunching:';
    procedure tick(timer: NSTimer); message 'tick:';
    procedure quitAction(sender: id); message 'quitAction:';
    procedure aboutAction(sender: id); message 'aboutAction:';
    procedure pauseAction(sender: id); message 'pauseAction:';
    procedure muteAction(sender: id); message 'muteAction:';
    procedure moreAction(sender: id); message 'moreAction:';
    procedure fewerAction(sender: id); message 'fewerAction:';
    procedure ledgesAction(sender: id); message 'ledgesAction:';
    procedure hudAction(sender: id); message 'hudAction:';
    procedure redraw; message 'redraw';
    procedure syncCanvasSize; message 'syncCanvasSize';
    procedure collectDesktop; message 'collectDesktop';
    procedure drainAudio; message 'drainAudio';
    procedure setup; message 'setup';
  end;

  TOverlayWindow = objcclass(NSWindow)
  public
    function canBecomeKeyWindow: ObjCBOOL; override;
    function canBecomeMainWindow: ObjCBOOL; override;
  end;

  TOverlayView = objcclass(NSView)
  public
    app: TAppDelegate;
    procedure drawRect(dirtyRect: NSRect); override;
    function isOpaque: ObjCBOOL; override;
  end;

var
  SharedApp: TAppDelegate;
  SfxWav: array[sfxTrudge..sfxYippee] of TBytes;
  SfxRing: array[0..5] of NSSound;

function CGWindowListCopyWindowInfo(option: LongWord; relativeToWindow: LongWord): Pointer; cdecl; external;
function CGRequestScreenCaptureAccess: Boolean; cdecl; external;
procedure CFRelease(cf: Pointer); cdecl; external;

function NSStr(const S: string): NSString;
begin
  Result := NSString.stringWithUTF8String(PChar(S));
end;

function MakeImage(Pixels: PByte; PixelW, PixelH: Integer; PointW, PointH: Double): NSImage;
var
  Rep: NSBitmapImageRep;
  Dest: PByte;
  Bytes: Integer;
begin
  Rep := NSBitmapImageRep(NSBitmapImageRep.alloc.initRGBA(nil, PixelW, PixelH, 8, 4,
    True, False, NSCalibratedRGBColorSpace, PixelW * 4, 32));
  Result := NSImage.alloc.initWithSize(NSMakeSize(PointW, PointH));
  if Rep <> nil then
  begin
    Dest := PByte(Rep.bitmapData);
    Bytes := PixelW * PixelH * 4;
    if (Dest <> nil) and (Pixels <> nil) and (Bytes > 0) then
      Move(Pixels^, Dest^, Bytes);
    Result.addRepresentation(Rep);
    Rep.release;
  end;
  Result.setCacheMode(NSImageCacheNever);
end;

procedure PlaySfx(Kind: TSfxKind);
var
  Data: NSData;
  Bytes: TBytes;
begin
  if (Kind < sfxTrudge) or (Kind > sfxYippee) then
    Exit;
  Bytes := SfxWav[Kind];
  if Length(Bytes) < 44 then
    Exit;
  Data := NSData.dataWithBytes_length(@Bytes[0], Length(Bytes));
  if SfxRing[SharedApp.sfxSlot] <> nil then
  begin
    SfxRing[SharedApp.sfxSlot].stop;
    SfxRing[SharedApp.sfxSlot].release;
    SfxRing[SharedApp.sfxSlot] := nil;
  end;
  SfxRing[SharedApp.sfxSlot] := NSSound.alloc.initWithData(Data);
  if SfxRing[SharedApp.sfxSlot] <> nil then
    SfxRing[SharedApp.sfxSlot].play;
  SharedApp.sfxSlot := (SharedApp.sfxSlot + 1) mod Length(SfxRing);
end;

procedure TAppDelegate.drainAudio;
var
  Kind: TSfxKind;
  Now: NSTimeInterval;
begin
  if controller = nil then
    Exit;
  if controller.Model.Config.Muted then
  begin
    while controller.Model.DrainSfx(Kind) do
      ;
    Exit;
  end;
  Now := NSDate.date.timeIntervalSinceReferenceDate;
  while controller.Model.DrainSfx(Kind) do
  begin
    if Kind = sfxTrudge then
    begin
      { Several walkers would otherwise machine-gun the clomp. }
      if Now - lastTrudge < 0.10 then
        Continue;
      lastTrudge := Now;
    end;
    PlaySfx(Kind);
  end;
end;

procedure TAppDelegate.collectDesktop;
var
  Desk: TDeskSnapshot;
  Info: Pointer;
  Arr: NSArray;
  Dict, Bounds: NSDictionary;
  I: Integer;
  Layer, Pid, Wid, OurPid, OverlayId: Integer;
  Alpha, X, Y, W, H: Double;
  Screen, Vis: NSRect;
  MenuH, DockH: Double;
  Num: NSNumber;
  Owner: NSString;
  WinCount: Integer;
begin
  if (controller = nil) or (NSScreen.mainScreen = nil) then
    Exit;
  Screen := NSScreen.mainScreen.frame;
  Vis := NSScreen.mainScreen.visibleFrame;
  ClearDesktop(Desk, controller.Overlay.Width, controller.Overlay.Height);

  MenuH := (NSMaxY(Screen) - NSMaxY(Vis)) * scale;
  DockH := (Vis.origin.y - Screen.origin.y) * scale;
  if MenuH > 2 then
    AddDeskRect(Desk, 8001, 0, MenuH, Desk.ScreenW, 6, dkScreenTop);
  if DockH > 8 then
    AddDeskRect(Desk, 8002, 0, Desk.ScreenH - DockH, Desk.ScreenW, DockH, dkDock);

  OurPid := Integer(NSProcessInfo.processInfo.processIdentifier);
  OverlayId := 0;
  if overlay <> nil then
    OverlayId := Integer(overlay.windowNumber);

  if not askedCapture then
  begin
    askedCapture := True;
    { First call may present the Screen Recording prompt so other apps'
      window bounds are not zeros. }
    CGRequestScreenCaptureAccess;
  end;

  Info := CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenOnly or
    kCGWindowListExcludeDesktopElements, kCGNullWindowID);
  WinCount := 0;
  if Info <> nil then
  begin
    Arr := NSArray(Info);
    for I := 0 to Arr.count - 1 do
    begin
      Dict := NSDictionary(Arr.objectAtIndex(I));
      if Dict = nil then
        Continue;
      Num := NSNumber(Dict.objectForKey(NSStr('kCGWindowLayer')));
      if Num = nil then
        Continue;
      Layer := Num.intValue;
      if Layer <> 0 then
        Continue;
      Num := NSNumber(Dict.objectForKey(NSStr('kCGWindowOwnerPID')));
      Pid := 0;
      if Num <> nil then
        Pid := Num.intValue;
      if Pid = OurPid then
        Continue;
      Num := NSNumber(Dict.objectForKey(NSStr('kCGWindowNumber')));
      Wid := 0;
      if Num <> nil then
        Wid := Num.intValue;
      if (Wid <> 0) and (Wid = OverlayId) then
        Continue;
      Num := NSNumber(Dict.objectForKey(NSStr('kCGWindowAlpha')));
      Alpha := 1;
      if Num <> nil then
        Alpha := Num.doubleValue;
      if Alpha < 0.05 then
        Continue;
      Owner := NSString(Dict.objectForKey(NSStr('kCGWindowOwnerName')));
      if (Owner <> nil) and (Owner.isEqualToString(NSStr('Dock')) or
          Owner.isEqualToString(NSStr('Window Server')) or
          Owner.isEqualToString(NSStr('Control Center'))) then
        Continue;
      Bounds := NSDictionary(Dict.objectForKey(NSStr('kCGWindowBounds')));
      if Bounds = nil then
        Continue;
      X := NSNumber(Bounds.objectForKey(NSStr('X'))).doubleValue * scale;
      Y := NSNumber(Bounds.objectForKey(NSStr('Y'))).doubleValue * scale;
      W := NSNumber(Bounds.objectForKey(NSStr('Width'))).doubleValue * scale;
      H := NSNumber(Bounds.objectForKey(NSStr('Height'))).doubleValue * scale;
      { Main-display overlay: skip windows that live entirely on another screen. }
      if (X + W < 0) or (Y + H < 0) or (X > Desk.ScreenW) or (Y > Desk.ScreenH) then
        Continue;
      if (W < 80 * scale) or (H < 48 * scale) then
        Continue;
      AddDeskRect(Desk, Wid, X, Y, W, H, dkWindow);
      Inc(WinCount);
    end;
    CFRelease(Info);
  end;

  if WinCount = 0 then
  begin
    { Permission denied or an empty Space: keep the gimmick alive. }
    Desk := MakeFallbackDesktop(Desk.ScreenW, Desk.ScreenH);
    if MenuH > 2 then
      AddDeskRect(Desk, 8001, 0, MenuH, Desk.ScreenW, 6, dkScreenTop);
  end;

  controller.SetDesktop(Desk);
end;

procedure TAppDelegate.redraw;
var
  B: NSRect;
  Btn: NSStatusBarButton;
begin
  if controller = nil then
    Exit;
  controller.Render;
  if view <> nil then
  begin
    B := view.bounds;
    if frameImage <> nil then
      frameImage.release;
    frameImage := MakeImage(controller.Overlay.Ptr, controller.Overlay.Width,
      controller.Overlay.Height, B.size.width, B.size.height);
    view.setNeedsDisplay_(True);
  end;
  if barImage <> nil then
    barImage.release;
  barImage := MakeImage(controller.Bar.Ptr, controller.Bar.Width,
    controller.Bar.Height, BarPointsW, BarPointsH);
  if statusItem <> nil then
  begin
    Btn := statusItem.button;
    if Btn <> nil then
    begin
      Btn.setImage(nil);
      Btn.setImage(barImage);
    end
    else
      statusItem.setImage(barImage);
  end;
  controller.ConsumePresent;
end;

procedure TAppDelegate.syncCanvasSize;
var
  B: NSRect;
  PW, PH: Integer;
  Scr: NSRect;
begin
  if (view = nil) or (controller = nil) or (NSScreen.mainScreen = nil) then
    Exit;
  Scr := NSScreen.mainScreen.frame;
  if overlay <> nil then
    overlay.setFrame_display(Scr, False);
  B := view.bounds;
  PW := Max(1, Round(B.size.width * scale));
  PH := Max(1, Round(B.size.height * scale));
  controller.Resize(PW, PH);
end;

procedure TAppDelegate.tick(timer: NSTimer);
var
  Pool: NSAutoreleasePool;
begin
  Pool := NSAutoreleasePool.alloc.init;
  if controller <> nil then
  begin
    syncCanvasSize;
    collectDesktop;
    controller.Tick;
    drainAudio;
    if controller.NeedsPresent then
      redraw;
  end;
  Pool.release;
end;

procedure TAppDelegate.setup;
var
  Menu: NSMenu;
  Item: NSMenuItem;
  PixelScale: Double;
  Scr: NSRect;
  Style: NSUInteger;
  Kind: TSfxKind;
  I: Integer;
begin
  if ready then
    Exit;
  ready := True;

  PixelScale := 2;
  if NSScreen.mainScreen <> nil then
    PixelScale := NSScreen.mainScreen.backingScaleFactor;
  if PixelScale < 1 then
    PixelScale := 1;
  scale := PixelScale;
  lastTrudge := 0;
  sfxSlot := 0;
  askedCapture := False;

  for Kind := sfxTrudge to sfxYippee do
    SfxWav[Kind] := BuildSfxWav(Kind);
  for I := 0 to High(SfxRing) do
    SfxRing[I] := nil;

  Scr := NSMakeRect(0, 0, 800, 500);
  if NSScreen.mainScreen <> nil then
    Scr := NSScreen.mainScreen.frame;

  controller := TLemmingsController.Create(
    Max(1, Round(Scr.size.width * scale)),
    Max(1, Round(Scr.size.height * scale)),
    Round(BarPointsW * scale), Round(BarPointsH * scale),
    LoadConfig);

  Menu := NSMenu.alloc.init;
  Item := NSMenuItem.alloc.initWithTitle_action_keyEquivalent(
    NSStr('Pause / Resume'), objcselector('pauseAction:'), NSStr(''));
  Item.setTarget(self);
  Menu.addItem(Item);
  Item.release;
  Item := NSMenuItem.alloc.initWithTitle_action_keyEquivalent(
    NSStr('Mute Sounds'), objcselector('muteAction:'), NSStr('m'));
  Item.setTarget(self);
  Menu.addItem(Item);
  Item.release;
  Item := NSMenuItem.alloc.initWithTitle_action_keyEquivalent(
    NSStr('More Lemmings'), objcselector('moreAction:'), NSStr(']'));
  Item.setTarget(self);
  Menu.addItem(Item);
  Item.release;
  Item := NSMenuItem.alloc.initWithTitle_action_keyEquivalent(
    NSStr('Fewer Lemmings'), objcselector('fewerAction:'), NSStr('['));
  Item.setTarget(self);
  Menu.addItem(Item);
  Item.release;
  Item := NSMenuItem.alloc.initWithTitle_action_keyEquivalent(
    NSStr('Show Ledges'), objcselector('ledgesAction:'), NSStr('d'));
  Item.setTarget(self);
  Menu.addItem(Item);
  Item.release;
  Item := NSMenuItem.alloc.initWithTitle_action_keyEquivalent(
    NSStr('Hide HUD'), objcselector('hudAction:'), NSStr('h'));
  Item.setTarget(self);
  Menu.addItem(Item);
  Item.release;
  Menu.addItem(NSMenuItem.separatorItem);
  Item := NSMenuItem.alloc.initWithTitle_action_keyEquivalent(
    NSStr('About Lemmings Overlay'), objcselector('aboutAction:'), NSStr(''));
  Item.setTarget(self);
  Menu.addItem(Item);
  Item.release;
  Menu.addItem(NSMenuItem.separatorItem);
  Item := NSMenuItem.alloc.initWithTitle_action_keyEquivalent(
    NSStr('Quit Lemmings Overlay'), objcselector('quitAction:'), NSStr('q'));
  Item.setTarget(self);
  Menu.addItem(Item);
  Item.release;

  statusItem := NSStatusBar.systemStatusBar.statusItemWithLength(BarPointsW);
  statusItem.retain;
  statusItem.setMenu(Menu);
  if statusItem.button <> nil then
    statusItem.button.setImagePosition(NSImageOnly);
  Menu.release;

  Style := NSBorderlessWindowMask;
  overlay := TOverlayWindow.alloc.initWithContentRect_styleMask_backing_defer(
    Scr, Style, NSBackingStoreBuffered, False);
  overlay.setTitle(NSStr('Lemmings Overlay'));
  overlay.setOpaque(False);
  overlay.setBackgroundColor(NSColor.clearColor);
  overlay.setHasShadow(False);
  overlay.setIgnoresMouseEvents(True);
  overlay.setLevel(NSStatusWindowLevel);
  overlay.setReleasedWhenClosed(False);
  overlay.setHidesOnDeactivate(False);
  overlay.setCollectionBehavior(NSWindowCollectionBehaviorCanJoinAllSpaces or
    NSWindowCollectionBehaviorStationary or NSWindowCollectionBehaviorIgnoresCycle);
  view := TOverlayView.alloc.initWithFrame(NSMakeRect(0, 0, Scr.size.width, Scr.size.height));
  view.app := self;
  overlay.setContentView(view);
  overlay.orderFront(nil);

  collectDesktop;
  redraw;

  animTimer := NSTimer.scheduledTimerWithTimeInterval_target_selector_userInfo_repeats(
    TickInterval, self, objcselector('tick:'), nil, True);
  animTimer.retain;
  NSRunLoop.currentRunLoop.addTimer_forMode(animTimer, NSRunLoopCommonModes);
end;

procedure TAppDelegate.applicationDidFinishLaunching(notification: NSNotification);
begin
  setup;
end;

procedure TAppDelegate.quitAction(sender: id);
var
  I: Integer;
begin
  for I := 0 to High(SfxRing) do
    if SfxRing[I] <> nil then
    begin
      SfxRing[I].stop;
      SfxRing[I].release;
      SfxRing[I] := nil;
    end;
  NSApplication.sharedApplication.terminate(nil);
end;

procedure TAppDelegate.aboutAction(sender: id);
var
  Alert: NSAlert;
begin
  NSApplication.sharedApplication.activateIgnoringOtherApps(True);
  Alert := NSAlert.alloc.init;
  Alert.setMessageText(NSStr(LemmingsAboutTitle));
  Alert.setInformativeText(NSStr(LemmingsAboutText));
  Alert.runModal;
  Alert.release;
end;

procedure TAppDelegate.pauseAction(sender: id);
begin
  if controller <> nil then
    controller.ApplyChar(' ');
end;

procedure TAppDelegate.muteAction(sender: id);
begin
  if controller <> nil then
    controller.ApplyChar('M');
end;

procedure TAppDelegate.moreAction(sender: id);
begin
  if controller <> nil then
    controller.ApplyChar(']');
end;

procedure TAppDelegate.fewerAction(sender: id);
begin
  if controller <> nil then
    controller.ApplyChar('[');
end;

procedure TAppDelegate.ledgesAction(sender: id);
begin
  if controller <> nil then
    controller.ApplyChar('D');
end;

procedure TAppDelegate.hudAction(sender: id);
begin
  if controller <> nil then
    controller.ApplyChar('H');
end;

procedure TOverlayView.drawRect(dirtyRect: NSRect);
var
  Ctx: NSGraphicsContext;
begin
  Ctx := NSGraphicsContext.currentContext;
  if Ctx <> nil then
    Ctx.setCompositingOperation(NSCompositeCopy);
  NSColor.clearColor.set_;
  NSRectFill(self.bounds);
  if Ctx <> nil then
    Ctx.setCompositingOperation(NSCompositeSourceOver);
  if (app = nil) or (app.frameImage = nil) then
    Exit;
  app.frameImage.drawInRect_fromRect_operation_fraction(self.bounds, NSZeroRect,
    NSCompositeSourceOver, 1.0);
end;

function TOverlayView.isOpaque: ObjCBOOL;
begin
  Result := False;
end;

function TOverlayWindow.canBecomeKeyWindow: ObjCBOOL;
begin
  Result := False;
end;

function TOverlayWindow.canBecomeMainWindow: ObjCBOOL;
begin
  Result := False;
end;

procedure HostRun;
var
  Pool: NSAutoreleasePool;
  App: NSApplication;
begin
  Pool := NSAutoreleasePool.alloc.init;
  App := NSApplication.sharedApplication;
  { Accessory + Info.plist LSUIElement: menu extra only, no Dock / Cmd-Tab. }
  App.setActivationPolicy(NSApplicationActivationPolicyAccessory);
  SharedApp := TAppDelegate.alloc.init;
  App.setDelegate(SharedApp);
  SharedApp.setup;
  App.run;
  Pool.release;
end;

end.
