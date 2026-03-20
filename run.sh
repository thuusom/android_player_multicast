#!/usr/bin/env bash
#
# run.sh - Build, deploy, and stream to the Android TV Multicast Player
#
# Cross-platform: macOS (Intel/Apple Silicon) and Linux (x86_64/arm64)
# Targets: Android TV emulator OR real Google TV / STB hardware
#
# Usage:
#   ./run.sh                                          Emulator + test pattern
#   ./run.sh -f streams/sample_1280x720_surfing_with_audio.ts   Emulator + file
#   ./run.sh -t 192.168.1.100                         STB + test pattern
#   ./run.sh -t 192.168.1.100 -f streams/sample_1280x720_surfing_with_audio.ts
#   ./run.sh stb-setup -t 192.168.1.100               Enable ADB + connect to STB
#   ./run.sh setup                                    Install all prerequisites
#
set -euo pipefail

# --- Platform detection ---
detect_platform() {
    OS="$(uname -s)"
    ARCH="$(uname -m)"

    case "$OS" in
        Darwin) PLATFORM="macos" ;;
        Linux)  PLATFORM="linux" ;;
        MINGW*|MSYS*|CYGWIN*)
            error "Windows is not directly supported. Use WSL2 (Windows Subsystem for Linux) instead."
            ;;
        *)      error "Unsupported OS: $OS" ;;
    esac

    case "$ARCH" in
        x86_64|amd64)  EMU_ABI="x86_64" ;;
        arm64|aarch64) EMU_ABI="arm64-v8a" ;;
        *)             error "Unsupported architecture: $ARCH" ;;
    esac
}

detect_android_home() {
    if [[ -n "${ANDROID_HOME:-}" ]]; then return; fi
    case "$PLATFORM" in
        macos) ANDROID_HOME="$HOME/Library/Android/sdk" ;;
        linux) ANDROID_HOME="$HOME/Android/Sdk" ;;
    esac
}

detect_java_home() {
    if [[ -n "${JAVA_HOME:-}" && -x "${JAVA_HOME}/bin/java" ]]; then return; fi
    case "$PLATFORM" in
        macos)
            if command -v brew >/dev/null 2>&1; then
                local brew_prefix
                brew_prefix="$(brew --prefix openjdk@17 2>/dev/null || true)"
                if [[ -n "$brew_prefix" && -d "$brew_prefix" ]]; then
                    JAVA_HOME="$brew_prefix/libexec/openjdk.jdk/Contents/Home"
                    return
                fi
            fi
            if /usr/libexec/java_home -v 17 >/dev/null 2>&1; then
                JAVA_HOME="$(/usr/libexec/java_home -v 17)"
                return
            fi
            ;;
        linux)
            for jdir in \
                /usr/lib/jvm/java-17-openjdk-amd64 \
                /usr/lib/jvm/java-17-openjdk-arm64 \
                /usr/lib/jvm/java-17-openjdk \
                /usr/lib/jvm/java-17 \
                /usr/lib/jvm/temurin-17-jdk-* \
                /usr/lib/jvm/adoptopenjdk-17-*; do
                if [[ -x "$jdir/bin/java" ]]; then
                    JAVA_HOME="$jdir"
                    return
                fi
            done
            ;;
    esac
    JAVA_HOME=""
}

# --- Configuration ---
detect_platform
detect_android_home
detect_java_home
export ANDROID_HOME JAVA_HOME

AVD_NAME="TV_API_34"
PACKAGE="com.cryptoguard.multicastplayer"
ACTIVITY=".MainActivity"
APK="app/build/outputs/apk/debug/app-debug.apk"
EMULATOR_SERIAL="emulator-5554"
UDP_PORT=5000

# Stream settings
STREAM_RESOLUTION="1280x720"
STREAM_FRAMERATE=25
STREAM_BITRATE="3M"
STREAM_GOP=50

ADB="$ANDROID_HOME/platform-tools/adb"
EMULATOR_BIN="$ANDROID_HOME/emulator/emulator"
SDKMANAGER="$ANDROID_HOME/cmdline-tools/latest/bin/sdkmanager"
AVDMANAGER="$ANDROID_HOME/cmdline-tools/latest/bin/avdmanager"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SYSTEM_IMAGE="system-images;android-34;android-tv;${EMU_ABI}"

if [[ "$PLATFORM" == "linux" && -z "${DISPLAY:-}" && -z "${WAYLAND_DISPLAY:-}" ]]; then
    GPU_MODE="swiftshader_indirect"
else
    GPU_MODE="auto"
fi

# --- Target mode: "emulator" or "stb" ---
TARGET_MODE="emulator"
STB_IP=""
STB_ADB_PORT=5555
MULTICAST_GROUP=""

# Resolved ADB target (set after parsing args)
ADB_TARGET=""

# --- Helpers ---
info()  { echo -e "\033[36m==>\033[0m $*"; }
warn()  { echo -e "\033[33mWARN:\033[0m $*"; }
error() { echo -e "\033[31mERROR:\033[0m $*" >&2; exit 1; }

resolve_adb_target() {
    if [[ "$TARGET_MODE" == "stb" ]]; then
        ADB_TARGET="${STB_IP}:${STB_ADB_PORT}"
    else
        ADB_TARGET="$EMULATOR_SERIAL"
    fi
}

adb_cmd() {
    "$ADB" -s "$ADB_TARGET" "$@"
}

check_env() {
    [[ -x "$JAVA_HOME/bin/java" ]]     || error "JDK 17 not found. Run: ./run.sh setup"
    [[ -x "$ADB" ]]                    || error "Android SDK not found at $ANDROID_HOME"
    command -v ffmpeg >/dev/null 2>&1   || error "ffmpeg not found. Install with your package manager"
    if [[ "$TARGET_MODE" == "emulator" ]]; then
        [[ -x "$EMULATOR_BIN" ]]       || error "Android emulator not found"
    fi
}

# --- Argument parsing ---
parse_extra_args() {
    STREAM_FILE=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -f|--file)
                [[ $# -lt 2 ]] && error "Missing filename after $1"
                STREAM_FILE="$2"
                shift 2
                ;;
            -t|--target)
                [[ $# -lt 2 ]] && error "Missing IP address after $1"
                STB_IP="$2"
                TARGET_MODE="stb"
                shift 2
                ;;
            -p|--port)
                [[ $# -lt 2 ]] && error "Missing port after $1"
                STB_ADB_PORT="$2"
                shift 2
                ;;
            --udp-port)
                [[ $# -lt 2 ]] && error "Missing UDP port after $1"
                UDP_PORT="$2"
                shift 2
                ;;
            --multicast)
                [[ $# -lt 2 ]] && error "Missing multicast group after $1"
                MULTICAST_GROUP="$2"
                shift 2
                ;;
            *)
                error "Unknown option: $1"
                ;;
        esac
    done
    # Resolve relative paths
    if [[ -n "$STREAM_FILE" && "$STREAM_FILE" != /* ]]; then
        STREAM_FILE="$SCRIPT_DIR/$STREAM_FILE"
    fi
    if [[ -n "$STREAM_FILE" && ! -f "$STREAM_FILE" ]]; then
        error "Stream file not found: $STREAM_FILE"
    fi
    resolve_adb_target
}

# --- Package manager helpers ---
pkg_install() {
    case "$PLATFORM" in
        macos)
            command -v brew >/dev/null 2>&1 || error "Homebrew not found. Install from https://brew.sh"
            brew install "$@" || true
            ;;
        linux)
            if command -v apt-get >/dev/null 2>&1; then
                sudo apt-get update && sudo apt-get install -y "$@"
            elif command -v dnf >/dev/null 2>&1; then
                sudo dnf install -y "$@"
            elif command -v pacman >/dev/null 2>&1; then
                sudo pacman -Sy --noconfirm "$@"
            else
                error "No supported package manager found (apt, dnf, pacman)"
            fi
            ;;
    esac
}

# =====================================================================
# STB-specific commands
# =====================================================================

do_stb_setup() {
    [[ -z "$STB_IP" ]] && error "STB IP required. Use: ./run.sh stb-setup -t <STB_IP>"
    check_env

    echo ""
    info "========================================================"
    info "  Google TV / STB Setup Guide"
    info "========================================================"
    echo ""
    info "Target STB: $STB_IP (ADB port: $STB_ADB_PORT)"
    echo ""
    info "STEP 1: Enable Developer Options on your Google TV"
    info "  1. Go to Settings → System → About"
    info "  2. Scroll down to 'Android TV OS build'"
    info "  3. Click it 7 times until you see 'You are now a developer!'"
    echo ""
    info "STEP 2: Enable ADB Debugging"
    info "  1. Go to Settings → System → Developer options"
    info "  2. Turn ON 'USB debugging' (also called 'ADB debugging')"
    info "  3. If available, also turn ON 'ADB over network' / 'Wireless debugging'"
    echo ""
    info "STEP 3: Press ENTER when the above steps are done..."
    read -r

    info "Connecting to STB at ${STB_IP}:${STB_ADB_PORT}..."
    "$ADB" connect "${STB_IP}:${STB_ADB_PORT}"

    # Wait for the authorization prompt
    echo ""
    info "STEP 4: Check your TV screen!"
    info "  A dialog should appear: 'Allow USB debugging?'"
    info "  ✓ Check 'Always allow from this computer'"
    info "  ✓ Click 'Allow'"
    echo ""
    info "Waiting for authorization (press ENTER after you click Allow on TV)..."
    read -r

    # Verify connection
    info "Verifying connection..."
    if adb_cmd shell echo "connected" 2>/dev/null | grep -q "connected"; then
        info "✓ Successfully connected to STB!"
        echo ""
        info "Device info:"
        info "  Model:    $(adb_cmd shell getprop ro.product.model 2>/dev/null | tr -d '\r')"
        info "  Brand:    $(adb_cmd shell getprop ro.product.brand 2>/dev/null | tr -d '\r')"
        info "  Android:  $(adb_cmd shell getprop ro.build.version.release 2>/dev/null | tr -d '\r')"
        info "  SDK:      $(adb_cmd shell getprop ro.build.version.sdk 2>/dev/null | tr -d '\r')"
        info "  Arch:     $(adb_cmd shell getprop ro.product.cpu.abi 2>/dev/null | tr -d '\r')"
        info "  Serial:   $ADB_TARGET"
        echo ""
        info "STB IP address on network:"
        adb_cmd shell ip -4 addr show wlan0 2>/dev/null | awk '/inet /{split($2,a,"/"); print "    " a[1]}' || \
        adb_cmd shell ip -4 addr show eth0 2>/dev/null | awk '/inet /{split($2,a,"/"); print "    " a[1]}' || \
        adb_cmd shell ifconfig wlan0 2>/dev/null | awk '/inet /{print "    " $2}' || \
        info "  (could not detect — verify $STB_IP is correct)"
        echo ""
        info "You can now deploy the app:"
        info "  ./run.sh -t $STB_IP install"
        info "  ./run.sh -t $STB_IP -f streams/sample_1280x720_surfing_with_audio.ts"
    else
        error "Could not connect to STB. Check the IP address and that ADB debugging is enabled."
    fi
}

do_stb_connect() {
    [[ -z "$STB_IP" ]] && error "STB IP required. Use: ./run.sh stb-connect -t <STB_IP>"

    info "Connecting to STB at ${STB_IP}:${STB_ADB_PORT}..."
    "$ADB" connect "${STB_IP}:${STB_ADB_PORT}"

    sleep 1
    if adb_cmd shell echo "ok" 2>/dev/null | grep -q "ok"; then
        info "✓ Connected to $(adb_cmd shell getprop ro.product.model 2>/dev/null | tr -d '\r')"
    else
        warn "Connection may be pending authorization. Check your TV for the 'Allow USB debugging?' dialog."
    fi
}

do_stb_disconnect() {
    [[ -z "$STB_IP" ]] && error "STB IP required."
    info "Disconnecting from STB..."
    "$ADB" disconnect "${STB_IP}:${STB_ADB_PORT}" 2>/dev/null || true
    info "Disconnected."
}

do_stb_info() {
    [[ -z "$STB_IP" ]] && error "STB IP required. Use: ./run.sh stb-info -t <STB_IP>"
    check_env

    # Ensure connected
    "$ADB" connect "${STB_IP}:${STB_ADB_PORT}" >/dev/null 2>&1 || true
    sleep 0.5

    info "========================================================"
    info "  STB Device Information"
    info "========================================================"
    info "  ADB target:      $ADB_TARGET"
    info "  Model:            $(adb_cmd shell getprop ro.product.model 2>/dev/null | tr -d '\r')"
    info "  Device:           $(adb_cmd shell getprop ro.product.device 2>/dev/null | tr -d '\r')"
    info "  Brand:            $(adb_cmd shell getprop ro.product.brand 2>/dev/null | tr -d '\r')"
    info "  Manufacturer:     $(adb_cmd shell getprop ro.product.manufacturer 2>/dev/null | tr -d '\r')"
    info "  Android version:  $(adb_cmd shell getprop ro.build.version.release 2>/dev/null | tr -d '\r')"
    info "  SDK level:        $(adb_cmd shell getprop ro.build.version.sdk 2>/dev/null | tr -d '\r')"
    info "  CPU ABI:          $(adb_cmd shell getprop ro.product.cpu.abi 2>/dev/null | tr -d '\r')"
    info "  CPU ABIs:         $(adb_cmd shell getprop ro.product.cpu.abilist 2>/dev/null | tr -d '\r')"
    info "  Build:            $(adb_cmd shell getprop ro.build.display.id 2>/dev/null | tr -d '\r')"
    info "  Google TV:        $(adb_cmd shell getprop ro.com.google.gmsversion 2>/dev/null | tr -d '\r')"
    echo ""
    info "  Network interfaces:"
    adb_cmd shell ip -4 addr show 2>/dev/null | grep -E '(^\d|inet )' | sed 's/^/    /' || true
    echo ""
    info "  Display info:"
    adb_cmd shell wm size 2>/dev/null | sed 's/^/    /'
    adb_cmd shell wm density 2>/dev/null | sed 's/^/    /'
    echo ""
    info "  Available decoders (video):"
    adb_cmd shell "dumpsys media.player 2>/dev/null | grep -i 'video.*decoder' | head -10" | sed 's/^/    /' || \
    adb_cmd shell "pm list features 2>/dev/null | grep -i 'hardware.type.television'" | sed 's/^/    /' || true
}

# =====================================================================
# Generic commands (work for both emulator and STB)
# =====================================================================

do_setup() {
    info "Platform: $PLATFORM ($ARCH)"
    info "Emulator ABI: $EMU_ABI"
    info "System image: $SYSTEM_IMAGE"
    echo ""

    info "Installing JDK 17..."
    case "$PLATFORM" in
        macos)
            command -v brew >/dev/null 2>&1 || error "Homebrew not found. Install from https://brew.sh"
            brew install openjdk@17 || true
            ;;
        linux)
            if command -v apt-get >/dev/null 2>&1; then
                sudo apt-get update && sudo apt-get install -y openjdk-17-jdk-headless
            elif command -v dnf >/dev/null 2>&1; then
                sudo dnf install -y java-17-openjdk-devel
            elif command -v pacman >/dev/null 2>&1; then
                sudo pacman -Sy --noconfirm jdk17-openjdk
            else
                error "Install JDK 17 manually and set JAVA_HOME"
            fi
            ;;
    esac
    detect_java_home
    export JAVA_HOME
    info "JAVA_HOME=$JAVA_HOME"

    if ! command -v ffmpeg >/dev/null 2>&1; then
        info "Installing ffmpeg..."
        case "$PLATFORM" in
            macos) brew install ffmpeg ;;
            linux) pkg_install ffmpeg ;;
        esac
    fi

    info "Installing Android cmdline-tools..."
    if [[ ! -x "$SDKMANAGER" ]]; then
        case "$PLATFORM" in
            macos)
                brew install --cask android-commandlinetools || true
                sdkmanager --sdk_root="$ANDROID_HOME" --install "cmdline-tools;latest"
                ;;
            linux)
                mkdir -p "$ANDROID_HOME"
                local cmdtools_zip="/tmp/commandlinetools.zip"
                local cmdtools_url="https://dl.google.com/android/repository/commandlinetools-linux-11076708_latest.zip"
                info "Downloading Android cmdline-tools..."
                curl -fSL -o "$cmdtools_zip" "$cmdtools_url"
                unzip -qo "$cmdtools_zip" -d "$ANDROID_HOME/cmdline-tools-tmp"
                mkdir -p "$ANDROID_HOME/cmdline-tools"
                mv "$ANDROID_HOME/cmdline-tools-tmp/cmdline-tools" "$ANDROID_HOME/cmdline-tools/latest"
                rm -rf "$ANDROID_HOME/cmdline-tools-tmp" "$cmdtools_zip"
                ;;
        esac
    fi
    SDKMANAGER="$ANDROID_HOME/cmdline-tools/latest/bin/sdkmanager"
    AVDMANAGER="$ANDROID_HOME/cmdline-tools/latest/bin/avdmanager"

    if [[ "$PLATFORM" == "linux" && "$EMU_ABI" == "x86_64" ]]; then
        if [[ ! -w /dev/kvm ]]; then
            warn "/dev/kvm is not writable. The emulator will be very slow without KVM."
            warn "Fix with: sudo apt install qemu-kvm && sudo adduser \$USER kvm"
        fi
    fi

    info "Installing Android TV system image ($SYSTEM_IMAGE)..."
    yes | "$SDKMANAGER" --sdk_root="$ANDROID_HOME" \
        "$SYSTEM_IMAGE" \
        "platforms;android-34" \
        "platform-tools" \
        "emulator" \
        "build-tools;36.0.0"

    info "Creating Android TV AVD..."
    AVDMANAGER="$ANDROID_HOME/cmdline-tools/latest/bin/avdmanager"
    if ! "$AVDMANAGER" list avd 2>/dev/null | grep -q "$AVD_NAME"; then
        echo "no" | "$AVDMANAGER" create avd \
            -n "$AVD_NAME" \
            -k "$SYSTEM_IMAGE" \
            -d "tv_1080p"
    else
        info "AVD '$AVD_NAME' already exists."
    fi

    echo "sdk.dir=$ANDROID_HOME" > local.properties
    echo ""
    info "Setup complete!"
    info "  Platform:     $PLATFORM ($ARCH)"
    info "  JAVA_HOME:    $JAVA_HOME"
    info "  ANDROID_HOME: $ANDROID_HOME"
    info "  System image: $SYSTEM_IMAGE"
    info "  AVD:          $AVD_NAME"
}

do_build() {
    check_env
    info "Building APK..."
    ./gradlew assembleDebug
    info "APK built: $APK"
}

do_emulator() {
    check_env
    if "$ADB" devices 2>/dev/null | grep -q "$EMULATOR_SERIAL"; then
        info "Emulator already running."
        return
    fi

    info "Launching Android TV emulator (gpu=$GPU_MODE)..."
    "$EMULATOR_BIN" -avd "$AVD_NAME" -no-snapshot-load -gpu "$GPU_MODE" &>/dev/null &

    info "Waiting for emulator to boot..."
    "$ADB" -s "$EMULATOR_SERIAL" wait-for-device
    while [[ "$("$ADB" -s "$EMULATOR_SERIAL" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" != "1" ]]; do
        sleep 2
    done
    info "Emulator booted."
}

do_install() {
    check_env
    do_build

    if [[ "$TARGET_MODE" == "stb" ]]; then
        # Ensure ADB connection to STB
        info "Connecting to STB at ${STB_IP}:${STB_ADB_PORT}..."
        "$ADB" connect "${STB_IP}:${STB_ADB_PORT}" >/dev/null 2>&1 || true
        sleep 1
    fi

    info "Installing APK on $ADB_TARGET..."
    adb_cmd install -r "$APK"

    # Determine stream URI for the app
    local stream_uri="udp://0.0.0.0:${UDP_PORT}"
    if [[ -n "$MULTICAST_GROUP" ]]; then
        stream_uri="udp://${MULTICAST_GROUP}:${UDP_PORT}"
    fi

    info "Launching app (stream URI: $stream_uri)..."
    adb_cmd shell am start -n "$PACKAGE/$ACTIVITY" --es STREAM_URI "$stream_uri"
    info "App launched on $ADB_TARGET."
}

do_redirect() {
    # Only needed for emulator — STB receives packets directly on the network
    if [[ "$TARGET_MODE" == "stb" ]]; then
        return
    fi

    info "Setting up UDP redirect (host:$UDP_PORT -> guest:$UDP_PORT)..."
    local auth_token
    auth_token=$(cat ~/.emulator_console_auth_token 2>/dev/null || echo "")

    {
        printf "auth %s\r\n" "$auth_token"
        sleep 0.3
        printf "redir add udp:%s:%s\r\n" "$UDP_PORT" "$UDP_PORT"
        sleep 0.3
        printf "quit\r\n"
    } | nc localhost 5554 >/dev/null 2>&1 || true

    info "UDP redirect active."
}

resolve_udp_dest() {
    # Returns the UDP destination — only echoes the URL, no info messages
    if [[ "$TARGET_MODE" == "stb" ]]; then
        if [[ -n "$MULTICAST_GROUP" ]]; then
            echo "udp://${MULTICAST_GROUP}:${UDP_PORT}?pkt_size=1316&ttl=2"
        else
            echo "udp://${STB_IP}:${UDP_PORT}?pkt_size=1316"
        fi
    else
        echo "udp://127.0.0.1:${UDP_PORT}?pkt_size=1316&buffer_size=65536"
    fi
}

log_stream_dest() {
    # Log the destination info (to stderr, so it doesn't interfere with capture)
    if [[ "$TARGET_MODE" == "stb" ]]; then
        if [[ -n "$MULTICAST_GROUP" ]]; then
            info "Streaming to multicast group ${MULTICAST_GROUP}:${UDP_PORT}"
        else
            info "Streaming unicast to ${STB_IP}:${UDP_PORT}"
        fi
    else
        info "Streaming to emulator via udp://127.0.0.1:${UDP_PORT}"
    fi
}

do_stream_test_pattern() {
    local udp_dest
    udp_dest="$(resolve_udp_dest)"
    log_stream_dest

    info "  Video: ${STREAM_RESOLUTION}@${STREAM_FRAMERATE}fps H.264 ${STREAM_BITRATE}"
    info "  Audio: AAC 48kHz stereo 128kbps (sine tone)"
    info "  Overlay: live clock, frame counter, PTS"
    info "Press Ctrl+C to stop."
    echo ""

    cp "$SCRIPT_DIR/ffmpeg_filter.txt" /tmp/multicast_filter.txt

    ffmpeg -re \
        -f lavfi -i "testsrc2=size=${STREAM_RESOLUTION}:rate=${STREAM_FRAMERATE}" \
        -f lavfi -i "sine=frequency=440:sample_rate=48000" \
        -filter_complex_script /tmp/multicast_filter.txt \
        -map "[vout]" -map 1:a \
        -c:v libx264 -preset ultrafast -tune zerolatency \
        -b:v "$STREAM_BITRATE" -maxrate "$STREAM_BITRATE" -bufsize 1M \
        -g "$STREAM_GOP" -keyint_min "$STREAM_GOP" \
        -flags +cgop \
        -c:a aac -b:a 128k -ac 2 \
        -mpegts_flags +resend_headers \
        -muxrate 4M \
        -f mpegts "$udp_dest"
}

do_stream_file() {
    local file="$1"
    local filename
    filename="$(basename "$file")"

    local udp_dest
    udp_dest="$(resolve_udp_dest)"
    log_stream_dest

    info "Probing file: $filename"
    local probe
    probe=$(ffprobe -v quiet -show_streams -show_format -print_format json "$file")

    local video_codec audio_codec video_res video_fps duration has_audio
    video_codec=$(echo "$probe" | python3 -c "import sys,json; streams=json.load(sys.stdin)['streams']; vs=[s for s in streams if s['codec_type']=='video']; print(vs[0]['codec_name'] if vs else 'none')" 2>/dev/null || echo "unknown")
    video_res=$(echo "$probe" | python3 -c "import sys,json; streams=json.load(sys.stdin)['streams']; vs=[s for s in streams if s['codec_type']=='video']; print(f\"{vs[0]['width']}x{vs[0]['height']}\" if vs else 'unknown')" 2>/dev/null || echo "unknown")
    video_fps=$(echo "$probe" | python3 -c "import sys,json; streams=json.load(sys.stdin)['streams']; vs=[s for s in streams if s['codec_type']=='video']; r=vs[0].get('r_frame_rate','0/1') if vs else '0/1'; n,d=map(int,r.split('/')); print(f'{n/d:.2f}' if d else '0')" 2>/dev/null || echo "unknown")
    audio_codec=$(echo "$probe" | python3 -c "import sys,json; streams=json.load(sys.stdin)['streams']; als=[s for s in streams if s['codec_type']=='audio']; print(als[0]['codec_name'] if als else 'none')" 2>/dev/null || echo "none")
    duration=$(echo "$probe" | python3 -c "import sys,json; d=json.load(sys.stdin)['format'].get('duration','?'); print(f'{float(d):.1f}s' if d!='?' else '?')" 2>/dev/null || echo "unknown")
    has_audio=$([[ "$audio_codec" != "none" ]] && echo "yes" || echo "no")

    info "File: $filename"
    info "  Duration: $duration (will loop continuously)"
    info "  Video: $video_codec $video_res @ ${video_fps}fps"
    info "  Audio: $audio_codec (has_audio=$has_audio)"
    info ""

    # For STB with hardware decoder, we can use higher profile/resolution
    local profile_args scale_filter=""
    if [[ "$TARGET_MODE" == "stb" ]]; then
        # STB has hardware H.264 decoder — use high profile, higher bitrate
        profile_args=(-profile:v high -level 4.1)
        local bitrate="5M"
        # Only scale if extremely large (>3840)
        local width
        width=$(echo "$video_res" | cut -dx -f1)
        if [[ "$width" -gt 3840 ]]; then
            warn "Resolution ${video_res} is > 4K. Scaling down to 1920x1080."
            scale_filter="-vf scale=1920:1080:force_original_aspect_ratio=decrease,pad=1920:1080:(ow-iw)/2:(oh-ih)/2"
        fi
    else
        # Emulator — baseline profile, lower bitrate, scale > 1920
        profile_args=(-profile:v baseline -level 3.1)
        local bitrate="2M"
        local width
        width=$(echo "$video_res" | cut -dx -f1)
        if [[ "$width" -gt 1920 ]]; then
            warn "Resolution ${video_res} is > 1920px wide. Scaling down to 1280x720 for emulator."
            scale_filter="-vf scale=1280:720:force_original_aspect_ratio=decrease,pad=1280:720:(ow-iw)/2:(oh-ih)/2"
        fi
    fi

    local ffmpeg_cmd=(
        ffmpeg -re
        -stream_loop -1
        -i "$file"
    )

    if [[ "$has_audio" == "no" ]]; then
        info "No audio track found - generating silent audio"
        ffmpeg_cmd+=( -f lavfi -i "anullsrc=r=48000:cl=stereo" )
    fi

    ffmpeg_cmd+=(
        -c:v libx264 -preset ultrafast -tune zerolatency
        "${profile_args[@]}"
        -b:v "$bitrate" -maxrate "$bitrate" -bufsize 1M
        -g 24 -keyint_min 24
        -flags +cgop
    )

    if [[ -n "$scale_filter" ]]; then
        ffmpeg_cmd+=( $scale_filter )
    fi

    if [[ "$has_audio" == "no" ]]; then
        ffmpeg_cmd+=( -map 0:v:0 -map 1:a:0 )
    fi
    ffmpeg_cmd+=(
        -c:a aac -b:a 128k -ac 2 -ar 48000
    )

    ffmpeg_cmd+=(
        -mpegts_flags +resend_headers
        -muxrate $(( ${bitrate%M} + 1 ))M
        -f mpegts "$udp_dest"
    )

    info "Press Ctrl+C to stop."
    echo ""
    "${ffmpeg_cmd[@]}"
}

do_stream() {
    do_redirect

    if [[ -n "${STREAM_FILE:-}" ]]; then
        do_stream_file "$STREAM_FILE"
    else
        do_stream_test_pattern
    fi
}

do_stop() {
    info "Stopping ffmpeg..."
    pkill -f "ffmpeg.*udp://" 2>/dev/null || true
    if [[ "$TARGET_MODE" == "stb" ]]; then
        info "Stopping app on STB..."
        adb_cmd shell am force-stop "$PACKAGE" 2>/dev/null || true
    else
        info "Stopping emulator..."
        "$ADB" -s "$EMULATOR_SERIAL" emu kill 2>/dev/null || true
    fi
    info "Stopped."
}

do_logs() {
    check_env
    if [[ "$TARGET_MODE" == "stb" ]]; then
        "$ADB" connect "${STB_IP}:${STB_ADB_PORT}" >/dev/null 2>&1 || true
    fi
    adb_cmd logcat -s MulticastPlayer ExoPlayerImpl
}

do_screenshot() {
    check_env
    if [[ "$TARGET_MODE" == "stb" ]]; then
        "$ADB" connect "${STB_IP}:${STB_ADB_PORT}" >/dev/null 2>&1 || true
    fi
    adb_cmd exec-out screencap -p > screenshot.png
    info "Screenshot saved to screenshot.png"
}

do_run() {
    if [[ "$TARGET_MODE" == "stb" ]]; then
        # STB mode: connect + install + stream
        do_stb_connect
        do_install
        do_stream
    else
        # Emulator mode: boot + install + stream
        do_emulator
        do_install
        do_stream
    fi
}

do_info() {
    info "Platform:       $PLATFORM ($ARCH)"
    info "Target mode:    $TARGET_MODE"
    if [[ "$TARGET_MODE" == "stb" ]]; then
        info "STB IP:         $STB_IP"
        info "STB ADB port:   $STB_ADB_PORT"
        info "ADB target:     $ADB_TARGET"
    else
        info "Emulator ABI:   $EMU_ABI"
        info "System image:   $SYSTEM_IMAGE"
        info "GPU mode:       $GPU_MODE"
    fi
    info "UDP port:       $UDP_PORT"
    info "Multicast:      ${MULTICAST_GROUP:-<none — unicast>}"
    info "JAVA_HOME:      ${JAVA_HOME:-<not set>}"
    info "ANDROID_HOME:   $ANDROID_HOME"
    info "ADB:            $ADB"
    info "ffmpeg:         $(command -v ffmpeg 2>/dev/null || echo '<not found>')"
    info "python3:        $(command -v python3 2>/dev/null || echo '<not found>')"
}

show_usage() {
    cat <<USAGE
Usage: ./run.sh [command] [options]

Commands (emulator):
  run              Full pipeline: emulator + build + install + stream (default)
  setup            Install all prerequisites (JDK, SDK, AVD)
  build            Build the APK only
  emulator         Launch the Android TV emulator
  install          Build, install, and launch the app
  stream           Start streaming only (test pattern or file)
  stop             Stop emulator and ffmpeg
  logs             Tail logcat for player events
  screenshot       Capture screenshot
  info             Show detected platform and tool paths

Commands (STB — requires -t <IP>):
  stb-setup        Interactive setup: enable ADB, connect, verify STB
  stb-connect      Connect ADB to STB
  stb-disconnect   Disconnect ADB from STB
  stb-info         Show STB device info (model, Android version, etc.)
  install          Build and install APK on STB
  stream           Stream to STB (unicast or multicast)
  run              Connect + install + stream (full STB pipeline)
  stop             Stop streaming + stop app on STB
  logs             Tail logcat from STB
  screenshot       Capture STB screenshot

Options:
  -t, --target IP      Target STB IP address (switches to STB mode)
  -p, --port PORT      ADB port on STB (default: 5555)
  --udp-port PORT      UDP streaming port (default: 5000)
  --multicast GROUP    Use multicast group (e.g., 239.1.1.1) instead of unicast
  -f, --file FILE      Stream a .ts file instead of the test pattern

Platform: $PLATFORM ($ARCH)

Examples (emulator):
  ./run.sh                                                    # Test pattern
  ./run.sh -f streams/sample_1280x720_surfing_with_audio.ts   # File stream
  ./run.sh info                                               # Platform info

Examples (STB):
  ./run.sh stb-setup -t 192.168.1.100                         # First-time STB setup
  ./run.sh -t 192.168.1.100                                   # Full pipeline to STB
  ./run.sh -t 192.168.1.100 -f streams/sample_1280x720_surfing_with_audio.ts
  ./run.sh -t 192.168.1.100 --multicast 239.1.1.1             # Multicast mode
  ./run.sh stb-info -t 192.168.1.100                          # Device info
  ./run.sh logs -t 192.168.1.100                              # Watch player logs
  ./run.sh stop -t 192.168.1.100                              # Stop app on STB
USAGE
}

# --- Main ---

COMMAND=""
EXTRA_ARGS=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        setup|build|emulator|install|stream|run|stop|logs|screenshot|info|stb-setup|stb-connect|stb-disconnect|stb-info)
            if [[ -z "$COMMAND" ]]; then
                COMMAND="$1"
                shift
            else
                EXTRA_ARGS+=("$1")
                shift
            fi
            ;;
        -f|--file)
            EXTRA_ARGS+=("$1" "$2")
            shift 2
            ;;
        -t|--target)
            EXTRA_ARGS+=("$1" "$2")
            shift 2
            ;;
        -p|--port)
            EXTRA_ARGS+=("$1" "$2")
            shift 2
            ;;
        --udp-port)
            EXTRA_ARGS+=("$1" "$2")
            shift 2
            ;;
        --multicast)
            EXTRA_ARGS+=("$1" "$2")
            shift 2
            ;;
        -h|--help|help)
            show_usage
            exit 0
            ;;
        *)
            EXTRA_ARGS+=("$1")
            shift
            ;;
    esac
done

COMMAND="${COMMAND:-run}"

# Parse all extra args (including -t, -f, --multicast, etc.)
parse_extra_args "${EXTRA_ARGS[@]+"${EXTRA_ARGS[@]}"}"

case "$COMMAND" in
    setup)          do_setup ;;
    build)          do_build ;;
    emulator)       do_emulator ;;
    install)        do_install ;;
    stream)         do_stream ;;
    run)            do_run ;;
    stop)           do_stop ;;
    logs)           do_logs ;;
    screenshot)     do_screenshot ;;
    info)           do_info ;;
    stb-setup)      do_stb_setup ;;
    stb-connect)    do_stb_connect ;;
    stb-disconnect) do_stb_disconnect ;;
    stb-info)       do_stb_info ;;
    *)              show_usage; exit 1 ;;
esac
