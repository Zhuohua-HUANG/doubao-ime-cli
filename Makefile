PROJECT := doubao-ime-cli
BINARY ?= doubao-voice
VERSION ?= 0.1.0
LANGUAGE ?= zh-Hans
SRC := src/doubao-voice.m
APP_SRC := src/doubao-voice-helper-app.m
ICON_TOOL_SRC := tools/make-app-icon.m
BUILD_DIR := build
APP_BUNDLE_NAME := DoubaoVoiceCLI.app
APP_BUNDLE := $(BUILD_DIR)/$(APP_BUNDLE_NAME)
APP_EXECUTABLE := DoubaoVoiceCLI
APP_ICON := $(BUILD_DIR)/AppIcon.icns
ICON_TOOL := $(BUILD_DIR)/make-app-icon
FSMN_WORKER := scripts/fsmn_vad_worker.py
PREFIX ?= $(HOME)/.local
BINDIR ?= $(PREFIX)/bin

FRAMEWORKS := -framework Foundation -framework ApplicationServices -framework CoreGraphics -framework AppKit
CFLAGS ?= -Wall -Wextra -Wpedantic -O2
APP_FRAMEWORKS := -framework Cocoa -framework ApplicationServices -framework CoreGraphics -framework AVFoundation
APP_CFLAGS ?= -Wall -Wextra -Wpedantic -O2 -fobjc-arc

.PHONY: all build app install uninstall clean check pkg dmg

all: build

build: $(BUILD_DIR)/$(BINARY) $(APP_BUNDLE)

$(BUILD_DIR)/$(BINARY): $(SRC)
	@mkdir -p $(BUILD_DIR)
	clang $(CFLAGS) $(SRC) $(FRAMEWORKS) -o $@

app: $(APP_BUNDLE)

$(ICON_TOOL): $(ICON_TOOL_SRC)
	@mkdir -p $(BUILD_DIR)
	clang $(APP_CFLAGS) $(ICON_TOOL_SRC) -framework Cocoa -o $@

$(APP_ICON): assets/AppIcon.icns.base64
	@mkdir -p $(BUILD_DIR)
	base64 -D -i assets/AppIcon.icns.base64 -o "$(APP_ICON)"
	test -s "$(APP_ICON)"

$(APP_BUNDLE): $(APP_SRC) packaging/app/Info.plist $(APP_ICON) $(FSMN_WORKER)
	rm -rf "$(APP_BUNDLE)"
	mkdir -p "$(APP_BUNDLE)/Contents/MacOS" "$(APP_BUNDLE)/Contents/Resources"
	cp packaging/app/Info.plist "$(APP_BUNDLE)/Contents/Info.plist"
	plutil -replace CFBundleShortVersionString -string "$(VERSION)" "$(APP_BUNDLE)/Contents/Info.plist"
	plutil -replace CFBundleVersion -string "$(VERSION)" "$(APP_BUNDLE)/Contents/Info.plist"
	clang $(APP_CFLAGS) $(APP_SRC) $(APP_FRAMEWORKS) -o "$(APP_BUNDLE)/Contents/MacOS/$(APP_EXECUTABLE)"
	cp "$(APP_ICON)" "$(APP_BUNDLE)/Contents/Resources/AppIcon.icns"
	cp "$(FSMN_WORKER)" "$(APP_BUNDLE)/Contents/Resources/fsmn_vad_worker.py"

install: build
	@mkdir -p "$(BINDIR)"
	cp "$(BUILD_DIR)/$(BINARY)" "$(BINDIR)/$(BINARY)"
	@echo "Installed $(BINARY) to $(BINDIR)/$(BINARY)"
	@echo "Run: $(BINDIR)/$(BINARY) check --prompt"

uninstall:
	rm -f "$(BINDIR)/$(BINARY)"
	@echo "Removed $(BINDIR)/$(BINARY)"

check: build
	"$(BUILD_DIR)/$(BINARY)" inspect

pkg: build
	VERSION="$(VERSION)" LANGUAGE="$(LANGUAGE)" BINARY="$(BINARY)" ./scripts/build-pkg.sh

dmg: build
	VERSION="$(VERSION)" LANGUAGE="$(LANGUAGE)" BINARY="$(BINARY)" ./scripts/build-dmg.sh

clean:
	rm -rf "$(BUILD_DIR)" dist
