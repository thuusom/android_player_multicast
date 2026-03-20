package com.cryptoguard.multicastplayer

import android.content.Context
import android.net.Uri
import android.net.wifi.WifiManager
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.util.Log
import android.view.KeyEvent
import android.view.View
import android.view.WindowManager
import android.widget.LinearLayout
import android.widget.TextView
import androidx.fragment.app.FragmentActivity
import androidx.media3.common.C
import androidx.media3.common.Format
import androidx.media3.common.MediaItem
import androidx.media3.common.MimeTypes
import androidx.media3.common.PlaybackException
import androidx.media3.common.Player
import androidx.media3.common.TrackSelectionOverride
import androidx.media3.common.Tracks
import androidx.media3.datasource.DefaultDataSource
import androidx.media3.exoplayer.DefaultLoadControl
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.analytics.AnalyticsListener
import androidx.media3.exoplayer.source.DefaultMediaSourceFactory
import androidx.media3.exoplayer.source.MediaLoadData
import androidx.media3.ui.PlayerView

class MainActivity : FragmentActivity() {

    companion object {
        private const val TAG = "MulticastPlayer"
        // Default: listen on UDP port 5000 on all interfaces
        // For real STB multicast, use: udp://239.1.1.1:5000
        private const val DEFAULT_STREAM_URI = "udp://0.0.0.0:5000"
        private const val STATS_INTERVAL_MS = 5000L
        private const val STATUS_BAR_HIDE_DELAY_MS = 10000L
    }

    private var player: ExoPlayer? = null
    private var playerView: PlayerView? = null
    private var bufferingOverlay: LinearLayout? = null
    private var bufferingText: TextView? = null
    private var statusBar: LinearLayout? = null
    private var statusText: TextView? = null
    private var statsText: TextView? = null

    private val handler = Handler(Looper.getMainLooper())
    private var tracksLogged = false
    private var lastDroppedFrames = 0L
    private var lastRenderedFrames = 0L
    private var statusBarVisible = false
    private var multicastLock: WifiManager.MulticastLock? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        setContentView(R.layout.activity_main)

        playerView = findViewById(R.id.player_view)
        bufferingOverlay = findViewById(R.id.buffering_overlay)
        bufferingText = findViewById(R.id.buffering_text)
        statusBar = findViewById(R.id.status_bar)
        statusText = findViewById(R.id.status_text)
        statsText = findViewById(R.id.stats_text)

        Log.i(TAG, "====================================================")
        Log.i(TAG, "MulticastPlayer starting up")
        Log.i(TAG, "====================================================")
    }

    override fun onStart() {
        super.onStart()
        acquireMulticastLock()
        initPlayer()
    }

    override fun onStop() {
        super.onStop()
        handler.removeCallbacksAndMessages(null)
        releasePlayer()
        releaseMulticastLock()
    }

    /**
     * Android filters out multicast packets on WiFi by default to save battery.
     * We must hold a MulticastLock to receive IGMP multicast traffic.
     */
    private fun acquireMulticastLock() {
        try {
            val wifiManager = applicationContext.getSystemService(Context.WIFI_SERVICE) as? WifiManager
            if (wifiManager != null) {
                multicastLock = wifiManager.createMulticastLock("MulticastPlayer").apply {
                    setReferenceCounted(false)
                    acquire()
                }
                Log.i(TAG, "✓ WiFi MulticastLock acquired")
            } else {
                Log.w(TAG, "WifiManager not available — multicast lock not acquired")
            }
        } catch (e: Exception) {
            Log.e(TAG, "Failed to acquire MulticastLock", e)
        }
    }

    private fun releaseMulticastLock() {
        try {
            multicastLock?.let {
                if (it.isHeld) {
                    it.release()
                    Log.i(TAG, "WiFi MulticastLock released")
                }
            }
            multicastLock = null
        } catch (e: Exception) {
            Log.e(TAG, "Error releasing MulticastLock", e)
        }
    }

    private fun initPlayer() {
        val streamUri = intent.getStringExtra("STREAM_URI") ?: DEFAULT_STREAM_URI
        Log.i(TAG, "----------------------------------------------------")
        Log.i(TAG, "Initializing player")
        Log.i(TAG, "  Stream URI: $streamUri")
        Log.i(TAG, "----------------------------------------------------")

        // Larger buffer to handle UDP jitter and prevent stopping
        val loadControl = DefaultLoadControl.Builder()
            .setBufferDurationsMs(
                /* minBufferMs */        5000,
                /* maxBufferMs */        30000,
                /* bufferForPlaybackMs */ 1500,
                /* bufferForPlaybackAfterRebufferMs */ 3000
            )
            .build()

        Log.i(TAG, "LoadControl: minBuffer=5s, maxBuffer=30s, playbackBuffer=1.5s, rebufferBuffer=3s")

        tracksLogged = false
        lastDroppedFrames = 0
        lastRenderedFrames = 0

        // Use our custom MulticastUdpDataSource for UDP URIs (handles IGMP join)
        val dataSourceFactory = MulticastUdpDataSource.Factory(
            delegateFactory = DefaultDataSource.Factory(this)
        )
        val mediaSourceFactory = DefaultMediaSourceFactory(dataSourceFactory)

        Log.i(TAG, "Using MulticastUdpDataSource (IGMP multicast support)")

        player = ExoPlayer.Builder(this)
            .setLoadControl(loadControl)
            .setMediaSourceFactory(mediaSourceFactory)
            .build().also { exoPlayer ->
                playerView?.player = exoPlayer

                // Enable subtitle rendering
                playerView?.subtitleView?.visibility = View.VISIBLE

                val mediaItem = MediaItem.fromUri(Uri.parse(streamUri))
                exoPlayer.setMediaItem(mediaItem)
                exoPlayer.playWhenReady = true

                // --- Main player listener ---
                exoPlayer.addListener(object : Player.Listener {
                    override fun onPlaybackStateChanged(playbackState: Int) {
                        val state = when (playbackState) {
                            Player.STATE_IDLE -> "IDLE"
                            Player.STATE_BUFFERING -> "BUFFERING"
                            Player.STATE_READY -> "READY"
                            Player.STATE_ENDED -> "ENDED"
                            else -> "UNKNOWN($playbackState)"
                        }
                        Log.i(TAG, ">>> Playback state changed: $state")

                        when (playbackState) {
                            Player.STATE_BUFFERING -> {
                                showBuffering("Buffering stream data...")
                            }
                            Player.STATE_READY -> {
                                hideBuffering()
                                showStatusBar()
                                if (!tracksLogged) {
                                    logTrackInfo(exoPlayer)
                                    tracksLogged = true
                                }
                                startPeriodicStats()
                            }
                            Player.STATE_ENDED -> {
                                Log.w(TAG, "Playback ended - attempting restart in 2s")
                                showBuffering("Stream ended. Restarting...")
                                handler.postDelayed({
                                    Log.i(TAG, "Restarting playback...")
                                    exoPlayer.seekToDefaultPosition()
                                    exoPlayer.prepare()
                                }, 2000)
                            }
                            Player.STATE_IDLE -> {
                                showBuffering("Waiting for stream...")
                            }
                        }
                    }

                    override fun onPlayerError(error: PlaybackException) {
                        Log.e(TAG, "!!! PLAYER ERROR !!!")
                        Log.e(TAG, "  Error code: ${error.errorCode}")
                        Log.e(TAG, "  Error code name: ${error.errorCodeName}")
                        Log.e(TAG, "  Message: ${error.message}")
                        Log.e(TAG, "  Cause: ${error.cause}")
                        error.cause?.let { cause ->
                            Log.e(TAG, "  Cause message: ${cause.message}")
                            Log.e(TAG, "  Cause stack:", cause)
                        }

                        showBuffering("Error: ${error.errorCodeName}\nRetrying in 3s...")

                        // Auto-retry on error
                        handler.postDelayed({
                            Log.i(TAG, "Retrying after error...")
                            exoPlayer.prepare()
                        }, 3000)
                    }

                    override fun onTracksChanged(tracks: Tracks) {
                        Log.i(TAG, ">>> Tracks changed, re-logging track info")
                        logTrackInfo(exoPlayer)
                    }

                    override fun onIsPlayingChanged(isPlaying: Boolean) {
                        Log.i(TAG, ">>> isPlaying changed: $isPlaying")
                        if (isPlaying) {
                            statusText?.text = "● LIVE"
                        } else {
                            statusText?.text = "⏸ PAUSED"
                        }
                    }
                })

                // --- Analytics listener for detailed stats ---
                exoPlayer.addAnalyticsListener(object : AnalyticsListener {
                    override fun onDroppedVideoFrames(
                        eventTime: AnalyticsListener.EventTime,
                        droppedFrames: Int,
                        elapsedMs: Long
                    ) {
                        lastDroppedFrames += droppedFrames
                        Log.d(TAG, "Dropped $droppedFrames video frames in ${elapsedMs}ms (total dropped: $lastDroppedFrames)")
                    }

                    override fun onRenderedFirstFrame(
                        eventTime: AnalyticsListener.EventTime,
                        output: Any,
                        renderTimeMs: Long
                    ) {
                        Log.i(TAG, ">>> First frame rendered at ${renderTimeMs}ms")
                    }

                    override fun onVideoDecoderInitialized(
                        eventTime: AnalyticsListener.EventTime,
                        decoderName: String,
                        initializedTimestampMs: Long,
                        initializationDurationMs: Long
                    ) {
                        Log.i(TAG, "Video decoder initialized: $decoderName (took ${initializationDurationMs}ms)")
                    }

                    override fun onAudioDecoderInitialized(
                        eventTime: AnalyticsListener.EventTime,
                        decoderName: String,
                        initializedTimestampMs: Long,
                        initializationDurationMs: Long
                    ) {
                        Log.i(TAG, "Audio decoder initialized: $decoderName (took ${initializationDurationMs}ms)")
                    }

                    override fun onDownstreamFormatChanged(
                        eventTime: AnalyticsListener.EventTime,
                        mediaLoadData: MediaLoadData
                    ) {
                        val trackTypeStr = when (mediaLoadData.trackType) {
                            C.TRACK_TYPE_VIDEO -> "VIDEO"
                            C.TRACK_TYPE_AUDIO -> "AUDIO"
                            C.TRACK_TYPE_TEXT -> "TEXT"
                            else -> "TYPE(${mediaLoadData.trackType})"
                        }
                        mediaLoadData.trackFormat?.let { format ->
                            Log.i(TAG, "Downstream format changed ($trackTypeStr):")
                            logFormat("  $trackTypeStr", format)
                        }
                    }
                })

                Log.i(TAG, "Calling prepare()...")
                showBuffering("Connecting to stream...")
                exoPlayer.prepare()
            }
    }

    private fun logTrackInfo(player: ExoPlayer) {
        Log.i(TAG, "====================================================")
        Log.i(TAG, "TRACK INFORMATION")
        Log.i(TAG, "====================================================")

        val tracks = player.currentTracks
        var videoCount = 0
        var audioCount = 0
        var textCount = 0
        var otherCount = 0

        for (group in tracks.groups) {
            for (i in 0 until group.length) {
                val format = group.getTrackFormat(i)
                val selected = group.isTrackSelected(i)
                val supported = group.isTrackSupported(i)

                when (group.type) {
                    C.TRACK_TYPE_VIDEO -> {
                        videoCount++
                        Log.i(TAG, "----------------------------------------------------")
                        Log.i(TAG, "VIDEO TRACK #$videoCount ${if (selected) "[SELECTED]" else "[not selected]"} ${if (supported) "" else "[UNSUPPORTED]"}")
                        logFormat("  ", format)
                    }
                    C.TRACK_TYPE_AUDIO -> {
                        audioCount++
                        Log.i(TAG, "----------------------------------------------------")
                        Log.i(TAG, "AUDIO TRACK #$audioCount ${if (selected) "[SELECTED]" else "[not selected]"} ${if (supported) "" else "[UNSUPPORTED]"}")
                        logFormat("  ", format)
                    }
                    C.TRACK_TYPE_TEXT -> {
                        textCount++
                        Log.i(TAG, "----------------------------------------------------")
                        Log.i(TAG, "SUBTITLE TRACK #$textCount ${if (selected) "[SELECTED]" else "[not selected]"} ${if (supported) "" else "[UNSUPPORTED]"}")
                        logFormat("  ", format)
                    }
                    else -> {
                        otherCount++
                        Log.i(TAG, "----------------------------------------------------")
                        Log.i(TAG, "OTHER TRACK (type=${group.type}) ${if (selected) "[SELECTED]" else ""}")
                        logFormat("  ", format)
                    }
                }
            }
        }

        Log.i(TAG, "====================================================")
        Log.i(TAG, "TRACK SUMMARY: $videoCount video, $audioCount audio, $textCount subtitle, $otherCount other")
        Log.i(TAG, "====================================================")
    }

    private fun logFormat(prefix: String, format: Format) {
        format.id?.let { Log.i(TAG, "${prefix}ID: $it") }
        format.label?.let { Log.i(TAG, "${prefix}Label: $it") }
        format.sampleMimeType?.let { Log.i(TAG, "${prefix}MIME: $it") }
        format.codecs?.let { Log.i(TAG, "${prefix}Codecs: $it") }
        format.containerMimeType?.let { Log.i(TAG, "${prefix}Container: $it") }
        format.language?.let { Log.i(TAG, "${prefix}Language: $it") }

        if (format.width != Format.NO_VALUE && format.height != Format.NO_VALUE) {
            Log.i(TAG, "${prefix}Resolution: ${format.width}x${format.height}")
        }
        if (format.frameRate != Format.NO_VALUE.toFloat()) {
            Log.i(TAG, "${prefix}Frame rate: ${format.frameRate} fps")
        }
        if (format.bitrate != Format.NO_VALUE) {
            Log.i(TAG, "${prefix}Bitrate: ${format.bitrate / 1000} kbps")
        }
        if (format.sampleRate != Format.NO_VALUE) {
            Log.i(TAG, "${prefix}Sample rate: ${format.sampleRate} Hz")
        }
        if (format.channelCount != Format.NO_VALUE) {
            Log.i(TAG, "${prefix}Channels: ${format.channelCount}")
        }
        if (format.pcmEncoding != Format.NO_VALUE) {
            Log.i(TAG, "${prefix}PCM encoding: ${format.pcmEncoding}")
        }
        if (format.selectionFlags != 0) {
            Log.i(TAG, "${prefix}Selection flags: ${format.selectionFlags}")
        }
        if (format.roleFlags != 0) {
            Log.i(TAG, "${prefix}Role flags: ${format.roleFlags}")
        }
    }

    private fun startPeriodicStats() {
        handler.removeCallbacksAndMessages(STATS_TOKEN)
        handler.postDelayed(statsRunnable, STATS_INTERVAL_MS)
    }

    private val STATS_TOKEN = Object()

    private val statsRunnable = object : Runnable {
        override fun run() {
            player?.let { p ->
                if (p.isPlaying) {
                    val videoFormat = p.videoFormat
                    val audioFormat = p.audioFormat
                    val bufferedMs = p.totalBufferedDuration

                    val fps = videoFormat?.frameRate ?: 0f
                    val resolution = if (videoFormat != null && videoFormat.width != Format.NO_VALUE)
                        "${videoFormat.width}x${videoFormat.height}" else "unknown"
                    val videoBitrate = if (videoFormat?.bitrate != Format.NO_VALUE && videoFormat?.bitrate != null)
                        "${videoFormat.bitrate / 1000}kbps" else "n/a"
                    val audioCodec = audioFormat?.sampleMimeType ?: "none"
                    val audioRate = if (audioFormat?.sampleRate != Format.NO_VALUE && audioFormat?.sampleRate != null)
                        "${audioFormat.sampleRate}Hz" else "n/a"

                    Log.i(TAG, "[STATS] Playing | res=$resolution fps=$fps vBitrate=$videoBitrate | audio=$audioCodec@$audioRate | buffer=${bufferedMs}ms | dropped=$lastDroppedFrames")

                    // Update on-screen stats
                    statsText?.text = "${resolution} ${fps}fps buf:${bufferedMs}ms drop:$lastDroppedFrames"
                } else {
                    Log.i(TAG, "[STATS] Not playing | state=${p.playbackState} | playWhenReady=${p.playWhenReady}")
                }
            }
            handler.postDelayed(this, STATS_INTERVAL_MS)
        }
    }

    private fun showBuffering(message: String) {
        Log.i(TAG, "UI: Showing buffering overlay: $message")
        bufferingOverlay?.visibility = View.VISIBLE
        bufferingText?.text = message
    }

    private fun hideBuffering() {
        Log.i(TAG, "UI: Hiding buffering overlay")
        bufferingOverlay?.visibility = View.GONE
    }

    private fun showStatusBar() {
        if (!statusBarVisible) {
            statusBar?.visibility = View.VISIBLE
            statusBarVisible = true
            // Auto-hide after delay
            handler.postDelayed({
                statusBar?.visibility = View.GONE
                statusBarVisible = false
            }, STATUS_BAR_HIDE_DELAY_MS)
        }
    }

    private fun releasePlayer() {
        Log.i(TAG, "Releasing player")
        player?.release()
        player = null
    }

    override fun onKeyDown(keyCode: Int, event: KeyEvent?): Boolean {
        when (keyCode) {
            KeyEvent.KEYCODE_DPAD_CENTER, KeyEvent.KEYCODE_ENTER -> {
                // Toggle play/pause
                player?.let {
                    it.playWhenReady = !it.playWhenReady
                    Log.i(TAG, "User toggled playWhenReady to: ${it.playWhenReady}")
                    return true
                }
            }
            KeyEvent.KEYCODE_DPAD_UP -> {
                // Show status bar
                statusBar?.visibility = View.VISIBLE
                statusBarVisible = true
                handler.removeCallbacksAndMessages(null)
                startPeriodicStats()
                handler.postDelayed({
                    statusBar?.visibility = View.GONE
                    statusBarVisible = false
                }, STATUS_BAR_HIDE_DELAY_MS)
                return true
            }
            KeyEvent.KEYCODE_I, KeyEvent.KEYCODE_INFO -> {
                // Toggle status bar
                if (statusBarVisible) {
                    statusBar?.visibility = View.GONE
                    statusBarVisible = false
                } else {
                    showStatusBar()
                }
                return true
            }
        }
        return super.onKeyDown(keyCode, event)
    }
}
