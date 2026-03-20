# Android TV Multicast MPEGTS Player - Makefile
#
# Usage:
#   make setup      - Install prerequisites (JDK 17, SDK components, AVD)
#   make build      - Build the debug APK
#   make emulator   - Launch Android TV emulator
#   make install    - Install APK on emulator
#   make stream     - Start ffmpeg test stream with UDP redirect
#   make run        - Full pipeline: build, install, launch app, stream
#   make stop       - Stop emulator and ffmpeg
#   make clean      - Clean build artifacts
#   make logs       - Tail logcat for player events

SHELL := /bin/bash

# Configuration
ANDROID_HOME     ?= $(HOME)/Library/Android/sdk
JAVA_HOME        ?= $(shell brew --prefix openjdk@17 2>/dev/null)/libexec/openjdk.jdk/Contents/Home
AVD_NAME         := TV_API_34
PACKAGE          := com.cryptoguard.multicastplayer
ACTIVITY         := .MainActivity
APK              := app/build/outputs/apk/debug/app-debug.apk
EMULATOR_SERIAL  := emulator-5554
UDP_PORT         := 5000

# Stream configuration
STREAM_RESOLUTION := 1280x720
STREAM_FRAMERATE := 25
STREAM_BITRATE   := 3M
STREAM_GOP       := 50

# Tool paths
ADB              := $(ANDROID_HOME)/platform-tools/adb
EMULATOR         := $(ANDROID_HOME)/emulator/emulator
SDKMANAGER       := $(ANDROID_HOME)/cmdline-tools/latest/bin/sdkmanager
AVDMANAGER       := $(ANDROID_HOME)/cmdline-tools/latest/bin/avdmanager
GRADLEW          := ./gradlew

export JAVA_HOME
export ANDROID_HOME

.PHONY: setup build emulator install launch stream run stop clean logs help check-env

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-15s\033[0m %s\n", $$1, $$2}'

check-env: ## Verify prerequisites are installed
	@echo "Checking prerequisites..."
	@command -v brew >/dev/null 2>&1 || { echo "ERROR: Homebrew not found"; exit 1; }
	@test -x "$(JAVA_HOME)/bin/java" || { echo "ERROR: JDK 17 not found. Run 'make setup'"; exit 1; }
	@test -x "$(ADB)" || { echo "ERROR: Android SDK not found at $(ANDROID_HOME)"; exit 1; }
	@test -x "$(EMULATOR)" || { echo "ERROR: Android emulator not found"; exit 1; }
	@command -v ffmpeg >/dev/null 2>&1 || { echo "ERROR: ffmpeg not found. Install with 'brew install ffmpeg'"; exit 1; }
	@echo "All prerequisites OK."

setup: ## Install JDK 17, Android SDK components, and create TV AVD
	@echo "==> Installing JDK 17..."
	brew install openjdk@17 || true
	@echo "==> Installing Android cmdline-tools..."
	@if [ ! -x "$(SDKMANAGER)" ]; then \
		brew install --cask android-commandlinetools || true; \
		sdkmanager --sdk_root=$(ANDROID_HOME) --install "cmdline-tools;latest"; \
	fi
	@echo "==> Installing Android TV system image..."
	yes | $(SDKMANAGER) --sdk_root=$(ANDROID_HOME) \
		"system-images;android-34;android-tv;arm64-v8a" \
		"platforms;android-34" \
		"build-tools;36.0.0"
	@echo "==> Creating Android TV AVD..."
	@$(AVDMANAGER) list avd 2>/dev/null | grep -q "$(AVD_NAME)" || \
		echo "no" | $(AVDMANAGER) create avd \
			-n "$(AVD_NAME)" \
			-k "system-images;android-34;android-tv;arm64-v8a" \
			-d "tv_1080p"
	@echo "==> Writing local.properties..."
	echo "sdk.dir=$(ANDROID_HOME)" > local.properties
	@echo "Setup complete!"

build: check-env ## Build the debug APK
	@echo "==> Building APK..."
	$(GRADLEW) assembleDebug
	@echo "APK built: $(APK)"

emulator: check-env ## Launch Android TV emulator in background
	@if $(ADB) devices 2>/dev/null | grep -q "$(EMULATOR_SERIAL)"; then \
		echo "Emulator already running."; \
	else \
		echo "==> Launching Android TV emulator..."; \
		$(EMULATOR) -avd $(AVD_NAME) -no-snapshot-load -gpu auto &>/dev/null & \
		echo "Waiting for emulator to boot..."; \
		$(ADB) -s $(EMULATOR_SERIAL) wait-for-device; \
		while [ "$$($(ADB) -s $(EMULATOR_SERIAL) shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" != "1" ]; do \
			sleep 2; \
		done; \
		echo "Emulator booted."; \
	fi

install: build ## Install APK and launch app on emulator
	@echo "==> Installing APK..."
	$(ADB) -s $(EMULATOR_SERIAL) install -r $(APK)
	@echo "==> Launching app..."
	$(ADB) -s $(EMULATOR_SERIAL) shell am start -n $(PACKAGE)/$(ACTIVITY)
	@echo "App launched."

redirect: ## Set up UDP port redirect on emulator
	@echo "==> Setting up UDP redirect (host:$(UDP_PORT) -> guest:$(UDP_PORT))..."
	@AUTH_TOKEN=$$(cat ~/.emulator_console_auth_token 2>/dev/null); \
	(echo "auth $$AUTH_TOKEN"; sleep 0.3; echo "redir add udp:$(UDP_PORT):$(UDP_PORT)"; sleep 0.3; echo "quit") \
		| nc localhost 5554 >/dev/null 2>&1
	@echo "UDP redirect active."

stream: redirect ## Start ffmpeg MPEGTS test stream (with UDP redirect)
	@echo "==> Starting ffmpeg test stream on udp://127.0.0.1:$(UDP_PORT)..."
	@echo "    Video: $(STREAM_RESOLUTION)@$(STREAM_FRAMERATE)fps H.264 $(STREAM_BITRATE)"
	@echo "    Audio: AAC 48kHz stereo 128kbps + sine tone"
	@echo "    Overlay: live clock, frame counter, PTS"
	@echo "    Press Ctrl+C to stop the stream."
	@echo ""
	@# Generate filter script with correct resolution
	@sed "s/1280x720/$(STREAM_RESOLUTION)/g" ffmpeg_filter.txt > /tmp/multicast_filter.txt
	ffmpeg -re \
		-f lavfi -i "testsrc2=size=$(STREAM_RESOLUTION):rate=$(STREAM_FRAMERATE)" \
		-f lavfi -i "sine=frequency=440:sample_rate=48000" \
		-filter_complex_script /tmp/multicast_filter.txt \
		-map "[vout]" -map 1:a \
		-c:v libx264 -preset ultrafast -tune zerolatency \
		-b:v $(STREAM_BITRATE) -maxrate $(STREAM_BITRATE) -bufsize 1M \
		-g $(STREAM_GOP) -keyint_min $(STREAM_GOP) \
		-flags +cgop \
		-c:a aac -b:a 128k -ac 2 \
		-mpegts_flags +resend_headers \
		-muxrate 4M \
		-f mpegts "udp://127.0.0.1:$(UDP_PORT)?pkt_size=1316&buffer_size=65536"

run: emulator install stream ## Full pipeline: emulator, build, install, stream

stop: ## Stop emulator and any ffmpeg test streams
	@echo "==> Stopping ffmpeg..."
	-pkill -f "ffmpeg.*udp://127.0.0.1:$(UDP_PORT)" 2>/dev/null || true
	@echo "==> Stopping emulator..."
	-$(ADB) -s $(EMULATOR_SERIAL) emu kill 2>/dev/null || true
	@echo "Stopped."

logs: ## Tail logcat for player events
	$(ADB) -s $(EMULATOR_SERIAL) logcat -s MulticastPlayer ExoPlayerImpl

clean: ## Clean build artifacts
	$(GRADLEW) clean
	@echo "Clean complete."

screenshot: ## Take a screenshot of the emulator
	@$(ADB) -s $(EMULATOR_SERIAL) exec-out screencap -p > screenshot.png
	@echo "Screenshot saved to screenshot.png"
