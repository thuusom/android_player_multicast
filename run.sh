#!/usr/bin/env bash
#
# run.sh - Build, deploy, and stream to the Android TV Multicast Player
#
# Cross-platform: macOS (Intel/Apple Silicon) and Linux (x86_64/arm64)
#
# Usage:
#   ./run.sh                                          Run with test pattern
#   ./run.sh -f streams/sample_1280x720_surfing_with_audio.ts
#   ./run.sh -f streams/sample_3840x2160.ts           Run with a file stream
#   ./run.sh setup                                    Install all prerequisites
#   ./run.sh build                                    Build the APK only
#   ./run.sh emulator                                 Launch the Android TV emulator
#   ./run.sh install                                  Install and launch the app
#   ./run.sh stream                                   Test pattern stream only
#   ./run.sh stream -f FILE                            Stream a file only
#   ./run.sh stop                                     Stop emulator and ffmpeg
#   ./run.sh logs                                     Tail logcat for player events
#   ./run.sh screenshot                               Capture emulator screenshot
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

# Resolve ANDROID_HOME per platform
detect_android_home() {
    if [[ -n "${ANDROID_HOME:-}" ]]; then
        return
    fi
    case "$PLATFORM" in
        macos) ANDROID_HOME="$HOME/Library/Android/sdk" ;;
        linux) ANDROID_HOME="$HOME/Android/Sdk" ;;
    esac
}

# Resolve JAVA_HOME per platform
detect_java_home() {
    if [[ -n "${JAVA_HOME:-}" && -x "${JAVA_HOME}/bin/java" ]]; then
        return
    fi
    case "$PLATFORM" in
        macos)
            # Try Homebrew first, then /usr/libexec/java_home
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
            # Try common JDK 17 locations
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

# Stream settings (for test pattern mode)
STREAM_RESOLUTION="1280x720"
STREAM_FRAMERATE=25
STREAM_BITRATE="3M"
STREAM_GOP=50

ADB="$ANDROID_HOME/platform-tools/adb"
EMULATOR_BIN="$ANDROID_HOME/emulator/emulator"
SDKMANAGER="$ANDROID_HOME/cmdline-tools/latest/bin/sdkmanager"
AVDMANAGER="$ANDROID_HOME/cmdline-tools/latest/bin/avdmanager"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# System image to use (architecture-dependent)
SYSTEM_IMAGE="system-images;android-34;android-tv;${EMU_ABI}"

# GPU mode: macOS can use 'auto', Linux headless may need swiftshader
if [[ "$PLATFORM" == "linux" && -z "${DISPLAY:-}" && -z "${WAYLAND_DISPLAY:-}" ]]; then
    GPU_MODE="swiftshader_indirect"
else
    GPU_MODE="auto"
fi

# --- Helpers ---
info()  { echo -e "\033[36m==>\033[0m $*"; }
warn()  { echo -e "\033[33mWARN:\033[0m $*"; }
error() { echo -e "\033[31mERROR:\033[0m $*" >&2; exit 1; }

check_env() {
    [[ -x "$JAVA_HOME/bin/java" ]]     || error "JDK 17 not found. Run: ./run.sh setup"
    [[ -x "$ADB" ]]                    || error "Android SDK not found at $ANDROID_HOME"
    [[ -x "$EMULATOR_BIN" ]]           || error "Android emulator not found"
    command -v ffmpeg >/dev/null 2>&1   || error "ffmpeg not found. Install with: ${PLATFORM_PKG_HINT:-your package manager}"
}

# Parse -f FILE from remaining args (after command is consumed)
parse_file_arg() {
    STREAM_FILE=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -f|--file)
                [[ $# -lt 2 ]] && error "Missing filename after $1"
                STREAM_FILE="$2"
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

# --- Commands ---
do_setup() {
    info "Platform: $PLATFORM ($ARCH)"
    info "Emulator ABI: $EMU_ABI"
    info "System image: $SYSTEM_IMAGE"
    echo ""

    # --- JDK 17 ---
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
    # Re-detect after install
    detect_java_home
    export JAVA_HOME
    info "JAVA_HOME=$JAVA_HOME"

    # --- ffmpeg ---
    if ! command -v ffmpeg >/dev/null 2>&1; then
        info "Installing ffmpeg..."
        case "$PLATFORM" in
            macos) brew install ffmpeg ;;
            linux) pkg_install ffmpeg ;;
        esac
    fi

    # --- Android SDK cmdline-tools ---
    info "Installing Android cmdline-tools..."
    if [[ ! -x "$SDKMANAGER" ]]; then
        case "$PLATFORM" in
            macos)
                brew install --cask android-commandlinetools || true
                sdkmanager --sdk_root="$ANDROID_HOME" --install "cmdline-tools;latest"
                ;;
            linux)
                # Download cmdline-tools if not present
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
    # Re-resolve after install
    SDKMANAGER="$ANDROID_HOME/cmdline-tools/latest/bin/sdkmanager"
    AVDMANAGER="$ANDROID_HOME/cmdline-tools/latest/bin/avdmanager"

    # --- KVM check (Linux only) ---
    if [[ "$PLATFORM" == "linux" && "$EMU_ABI" == "x86_64" ]]; then
        if [[ ! -w /dev/kvm ]]; then
            warn "/dev/kvm is not writable. The emulator will be very slow without KVM."
            warn "Fix with: sudo apt install qemu-kvm && sudo adduser \$USER kvm"
        fi
    fi

    # --- Android TV system image ---
    info "Installing Android TV system image ($SYSTEM_IMAGE)..."
    yes | "$SDKMANAGER" --sdk_root="$ANDROID_HOME" \
        "$SYSTEM_IMAGE" \
        "platforms;android-34" \
        "platform-tools" \
        "emulator" \
        "build-tools;36.0.0"

    # --- Create AVD ---
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

    info "Installing APK on emulator..."
    "$ADB" -s "$EMULATOR_SERIAL" install -r "$APK"

    info "Launching app..."
    "$ADB" -s "$EMULATOR_SERIAL" shell am start -n "$PACKAGE/$ACTIVITY"
    info "App launched."
}

do_redirect() {
    info "Setting up UDP redirect (host:$UDP_PORT -> guest:$UDP_PORT)..."
    local auth_token
    auth_token=$(cat ~/.emulator_console_auth_token 2>/dev/null || echo "")

    # Use printf+nc for cross-platform compatibility (BSD nc vs GNU nc)
    {
        printf "auth %s\r\n" "$auth_token"
        sleep 0.3
        printf "redir add udp:%s:%s\r\n" "$UDP_PORT" "$UDP_PORT"
        sleep 0.3
        printf "quit\r\n"
    } | nc localhost 5554 >/dev/null 2>&1 || true

    info "UDP redirect active."
}

do_stream_test_pattern() {
    info "Starting ffmpeg test pattern stream on udp://127.0.0.1:$UDP_PORT"
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
        -f mpegts "udp://127.0.0.1:${UDP_PORT}?pkt_size=1316&buffer_size=65536"
}

do_stream_file() {
    local file="$1"
    local filename
    filename="$(basename "$file")"

    info "Probing file: $filename"
    local probe
    probe=$(ffprobe -v quiet -show_streams -show_format -print_format json "$file")

    # Extract stream info
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

    # Determine if we need to scale (4K is too heavy for emulator software decode)
    local scale_filter=""
    local width
    width=$(echo "$video_res" | cut -dx -f1)
    if [[ "$width" -gt 1920 ]]; then
        warn "Resolution ${video_res} is > 1920px wide. Scaling down to 1280x720 for emulator."
        scale_filter="-vf scale=1280:720:force_original_aspect_ratio=decrease,pad=1280:720:(ow-iw)/2:(oh-ih)/2"
    fi

    # Build ffmpeg command
    local ffmpeg_cmd=(
        ffmpeg -re
        -stream_loop -1
        -i "$file"
    )

    if [[ "$has_audio" == "no" ]]; then
        info "No audio track found - generating silent audio"
        ffmpeg_cmd+=( -f lavfi -i "anullsrc=r=48000:cl=stereo" )
    fi

    # Video encoding - baseline profile for maximum emulator compatibility
    ffmpeg_cmd+=(
        -c:v libx264 -preset ultrafast -tune zerolatency
        -profile:v baseline -level 3.1
        -b:v 2M -maxrate 2M -bufsize 1M
        -g 24 -keyint_min 24
        -flags +cgop
    )

    # Add scale filter if needed
    if [[ -n "$scale_filter" ]]; then
        ffmpeg_cmd+=( $scale_filter )
    fi

    # Audio encoding
    if [[ "$has_audio" == "no" ]]; then
        ffmpeg_cmd+=( -map 0:v:0 -map 1:a:0 )
    fi
    ffmpeg_cmd+=(
        -c:a aac -b:a 128k -ac 2 -ar 48000
    )

    # Output
    ffmpeg_cmd+=(
        -mpegts_flags +resend_headers
        -muxrate 3M
        -f mpegts "udp://127.0.0.1:${UDP_PORT}?pkt_size=1316&buffer_size=65536"
    )

    info "Streaming to udp://127.0.0.1:$UDP_PORT"
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
    pkill -f "ffmpeg.*udp://127.0.0.1:$UDP_PORT" 2>/dev/null || true
    info "Stopping emulator..."
    "$ADB" -s "$EMULATOR_SERIAL" emu kill 2>/dev/null || true
    info "Stopped."
}

do_logs() {
    check_env
    "$ADB" -s "$EMULATOR_SERIAL" logcat -s MulticastPlayer ExoPlayerImpl
}

do_screenshot() {
    check_env
    "$ADB" -s "$EMULATOR_SERIAL" exec-out screencap -p > screenshot.png
    info "Screenshot saved to screenshot.png"
}

do_run() {
    do_emulator
    do_install
    do_stream
}

do_info() {
    info "Platform:       $PLATFORM ($ARCH)"
    info "Emulator ABI:   $EMU_ABI"
    info "System image:   $SYSTEM_IMAGE"
    info "GPU mode:       $GPU_MODE"
    info "JAVA_HOME:      ${JAVA_HOME:-<not set>}"
    info "ANDROID_HOME:   $ANDROID_HOME"
    info "SDK Manager:    $SDKMANAGER"
    info "ADB:            $ADB"
    info "Emulator:       $EMULATOR_BIN"
    info "ffmpeg:         $(command -v ffmpeg 2>/dev/null || echo '<not found>')"
    info "python3:        $(command -v python3 2>/dev/null || echo '<not found>')"
}

show_usage() {
    cat <<USAGE
Usage: ./run.sh [command] [-f FILE]

Commands:
  run          Full pipeline: emulator + build + install + stream (default)
  setup        Install all prerequisites
  build        Build the APK only
  emulator     Launch the Android TV emulator
  install      Build, install, and launch the app
  stream       Start streaming only (test pattern or file)
  stop         Stop emulator and ffmpeg
  logs         Tail logcat for player events
  screenshot   Capture emulator screenshot
  info         Show detected platform and tool paths

Options:
  -f, --file FILE    Stream a .ts file instead of the test pattern
                     The file is re-encoded to H.264/AAC and looped infinitely.
                     4K files are automatically scaled down for the emulator.

Platform: $PLATFORM ($ARCH), ABI: $EMU_ABI

Examples:
  ./run.sh                                                    # Test pattern
  ./run.sh -f streams/sample_1280x720_surfing_with_audio.ts   # Surfing video
  ./run.sh -f streams/sample_3840x2160.ts                     # 4K (auto-scaled)
  ./run.sh stream -f streams/sample_1280x720_surfing_with_audio.ts  # Stream only
  ./run.sh info                                               # Show platform info
USAGE
}

# --- Main ---

# Extract command (first non-flag argument)
COMMAND=""
EXTRA_ARGS=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        setup|build|emulator|install|stream|run|stop|logs|screenshot|info)
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

# Default command
COMMAND="${COMMAND:-run}"

# Parse -f from remaining args
parse_file_arg "${EXTRA_ARGS[@]+"${EXTRA_ARGS[@]}"}"

case "$COMMAND" in
    setup)      do_setup ;;
    build)      do_build ;;
    emulator)   do_emulator ;;
    install)    do_install ;;
    stream)     do_stream ;;
    run)        do_run ;;
    stop)       do_stop ;;
    logs)       do_logs ;;
    screenshot) do_screenshot ;;
    info)       do_info ;;
    *)          show_usage; exit 1 ;;
esac
