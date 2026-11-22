# Builds the HAL driver and the menu bar app with the Command Line Tools only (no Xcode project).
VERSION     := $(shell cat VERSION)
BUILD       := build
DRIVER      := $(BUILD)/BTLatencyProxy.driver
APP         := $(BUILD)/BT Latency Proxy.app
ARCHS       := -arch arm64 -arch x86_64
DRIVER_MIN  := 12.0
APP_MIN     := 15.0
SIGN_ID     ?= -

DRIVER_DEFS := -DkNumber_Of_Channels=2 \
               -DkPlugIn_BundleID='"io.github.woolstrand.btlatencyproxy.driver"' \
               -DkDriver_Name='"BT Latency Proxy"' \
               -DkHas_Driver_Name_Format=false \
               -DkDevice_Name='"BT Latency Proxy"' \
               -DkManufacturer_Name='"bt-latency-proxy"' \
               -DkPlugIn_Icon='"BTLatencyProxy.icns"'

SWIFT_SRC   := $(wildcard app/Sources/*.swift)

.PHONY: all driver app clean install uninstall zip

all: app

driver: $(DRIVER)/Contents/MacOS/BTLatencyProxy

$(DRIVER)/Contents/MacOS/BTLatencyProxy: driver/BTLatencyProxy.c driver/Info.plist VERSION
	@mkdir -p "$(DRIVER)/Contents/MacOS"
	sed 's/@VERSION@/$(VERSION)/g' driver/Info.plist > "$(DRIVER)/Contents/Info.plist"
	clang -bundle -O2 $(ARCHS) -mmacosx-version-min=$(DRIVER_MIN) -Wno-deprecated-declarations -Wno-format-extra-args \
		$(DRIVER_DEFS) -framework CoreAudio -framework CoreFoundation -framework Accelerate \
		-o "$@" driver/BTLatencyProxy.c
	codesign --force --sign "$(SIGN_ID)" "$(DRIVER)"

app: driver $(SWIFT_SRC) app/Info.plist VERSION
	@mkdir -p "$(APP)/Contents/MacOS" "$(APP)/Contents/Resources"
	sed 's/@VERSION@/$(VERSION)/g' app/Info.plist > "$(APP)/Contents/Info.plist"
	swiftc -O -target arm64-apple-macos$(APP_MIN) -o $(BUILD)/app-arm64 $(SWIFT_SRC)
	swiftc -O -target x86_64-apple-macos$(APP_MIN) -o $(BUILD)/app-x86_64 $(SWIFT_SRC)
	lipo -create -output "$(APP)/Contents/MacOS/BTLatencyProxy" $(BUILD)/app-arm64 $(BUILD)/app-x86_64
	rm -rf "$(APP)/Contents/Resources/BTLatencyProxy.driver"
	cp -R "$(DRIVER)" "$(APP)/Contents/Resources/"
	codesign --force --sign "$(SIGN_ID)" "$(APP)"

# Copies the app to /Applications and starts it; the app offers to install the driver on first launch.
install: app
	rm -rf "/Applications/BT Latency Proxy.app"
	cp -R "$(APP)" /Applications/
	open "/Applications/BT Latency Proxy.app"

uninstall:
	./uninstall.sh

zip: app
	cd $(BUILD) && ditto -c -k --keepParent "BT Latency Proxy.app" "BT-Latency-Proxy-$(VERSION).zip"

clean:
	rm -rf $(BUILD)
