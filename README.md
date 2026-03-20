# Android TV Multicast MPEGTS Player

A sample Android TV application that plays back MPEGTS video streams over UDP. Designed for Set-Top Box (STB) deployments where video is delivered via IP multicast.

## What It Does

- Receives MPEGTS-over-UDP streams using AndroidX Media3 (ExoPlayer)
- Runs on Android TV and AOSP devices (API 21+)
- Supports both unicast UDP (for emulator testing) and multicast (for real hardware)
- Plays test patterns or real `.ts` video files (looped continuously)
- Fullscreen playback with D-pad play/pause control
- Buffering overlay with spinner and status messages
- On-screen status bar showing LIVE indicator, resolution, FPS, buffer depth, and dropped frames
- Auto-retry on errors and stream interruptions
- Extensive logcat logging: track info on connect, periodic stats every 5 seconds

## Prerequisites

- **macOS** (Apple Silicon or Intel)
- **Homebrew** — [brew.sh](https://brew.sh)
- **ffmpeg** — `brew install ffmpeg`
- **Android SDK** — installed at `~/Library/Android/sdk` (default Android Studio location)
- **JDK 17** — installed automatically by `make setup`

## Quick Start

### Test pattern (no files needed)

```bash
make setup    # once: install JDK 17, Android TV image, create AVD
make run      # build, launch emulator, install app, stream test pattern
```

### Stream a video file

```bash
# Surfing video (1280x720, MPEG-2 + MP2 audio → re-encoded to H.264/AAC)
./run.sh -f streams/sample_1280x720_surfing_with_audio.ts

# 4K video (auto-scaled to 720p for emulator, silent audio generated)
./run.sh -f streams/sample_3840x2160.ts
```

### Step by step

```bash
# 1. Install prerequisites
make setup

# 2. Build the APK
make build

# 3. Launch the Android TV emulator (waits for boot)
make emulator

# 4. Install APK and launch the app
make install

# 5a. Stream test pattern
make stream

# 5b. Or stream a video file (in place of 5a)
./run.sh stream -f streams/sample_1280x720_surfing_with_audio.ts

# 6. (In another terminal) Watch player logs
make logs
```

## Streaming Video Files

The `./run.sh` script accepts a `-f` / `--file` parameter to stream any `.ts` file instead of the test pattern. The file is:

- **Probed** automatically — resolution, codec, audio presence are detected and logged
- **Re-encoded** to H.264 Baseline + AAC for maximum emulator compatibility
- **Looped** infinitely with `-stream_loop -1` so playback never ends
- **Scaled** automatically if the source is wider than 1920px (e.g., 4K → 720p)
- **Silent audio** is generated if the source file has no audio track

### Examples

```bash
# Full pipeline: boot emulator + build + install + stream file
./run.sh -f streams/sample_1280x720_surfing_with_audio.ts

# Stream only (emulator already running, app already installed)
./run.sh stream -f streams/sample_1280x720_surfing_with_audio.ts

# 4K file (auto-scaled down for emulator)
./run.sh -f streams/sample_3840x2160.ts

# Test pattern (no -f flag)
./run.sh
```

### Sample files included

| File | Resolution | Video | Audio | Duration |
|------|-----------|-------|-------|----------|
| `streams/sample_1280x720_surfing_with_audio.ts` | 1280x720 | MPEG-2 | MP2 stereo 384kbps | 3:03 |
| `streams/sample_3840x2160.ts` | 3840x2160 | MPEG-2 | none | 0:28 |

Both files are re-encoded on-the-fly to H.264/AAC before streaming.

## What You'll See

### On Screen (test pattern mode)
- **Test pattern** (testsrc2 color bars) — confirms video decoding works
- **Live clock** (top-left) — proves the stream is live, not frozen
- **"LIVE MPEGTS TEST"** label — identifies the stream
- **Frame counter and PTS** (bottom) — shows frame number and presentation timestamp

### On Screen (file mode)
- **Video content** from your `.ts` file, re-encoded and streamed live

### On Screen (both modes)
- **Buffering overlay** — semi-transparent spinner shown during buffering or reconnection
- **Status bar** (top, auto-hides after 10s) — shows LIVE/PAUSED state, resolution, FPS, buffer depth, dropped frame count

### On Screen Controls
- **D-pad Center / Enter** — toggle play/pause
- **D-pad Up** — show status bar (auto-hides after 10s)
- **I key** — toggle status bar on/off

### In Logcat (`make logs`)

On initial connection you'll see full track information:
```
MulticastPlayer: ====================================================
MulticastPlayer: TRACK INFORMATION
MulticastPlayer: ====================================================
MulticastPlayer: VIDEO TRACK #1 [SELECTED]
MulticastPlayer:   ID: 1/256
MulticastPlayer:   MIME: video/avc
MulticastPlayer:   Codecs: avc1.42C01F
MulticastPlayer:   Resolution: 1280x720
MulticastPlayer: AUDIO TRACK #1 [SELECTED]
MulticastPlayer:   ID: 1/257
MulticastPlayer:   MIME: audio/mp4a-latm
MulticastPlayer:   Codecs: mp4a.40.2
MulticastPlayer:   Language: en
MulticastPlayer:   Sample rate: 48000 Hz
MulticastPlayer:   Channels: 2
MulticastPlayer: TRACK SUMMARY: 1 video, 1 audio, 0 subtitle, 0 other
```

During playback, every 5 seconds:
```
MulticastPlayer: [STATS] Playing | res=1280x720 fps=-1.0 vBitrate=n/a | audio=audio/mp4a-latm@48000Hz | buffer=2017ms | dropped=0
```

## Available Commands

### Makefile

| Command           | Description                                       |
|-------------------|---------------------------------------------------|
| `make help`       | Show all available commands                       |
| `make setup`      | Install JDK 17, Android TV image, create AVD      |
| `make build`      | Build the debug APK                                |
| `make emulator`   | Launch Android TV emulator                         |
| `make install`    | Build, install APK, and launch app                 |
| `make redirect`   | Set up UDP port redirect on emulator               |
| `make stream`     | Set up UDP redirect and start test pattern stream  |
| `make run`        | Full pipeline: emulator + install + test stream    |
| `make stop`       | Stop emulator and ffmpeg                           |
| `make logs`       | Tail logcat for player events                      |
| `make screenshot` | Capture emulator screenshot to `screenshot.png`    |
| `make clean`      | Clean build artifacts                              |
| `make check-env`  | Verify all prerequisites are installed             |

### Bash script (`./run.sh`)

```bash
./run.sh                          # Full pipeline with test pattern
./run.sh -f FILE                  # Full pipeline with a .ts file
./run.sh setup                    # Install prerequisites
./run.sh build                    # Build APK
./run.sh emulator                 # Launch emulator
./run.sh install                  # Build + install + launch app
./run.sh stream                   # Test pattern stream only
./run.sh stream -f FILE           # File stream only (emulator already up)
./run.sh stop                     # Stop everything
./run.sh logs                     # Tail logcat
./run.sh screenshot               # Capture screenshot
./run.sh --help                   # Show full usage
```

## How It Works

### Architecture

```
┌─────────────────────────────────────────────────────────┐
│  Host (macOS)                                           │
│                                                         │
│  ffmpeg ──► udp://127.0.0.1:5000 ──► emulator console  │
│  (test pattern or .ts file          UDP redirect        │
│   re-encoded to H.264/AAC)              │               │
│                             ┌────────────┘              │
│                             ▼                           │
│              ┌───────────────────────────┐              │
│              │   Android TV Emulator     │              │
│              │                           │              │
│              │   ExoPlayer listens on    │              │
│              │   udp://0.0.0.0:5000      │              │
│              │                           │              │
│              │   ┌─────────────────────┐ │              │
│              │   │ MPEGTS demux        │ │              │
│              │   │  ├─ H.264 → video   │ │              │
│              │   │  └─ AAC   → audio   │ │              │
│              │   └─────────────────────┘ │              │
│              │                           │              │
│              │   Buffering overlay       │              │
│              │   Status bar (LIVE/stats) │              │
│              │   Auto-retry on error     │              │
│              └───────────────────────────┘              │
└─────────────────────────────────────────────────────────┘
```

### Network Containment

The Android emulator uses NAT (SLIRP) networking which doesn't support IP multicast. To work around this safely:

1. The emulator console's `redir add udp:5000:5000` command forwards UDP packets from host port 5000 to guest port 5000
2. ffmpeg sends unicast to `udp://127.0.0.1:5000` — packets never leave the machine
3. The app listens on `udp://0.0.0.0:5000` (all interfaces) so it receives the forwarded packets

**No multicast traffic touches the network.** Everything stays on localhost.

### Stream Quality

The ffmpeg stream is configured to minimize artifacts:
- **`-profile:v baseline -level 3.1`** — maximum decoder compatibility (especially for emulator)
- **`-tune zerolatency`** — no B-frames, reduces decode latency
- **`-g 24` (GOP ~ 1 second)** — frequent keyframes for faster tune-in
- **`-flags +cgop`** — closed GOPs prevent cross-GOP decoding issues
- **`-mpegts_flags +resend_headers`** — re-sends PAT/PMT tables so the player can tune in mid-stream
- **`-bufsize 1M` + `buffer_size=65536`** — proper rate control and UDP socket buffer
- **`pkt_size=1316`** — standard MPEG-TS over UDP packet size (7 TS packets x 188 bytes)

### Player Resilience

The app is designed to keep playing:
- **Larger buffers** (5s min, 30s max) handle UDP jitter
- **Auto-retry on error** — waits 3 seconds and calls `prepare()` again
- **Auto-restart on STATE_ENDED** — seeks back to default position and re-prepares
- **Buffering overlay** — shows a spinner with status message during buffering, errors, or reconnection

## On Real STB Hardware

On a real Set-Top Box connected to a multicast-capable LAN:

### 1. Change the stream URI

```kotlin
// In MainActivity.kt, change DEFAULT_STREAM_URI:
private const val DEFAULT_STREAM_URI = "udp://239.1.1.1:5000"

// Or pass via intent at runtime:
adb shell am start -n com.cryptoguard.multicastplayer/.MainActivity \
    --es STREAM_URI "udp://239.1.1.1:5000"
```

### 2. Multicast on the LAN

```bash
ffmpeg -re -i input.ts \
    -c copy \
    -f mpegts "udp://239.1.1.1:5000?pkt_size=1316&ttl=1"
```

## Streaming Your Own Content

Replace the test pattern with any video file:

```bash
# Via run.sh (recommended - handles probing, scaling, audio generation)
./run.sh stream -f /path/to/any_video.ts

# Manual ffmpeg (re-encode)
ffmpeg -re -stream_loop -1 -i /path/to/video.mp4 \
    -c:v libx264 -preset ultrafast -tune zerolatency \
    -profile:v baseline -b:v 2M \
    -c:a aac -b:a 128k -ac 2 \
    -f mpegts "udp://127.0.0.1:5000?pkt_size=1316"

# Manual ffmpeg (pass-through, if already H.264/AAC)
ffmpeg -re -stream_loop -1 -i input.ts -c copy \
    -f mpegts "udp://127.0.0.1:5000?pkt_size=1316"
```

## Project Structure

```
├── Makefile                          # Build/run automation (test pattern)
├── run.sh                            # Bash script with -f FILE support
├── ffmpeg_filter.txt                 # Drawtext filter for test pattern overlay
├── README.md                         # This file
├── build.gradle.kts                  # Root Gradle config
├── settings.gradle.kts               # Project settings
├── gradle.properties                 # Gradle properties
├── local.properties                  # SDK path (generated by setup)
├── streams/                          # Sample .ts files
│   ├── sample_1280x720_surfing_with_audio.ts
│   └── sample_3840x2160.ts
├── app/
│   ├── build.gradle.kts              # App dependencies (Media3, Leanback)
│   └── src/main/
│       ├── AndroidManifest.xml       # TV launcher, permissions
│       ├── java/.../MainActivity.kt  # ExoPlayer + logging + buffering UI
│       └── res/
│           ├── layout/activity_main.xml  # PlayerView + buffering overlay + status bar
│           ├── drawable/banner.xml
│           └── values/strings.xml
```

## Troubleshooting

| Problem | Solution |
|---------|----------|
| **Build fails: "25.0.2" error** | JDK 25 is being used instead of 17. Run `export JAVA_HOME=$(brew --prefix openjdk@17)/libexec/openjdk.jdk/Contents/Home` before building |
| **Emulator won't boot** | Run `make setup` to install the Android TV system image. Verify with `emulator -list-avds` |
| **App shows buffering forever** | Make sure `make stream` or `./run.sh stream -f ...` is running. Check `make logs` for errors |
| **Video is garbled/artifacts** | The baseline profile + closed GOPs settings should fix this. If still garbled, reduce the video bitrate in `run.sh` |
| **Stream stops after a few seconds** | The app auto-retries. Check `make logs` — look for `[STATS]` lines to confirm it's playing. File streams loop infinitely |
| **4K file is slow** | 4K sources are auto-scaled to 720p. If encoding is too slow, use a pre-encoded 720p file instead |
| **"More than one device" error** | Unplug any physical Android device, or the commands target `emulator-5554` specifically |
| **UDP redirect fails** | The emulator console must be on `localhost:5554`. Check with `nc localhost 5554` |
| **No audio** | If the source file has no audio, `run.sh` auto-generates a silent track. Check `make logs` for `AUDIO TRACK` |
| **File not found** | Paths are relative to the project root. Use `./run.sh -f streams/filename.ts` |

## Tech Stack

- **Kotlin** — app language
- **AndroidX Media3 (ExoPlayer) 1.5.1** — MPEGTS demuxing, UDP source, H.264/AAC decoding
- **AndroidX Leanback** — Android TV launcher integration
- **ffmpeg** — stream generation & re-encoding (MPEG-2/MP2 → H.264/AAC → MPEGTS/UDP)
- **Gradle 8.9 / AGP 8.7.3** — build system
