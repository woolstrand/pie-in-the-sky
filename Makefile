# Builds the HAL driver and the menu bar app with the Command Line Tools only (no Xcode project).
VERSION     := $(shell cat VERSION)
BUILD       := build
DRIVER      := $(BUILD)/PieInTheSky.driver
APP         := $(BUILD)/Pie in the Sky.app
ARCHS       := -arch arm64 -arch x86_64
DRIVER_MIN  := 12.0
APP_MIN     := 15.0
SIGN_ID     ?= -

DRIVER_DEFS := -DkNumber_Of_Channels=2 \
               -DkPlugIn_BundleID='"io.github.woolstrand.pieinthesky.driver"' \
               -DkDriver_Name='"Pie in the Sky"' \
               -DkHas_Driver_Name_Format=false \
               -DkDevice_Name='"Pie in the Sky"' \
               -DkManufacturer_Name='"pie-in-the-sky"' \
               -DkPlugIn_Icon='"PieInTheSky.icns"'

SWIFT_SRC   := $(wildcard app/Sources/*.swift)

.PHONY: all driver app clean install uninstall zip

all: app

driver: $(DRIVER)/Contents/MacOS/PieInTheSky

$(DRIVER)/Contents/MacOS/PieInTheSky: driver/PieInTheSky.c driver/Info.plist VERSION
	@mkdir -p "$(DRIVER)/Contents/MacOS"
	sed 's/@VERSION@/$(VERSION)/g' driver/Info.plist > "$(DRIVER)/Contents/Info.plist"
	clang -bundle -O2 $(ARCHS) -mmacosx-version-min=$(DRIVER_MIN) -Wno-deprecated-declarations -Wno-format-extra-args \
		$(DRIVER_DEFS) -framework CoreAudio -framework CoreFoundation -framework Accelerate \
		-o "$@" driver/PieInTheSky.c
	codesign --force --sign "$(SIGN_ID)" "$(DRIVER)"

app: driver $(SWIFT_SRC) app/Info.plist VERSION
	@mkdir -p "$(APP)/Contents/MacOS" "$(APP)/Contents/Resources"
	sed 's/@VERSION@/$(VERSION)/g' app/Info.plist > "$(APP)/Contents/Info.plist"
	swiftc -O -target arm64-apple-macos$(APP_MIN) -o $(BUILD)/app-arm64 $(SWIFT_SRC)
	swiftc -O -target x86_64-apple-macos$(APP_MIN) -o $(BUILD)/app-x86_64 $(SWIFT_SRC)
	lipo -create -output "$(APP)/Contents/MacOS/PieInTheSky" $(BUILD)/app-arm64 $(BUILD)/app-x86_64
	rm -rf "$(APP)/Contents/Resources/PieInTheSky.driver"
	cp -R "$(DRIVER)" "$(APP)/Contents/Resources/"
	codesign --force --sign "$(SIGN_ID)" "$(APP)"

# Copies the app to /Applications and starts it; the app offers to install the driver on first launch.
install: app
	rm -rf "/Applications/Pie in the Sky.app"
	cp -R "$(APP)" /Applications/
	open "/Applications/Pie in the Sky.app"

uninstall:
	./uninstall.sh

zip: app
	cd $(BUILD) && ditto -c -k --keepParent "Pie in the Sky.app" "Pie-in-the-Sky-$(VERSION).zip"

clean:
	rm -rf $(BUILD)
