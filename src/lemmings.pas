program LemmingsOverlay;

{$mode objfpc}{$H+}
{$IFDEF DARWIN}
{$modeswitch objectivec1}
{$linkframework Cocoa}
{$linkframework CoreGraphics}
{$ENDIF}

{ Lemmings Overlay — nineties desktop walkers in Pascal.

  macOS:    click-through fullscreen overlay + menu extra (no Dock icon).
  Windows:  layered click-through overlay + notification-area icon.
  Linux:    GTK 2 click-through overlay + panel status icon.

  Only one HostRun is linked; the other two host units are not compiled.
  Build: see the Makefile. }

uses
  {$IFDEF DARWIN}
  uhostcocoa
  {$ELSE}
    {$IFDEF WINDOWS}
    uhostwin
    {$ELSE}
    uhostgtk
    {$ENDIF}
  {$ENDIF};

begin
  HostRun; { Cocoa run loop, Win32 GetMessage, or gtk_main — see uhost*.pas }
end.
