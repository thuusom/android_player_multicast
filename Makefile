# Android TV Multicast MPEGTS Player - Makefile
#
# Cross-platform: macOS (Intel/Apple Silicon) and Linux (x86_64/arm64)
# Targets: Android TV emulator OR real Google TV / STB hardware
#
# Emulator usage:
#   make setup      - Install prerequisites (JDK 17, SDK components, AVD)
#   make run        - Full pipeline: emulator, build, install, stream
#
# STB usage (pass STB_IP=<ip>):
#   make stb-setup  STB_IP=192.168.1.100   - Interactive STB setup
#   make stb-run    STB_IP=192.168.1.100   - Full pipeline to STB
#   make stb-stream STB_IP=192.168.1.100   - Stream to STB

SHELL := /bin/bash

# --- Platform detection ---
UNAME_S := $(shell uname -s)
UNAME_M := $(shell uname -m)

ifeq ($(UNAME_S),Darwin)
  PLATFORM := macos
else ifeq ($(UNAME_S),Linux)
  PLATFORM := linux
else
  $(error Unsupported OS: $(UNAME_S). Use macOS or Linux.)
endif

ifeq ($(filter $(UNAME_M),x86_64 amd64),)
  ifeq ($(filter $(UNAME_M),arm64 aarch64),)
    $(error Unsupported architecture: $(UNAME_M))
  else
    EMU_ABI := arm64-v8a
  endif
else
  EMU_ABI := x86_64
endif

# --- ANDROID_HOME per platform ---
ifeq ($(PLATFORM),macos)
  ANDROID_HOME ?= $(HOME)/Library/Android/sdk
else
  ANDROID_HOME ?= $(HOME)/Android/Sdk
endif

# --- JAVA_HOME per platform ---
ifeq ($(PLATFORM),macos)
  JAVA_HOME ?= $(shell \
    if brew --prefix openjdk@17 >/dev/null 2>&1; then \
      echo "$$(brew --prefix openjdk@17)/libexec/openjdk.jdk/Contents/Home"; \
    elif /usr/libexec/java_home -v 17 >/dev/null 2>&1; then \
      /usr/libexec/java_home -v 17; \
    fi)
else
  JAVA_HOME ?= $(shell \
    for d in \
      /usr/lib/jvm/java-17-openjdk-amd64 \
      /usr/lib/jvm/java-17-openjdk-arm64 \
      /usr/lib/jvm/java-17-openjdk \
      /usr/lib/jvm/java-17; do \
      if [ -x "$$d/bin/java" ]; then echo "$$d"; break; fi; \
    done)
endif

# --- GPU mode ---
ifeq ($(PLATFORM),linux)
  GPU_MODE ?= $(shell if [ -z "$$DISPLAY" ] && [ -z "$$WAYLAND_DISPLAY" ]; then echo "swiftshader_indirect"; else echo "auto"; fi)
else
  GPU_MODE ?= auto
endif

# --- Configuration ---
AVD_NAME         := TV_API_34
PACKAGE          := com.cryptoguard.multicastplayer
ACTIVITY         := .MainActivity
APK              := app/build/outputs/apk/debug/app-debug.apk
EMULATOR_SERIAL  := emulator-5554
UDP_PORT         := 5000
SYSTEM_IMAGE     := system-images;android-34;android-tv;$(EMU_ABI)

# STB configuration (pass on command line: make stb-run STB_IP=192.168.1.100)
STB_IP           ?=
STB_ADB_PORT     ?= 5555
STB_TARGET       = $(STB_IP):$(STB_ADB_PORT)
MULTICAST_GROUP  ?=

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

.PHONY: setup build emulator install stream run stop clean logs help check-env info \
        stb-setup stb-connect stb-disconnect stb-info stb-install stb-stream stb-run stb-stop stb-logs stb-screenshot

# =====================================================================
# Help & Info
# =====================================================================

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-20s\033[0m %s\n", $$1, $$2}'

info: ## Show detected platform, architecture, and tool paths
	@echo "Platform:       $(PLATFORM)"
	@echo "Architecture:   $(UNAME_M)"
	@echo "Emulator ABI:   $(EMU_ABI)"
	@echo "System image:   $(SYSTEM_IMAGE)"
	@echo "GPU mode:       $(GPU_MODE)"
	@echo "JAVA_HOME:      $(JAVA_HOME)"
	@echo "ANDROID_HOME:   $(ANDROID_HOME)"
	@echo "ADB:            $(ADB)"
	@echo "Emulator:       $(EMULATOR)"
	@echo "ffmpeg:         $$(command -v ffmpeg 2>/dev/null || echo '<not found>')"

check-env: ## Verify prerequisites are installed
	@echo "Checking prerequisites ($(PLATFORM)/$(UNAME_M))..."
	@test -x "$(JAVA_HOME)/bin/java" || { echo "ERROR: JDK 17 not found at $(JAVA_HOME). Run 'make setup'"; exit 1; }
	@test -x "$(ADB)" || { echo "ERROR: Android SDK not found at $(ANDROID_HOME). Run 'make setup'"; exit 1; }
	@command -v ffmpeg >/dev/null 2>&1 || { echo "ERROR: ffmpeg not found. Run 'make setup'"; exit 1; }
	@echo "All prerequisites OK."

# =====================================================================
# Setup
# =====================================================================

setup: ## Install JDK 17, Android SDK components, and create TV AVD
	@echo "==> Platform: $(PLATFORM) ($(UNAME_M)), ABI: $(EMU_ABI)"
	@echo ""
	@echo "==> Installing JDK 17..."
ifeq ($(PLATFORM),macos)
	@command -v brew >/dev/null 2>&1 || { echo "ERROR: Homebrew required on macOS. Install from https://brew.sh"; exit 1; }
	brew install openjdk@17 || true
else
	@if command -v apt-get >/dev/null 2>&1; then \
		sudo apt-get update && sudo apt-get install -y openjdk-17-jdk-headless; \
	elif command -v dnf >/dev/null 2>&1; then \
		sudo dnf install -y java-17-openjdk-devel; \
	elif command -v pacman >/dev/null 2>&1; then \
		sudo pacman -Sy --noconfirm jdk17-openjdk; \
	else \
		echo "ERROR: Install JDK 17 manually and set JAVA_HOME"; exit 1; \
	fi
endif
	@echo "==> Installing ffmpeg..."
ifeq ($(PLATFORM),macos)
	@command -v ffmpeg >/dev/null 2>&1 || brew install ffmpeg || true
else
	@command -v ffmpeg >/dev/null 2>&1 || { \
		if command -v apt-get >/dev/null 2>&1; then \
			sudo apt-get install -y ffmpeg; \
		elif command -v dnf >/dev/null 2>&1; then \
			sudo dnf install -y ffmpeg; \
		elif command -v pacman >/dev/null 2>&1; then \
			sudo pacman -Sy --noconfirm ffmpeg; \
		fi; \
	}
endif
	@echo "==> Installing Android cmdline-tools..."
	@if [ ! -x "$(SDKMANAGER)" ]; then \
		if [ "$(PLATFORM)" = "macos" ]; then \
			brew install --cask android-commandlinetools || true; \
			sdkmanager --sdk_root=$(ANDROID_HOME) --install "cmdline-tools;latest"; \
		else \
			echo "Downloading Android cmdline-tools..."; \
			mkdir -p $(ANDROID_HOME); \
			curl -fSL -o /tmp/cmdtools.zip \
				"https://dl.google.com/android/repository/commandlinetools-linux-11076708_latest.zip"; \
			unzip -qo /tmp/cmdtools.zip -d $(ANDROID_HOME)/cmdline-tools-tmp; \
			mkdir -p $(ANDROID_HOME)/cmdline-tools; \
			mv $(ANDROID_HOME)/cmdline-tools-tmp/cmdline-tools $(ANDROID_HOME)/cmdline-tools/latest; \
			rm -rf $(ANDROID_HOME)/cmdline-tools-tmp /tmp/cmdtools.zip; \
		fi; \
	fi
ifeq ($(PLATFORM),linux)
	@if [ "$(EMU_ABI)" = "x86_64" ] && [ ! -w /dev/kvm ]; then \
		echo ""; \
		echo "WARNING: /dev/kvm is not writable. The emulator will be very slow."; \
		echo "  Fix: sudo apt install qemu-kvm && sudo adduser $$USER kvm"; \
		echo ""; \
	fi
endif
	@echo "==> Installing Android TV system image ($(EMU_ABI))..."
	yes | $(SDKMANAGER) --sdk_root=$(ANDROID_HOME) \
		"$(SYSTEM_IMAGE)" \
		"platforms;android-34" \
		"platform-tools" \
		"emulator" \
		"build-tools;36.0.0"
	@echo "==> Creating Android TV AVD..."
	@$(AVDMANAGER) list avd 2>/dev/null | grep -q "$(AVD_NAME)" || \
		echo "no" | $(AVDMANAGER) create avd \
			-n "$(AVD_NAME)" \
			-k "$(SYSTEM_IMAGE)" \
			-d "tv_1080p"
	@echo "==> Writing local.properties..."
	echo "sdk.dir=$(ANDROID_HOME)" > local.properties
	@echo ""
	@echo "Setup complete!"

# =====================================================================
# Emulator targets
# =====================================================================

build: check-env ## Build the debug APK
	@echo "==> Building APK..."
	$(GRADLEW) assembleDebug
	@echo "APK built: $(APK)"

emulator: check-env ## Launch Android TV emulator in background
	@if $(ADB) devices 2>/dev/null | grep -q "$(EMULATOR_SERIAL)"; then \
		echo "Emulator already running."; \
	else \
		echo "==> Launching Android TV emulator (gpu=$(GPU_MODE))..."; \
		$(EMULATOR) -avd $(AVD_NAME) -no-snapshot-load -gpu $(GPU_MODE) &>/dev/null & \
		echo "Waiting for emulator to boot..."; \
		$(ADB) -s $(EMULATOR_SERIAL) wait-for-device; \
		while [ "$$($(ADB) -s $(EMULATOR_SERIAL) shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" != "1" ]; do \
			sleep 2; \
		done; \
		echo "Emulator booted."; \
	fi

install: build ## Install APK and launch app on emulator
	@echo "==> Installing APK on emulator..."
	$(ADB) -s $(EMULATOR_SERIAL) install -r $(APK)
	@echo "==> Launching app..."
	$(ADB) -s $(EMULATOR_SERIAL) shell am start -n $(PACKAGE)/$(ACTIVITY)
	@echo "App launched."

redirect: ## Set up UDP port redirect on emulator
	@echo "==> Setting up UDP redirect (host:$(UDP_PORT) -> guest:$(UDP_PORT))..."
	@AUTH_TOKEN=$$(cat ~/.emulator_console_auth_token 2>/dev/null); \
	(printf "auth %s\r\n" "$$AUTH_TOKEN"; sleep 0.3; printf "redir add udp:%s:%s\r\n" "$(UDP_PORT)" "$(UDP_PORT)"; sleep 0.3; printf "quit\r\n") \
		| nc localhost 5554 >/dev/null 2>&1 || true
	@echo "UDP redirect active."

stream: redirect ## Start ffmpeg MPEGTS test stream to emulator
	@echo "==> Starting ffmpeg test stream on udp://127.0.0.1:$(UDP_PORT)..."
	@echo "    Press Ctrl+C to stop."
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

run: emulator install stream ## Full emulator pipeline: boot, build, install, stream

stop: ## Stop emulator and ffmpeg
	@echo "==> Stopping ffmpeg..."
	-pkill -f "ffmpeg.*udp://" 2>/dev/null || true
	@echo "==> Stopping emulator..."
	-$(ADB) -s $(EMULATOR_SERIAL) emu kill 2>/dev/null || true
	@echo "Stopped."

logs: ## Tail logcat for player events (emulator)
	$(ADB) -s $(EMULATOR_SERIAL) logcat -s MulticastPlayer ExoPlayerImpl

screenshot: ## Take a screenshot of the emulator
	@$(ADB) -s $(EMULATOR_SERIAL) exec-out screencap -p > screenshot.png
	@echo "Screenshot saved to screenshot.png"

clean: ## Clean build artifacts
	$(GRADLEW) clean
	@echo "Clean complete."

# =====================================================================
# STB targets (pass STB_IP=<ip> on the command line)
# =====================================================================

stb-check-ip:
	@if [ -z "$(STB_IP)" ]; then \
		echo "ERROR: STB_IP is required. Usage: make <target> STB_IP=192.168.1.100"; \
		exit 1; \
	fi

stb-setup: stb-check-ip check-env ## Interactive STB setup: enable ADB, connect, verify
	./run.sh stb-setup -t $(STB_IP) -p $(STB_ADB_PORT)

stb-connect: stb-check-ip check-env ## Connect ADB to STB
	@echo "==> Connecting to STB at $(STB_TARGET)..."
	$(ADB) connect $(STB_TARGET)
	@sleep 1
	@$(ADB) -s $(STB_TARGET) shell echo "connected" 2>/dev/null && \
		echo "Connected to $$($(ADB) -s $(STB_TARGET) shell getprop ro.product.model 2>/dev/null | tr -d '\r')" || \
		echo "Connection pending — check TV for authorization dialog."

stb-disconnect: stb-check-ip ## Disconnect ADB from STB
	$(ADB) disconnect $(STB_TARGET)

stb-info: stb-check-ip check-env ## Show STB device information
	./run.sh stb-info -t $(STB_IP) -p $(STB_ADB_PORT)

stb-install: stb-check-ip build ## Build APK and install on STB
	@echo "==> Connecting to STB at $(STB_TARGET)..."
	@$(ADB) connect $(STB_TARGET) >/dev/null 2>&1 || true
	@sleep 1
	@echo "==> Installing APK on STB..."
	$(ADB) -s $(STB_TARGET) install -r $(APK)
	@echo "==> Launching app..."
	@if [ -n "$(MULTICAST_GROUP)" ]; then \
		$(ADB) -s $(STB_TARGET) shell am start -n $(PACKAGE)/$(ACTIVITY) \
			--es STREAM_URI "udp://$(MULTICAST_GROUP):$(UDP_PORT)"; \
	else \
		$(ADB) -s $(STB_TARGET) shell am start -n $(PACKAGE)/$(ACTIVITY); \
	fi
	@echo "App launched on STB."

stb-stream: stb-check-ip ## Stream test pattern to STB (unicast or multicast)
	@echo "==> Streaming to STB at $(STB_IP):$(UDP_PORT)..."
	@echo "    Press Ctrl+C to stop."
	@sed "s/1280x720/$(STREAM_RESOLUTION)/g" ffmpeg_filter.txt > /tmp/multicast_filter.txt
	@if [ -n "$(MULTICAST_GROUP)" ]; then \
		echo "    Mode: multicast $(MULTICAST_GROUP):$(UDP_PORT)"; \
		UDP_DEST="udp://$(MULTICAST_GROUP):$(UDP_PORT)?pkt_size=1316&ttl=2"; \
	else \
		echo "    Mode: unicast $(STB_IP):$(UDP_PORT)"; \
		UDP_DEST="udp://$(STB_IP):$(UDP_PORT)?pkt_size=1316"; \
	fi; \
	ffmpeg -re \
		-f lavfi -i "testsrc2=size=$(STREAM_RESOLUTION):rate=$(STREAM_FRAMERATE)" \
		-f lavfi -i "sine=frequency=440:sample_rate=48000" \
		-filter_complex_script /tmp/multicast_filter.txt \
		-map "[vout]" -map 1:a \
		-c:v libx264 -preset ultrafast -tune zerolatency \
		-profile:v high -level 4.1 \
		-b:v $(STREAM_BITRATE) -maxrate $(STREAM_BITRATE) -bufsize 1M \
		-g $(STREAM_GOP) -keyint_min $(STREAM_GOP) \
		-flags +cgop \
		-c:a aac -b:a 128k -ac 2 \
		-mpegts_flags +resend_headers \
		-muxrate 4M \
		-f mpegts "$$UDP_DEST"

stb-run: stb-connect stb-install stb-stream ## Full STB pipeline: connect, build, install, stream

stb-stop: stb-check-ip ## Stop streaming and app on STB
	@echo "==> Stopping ffmpeg..."
	-pkill -f "ffmpeg.*udp://" 2>/dev/null || true
	@echo "==> Stopping app on STB..."
	-$(ADB) -s $(STB_TARGET) shell am force-stop $(PACKAGE) 2>/dev/null || true
	@echo "Stopped."

stb-logs: stb-check-ip ## Tail logcat from STB
	@$(ADB) connect $(STB_TARGET) >/dev/null 2>&1 || true
	$(ADB) -s $(STB_TARGET) logcat -s MulticastPlayer ExoPlayerImpl

stb-screenshot: stb-check-ip ## Capture screenshot from STB
	@$(ADB) connect $(STB_TARGET) >/dev/null 2>&1 || true
	@$(ADB) -s $(STB_TARGET) exec-out screencap -p > screenshot_stb.png
	@echo "Screenshot saved to screenshot_stb.png"
