# Lemmings Overlay — nineties desktop walkers (Free Pascal)
#
# macOS:   make
# Linux:   sudo apt install fpc libgtk2.0-dev   &&  make linux
# Windows: from a native FPC install:            make windows

FPC      ?= fpc
SRC      := src
BUILD    := build
APP      := $(BUILD)/LemmingsOverlay.app
UNITS    := -Fu$(SRC) -FU$(BUILD) -FE$(BUILD)
FLAGS    := -Mobjfpc -Scgi -O2 -Xs

.PHONY: all app run linux windows test snap clean

all: app

$(BUILD):
	mkdir -p $(BUILD)

$(BUILD)/LemmingsOverlay: $(BUILD) $(SRC)/*.pas
	$(FPC) $(FLAGS) $(UNITS) -o$(BUILD)/LemmingsOverlay $(SRC)/lemmings.pas

$(BUILD)/lemmingtest: $(BUILD) $(SRC)/ulemmingconfig.pas $(SRC)/ulemmingdesktop.pas $(SRC)/ulemmingaudio.pas $(SRC)/ulemmingmodel.pas $(SRC)/ulemmingrender.pas $(SRC)/ubitmapfont.pas $(SRC)/ulemmingapp.pas $(SRC)/lemmingtest.pas
	$(FPC) $(FLAGS) $(UNITS) -o$(BUILD)/lemmingtest $(SRC)/lemmingtest.pas

$(BUILD)/lemmingsnap: $(BUILD) $(SRC)/ulemmingconfig.pas $(SRC)/ulemmingdesktop.pas $(SRC)/ulemmingaudio.pas $(SRC)/ulemmingmodel.pas $(SRC)/ulemmingrender.pas $(SRC)/ubitmapfont.pas $(SRC)/ulemmingapp.pas $(SRC)/lemmingsnap.pas
	$(FPC) $(FLAGS) $(UNITS) -o$(BUILD)/lemmingsnap $(SRC)/lemmingsnap.pas

app: $(BUILD)/LemmingsOverlay
	mkdir -p $(APP)/Contents/MacOS $(APP)/Contents/Resources
	cp $(BUILD)/LemmingsOverlay $(APP)/Contents/MacOS/LemmingsOverlay
	cp bundle/Info.plist $(APP)/Contents/Info.plist

run: app
	open $(APP)

linux: $(BUILD)
	$(FPC) $(FLAGS) $(UNITS) -o$(BUILD)/lemmingsoverlay $(SRC)/lemmings.pas

windows: $(BUILD)
	$(FPC) $(FLAGS) $(UNITS) -o$(BUILD)/LemmingsOverlay.exe $(SRC)/lemmings.pas

test: $(BUILD)/lemmingtest
	$(BUILD)/lemmingtest

snap: $(BUILD)/lemmingsnap
	$(BUILD)/lemmingsnap $(BUILD)

clean:
	rm -rf $(BUILD)
