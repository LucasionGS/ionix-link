package dev.ionnet.ionix_link

import android.media.MediaCodec
import android.media.MediaCodecList
import android.media.MediaFormat
import android.os.Build
import android.os.Handler
import android.os.HandlerThread
import android.os.Looper
import android.util.Log
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.BasicMessageChannel
import io.flutter.plugin.common.BinaryCodec
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.view.TextureRegistry
import java.nio.ByteBuffer
import java.nio.ByteOrder

/**
 * H.264 decoding for the screen view (lib/platform/android_video_decoder.dart): one MediaCodec per decoder, in
 * asynchronous mode on its own thread, drawing into a Flutter SurfaceProducer whose id is the Texture widget's.
 *
 * Channels: `dev.ionnet.ionix_link/video` (methods `available`, `create`, `configure`, `release`),
 * `.../video/events` (maps with `id` and `event`: `frame` {seq}, `format` {width, height, handlesCrop and the
 * crop-left/top/right/bottom keys the decoder set}, `error` {message}) and `.../video/units` (binary: u64 id, u32 seq, u8 flags,
 * then one access unit). Presentation times are seq × 1000 µs, which gives every drawn frame's seq back; the stream
 * has no B-frames, so output order is input order.
 */
class VideoDecoders private constructor(private val engine: FlutterEngine) : MethodChannel.MethodCallHandler, EventChannel.StreamHandler {
    companion object {
        private const val TAG = "ionix-video"
        private const val MIME = MediaFormat.MIMETYPE_VIDEO_AVC
        private const val HEADER = 13
        private const val FLAG_KEYFRAME = 1
        private const val MAX_WAITING = 60 // units queued for input buffers before the oldest are dropped

        /** Answer the video channels of [engine]. */
        fun register(engine: FlutterEngine) {
            VideoDecoders(engine)
        }
    }

    private val main = Handler(Looper.getMainLooper())
    private val decoders = HashMap<Long, Decoder>()
    private var sink: EventChannel.EventSink? = null

    init {
        val messenger = engine.dartExecutor.binaryMessenger
        MethodChannel(messenger, "dev.ionnet.ionix_link/video").setMethodCallHandler(this)
        EventChannel(messenger, "dev.ionnet.ionix_link/video/events").setStreamHandler(this)
        BasicMessageChannel(messenger, "dev.ionnet.ionix_link/video/units", BinaryCodec.INSTANCE).setMessageHandler { message, reply ->
            if (message != null) onUnit(message)
            reply.reply(null)
        }
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
        sink = events
    }

    override fun onCancel(arguments: Any?) {
        sink = null
    }

    /** Send an event to Dart from any thread. */
    private fun emit(id: Long, event: String, fields: Map<String, Any> = emptyMap()) {
        main.post { sink?.success(fields + mapOf("id" to id, "event" to event)) }
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "available" -> result.success(hasDecoder())
            "create" -> {
                val producer = engine.renderer.createSurfaceProducer()
                val decoder = Decoder(producer)
                decoders[decoder.id] = decoder
                result.success(decoder.id)
            }
            "configure" -> {
                val decoder = decoders[call.idArgument()]
                val width = call.argument<Int>("width") ?: 0
                val height = call.argument<Int>("height") ?: 0
                val sps = call.argument<ByteArray>("sps")
                val pps = call.argument<ByteArray>("pps")
                if (decoder == null || width <= 0 || height <= 0 || sps == null || pps == null) {
                    result.error("invalid_argument", "configure needs a decoder id, a size, an SPS and a PPS.", null)
                    return
                }
                decoder.configure(width, height, sps, pps)
                result.success(null)
            }
            "release" -> {
                decoders.remove(call.idArgument())?.release()
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    private fun MethodCall.idArgument(): Long = (argument<Any>("id") as? Number)?.toLong() ?: -1L

    private fun hasDecoder(): Boolean = MediaCodecList(MediaCodecList.REGULAR_CODECS).codecInfos.any { info ->
        !info.isEncoder && info.supportedTypes.any { it.equals(MIME, ignoreCase = true) }
    }

    private fun onUnit(message: ByteBuffer) {
        if (message.remaining() < HEADER) return
        message.order(ByteOrder.BIG_ENDIAN)
        val id = message.getLong()
        val seq = message.getInt().toLong() and 0xffffffffL
        val flags = message.get().toInt()
        val decoder = decoders[id] ?: return
        // The buffer is only valid during this call.
        val data = ByteArray(message.remaining())
        message.get(data)
        decoder.queue(AccessUnit(seq, data, flags and FLAG_KEYFRAME != 0))
    }

    private class Config(val width: Int, val height: Int, val sps: ByteArray, val pps: ByteArray)

    private class AccessUnit(val seq: Long, val data: ByteArray, val keyframe: Boolean)

    /** One MediaCodec and its texture. Everything touching the codec runs on [handler]. */
    private inner class Decoder(private val producer: TextureRegistry.SurfaceProducer) {
        val id: Long = producer.id()
        private val thread = HandlerThread("ionix-video-$id").apply { start() }
        private val handler = Handler(thread.looper)
        private var codec: MediaCodec? = null
        private val freeInputs = ArrayDeque<Int>()
        private val waiting = ArrayDeque<AccessUnit>()
        private var released = false
        private var needKeyframe = false
        private var config: Config? = null // what the codec was last configured with, to start it again on a new surface
        private var surfaceGone = false // between onSurfaceCleanup and onSurfaceAvailable the codec has nothing to draw on

        init {
            producer.setCallback(object : TextureRegistry.SurfaceProducer.Callback {
                override fun onSurfaceAvailable() {
                    // A new surface after the old one was cleaned up (low memory in the background): decode into it.
                    handler.post {
                        if (released || !surfaceGone) return@post
                        surfaceGone = false
                        val last = config ?: return@post
                        // The next keyframe brings the picture back; the daemon sends one every second.
                        needKeyframe = true
                        startCodec(last)
                    }
                }

                override fun onSurfaceCleanup() {
                    // The surface is released after this returns, and a codec holding a dead surface only errors.
                    handler.post {
                        if (released) return@post
                        surfaceGone = true
                        stopCodec()
                    }
                }
            })
        }

        fun configure(width: Int, height: Int, sps: ByteArray, pps: ByteArray) {
            main.post { producer.setSize(width, height) }
            handler.post {
                if (released) return@post
                stopCodec()
                val next = Config(width, height, sps, pps)
                config = next
                needKeyframe = false
                if (!surfaceGone) startCodec(next)
            }
        }

        private fun startCodec(c: Config) {
            try {
                val format = MediaFormat.createVideoFormat(MIME, c.width, c.height).apply {
                    setByteBuffer("csd-0", ByteBuffer.wrap(c.sps))
                    setByteBuffer("csd-1", ByteBuffer.wrap(c.pps))
                    setInteger(MediaFormat.KEY_PRIORITY, 0) // real time
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) setInteger(MediaFormat.KEY_LOW_LATENCY, 1)
                }
                val created = MediaCodec.createDecoderByType(MIME)
                created.setCallback(Callbacks(created), handler)
                created.configure(format, producer.surface, null, 0)
                created.start()
                codec = created
                Log.i(TAG, "decoder $id: ${created.name} for ${c.width}x${c.height}")
            } catch (e: Exception) {
                fail("The phone's video decoder would not start: ${e.message}")
            }
        }

        fun queue(unit: AccessUnit) {
            handler.post {
                if (released || codec == null) return@post
                if (unit.keyframe) {
                    // Nothing before a keyframe is needed any more; if the decoder has fallen behind, skip ahead.
                    waiting.clear()
                    needKeyframe = false
                }
                else if (needKeyframe) {
                    return@post
                }
                else if (waiting.size >= MAX_WAITING) {
                    // Too far behind: what is queued can be dropped only together with everything up to a keyframe.
                    waiting.clear()
                    needKeyframe = true
                    return@post
                }
                waiting.addLast(unit)
                pump()
            }
        }

        private fun pump() {
            val current = codec ?: return
            while (freeInputs.isNotEmpty() && waiting.isNotEmpty()) {
                val index = freeInputs.removeFirst()
                val unit = waiting.removeFirst()
                try {
                    val buffer = current.getInputBuffer(index) ?: continue
                    if (unit.data.size > buffer.capacity()) {
                        fail("A video frame of ${unit.data.size} bytes does not fit the decoder's ${buffer.capacity()}.")
                        return
                    }
                    buffer.clear()
                    buffer.put(unit.data)
                    current.queueInputBuffer(index, 0, unit.data.size, unit.seq * 1000, if (unit.keyframe) MediaCodec.BUFFER_FLAG_KEY_FRAME else 0)
                } catch (e: Exception) {
                    fail("The phone's video decoder stopped: ${e.message}")
                    return
                }
            }
        }

        private inner class Callbacks(private val owner: MediaCodec) : MediaCodec.Callback() {
            override fun onInputBufferAvailable(codec: MediaCodec, index: Int) {
                if (owner !== this@Decoder.codec) return
                freeInputs.addLast(index)
                pump()
            }

            override fun onOutputBufferAvailable(codec: MediaCodec, index: Int, info: MediaCodec.BufferInfo) {
                if (owner !== this@Decoder.codec) return
                try {
                    val draw = info.size > 0 && info.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG == 0
                    codec.releaseOutputBuffer(index, draw)
                    if (draw) emit(id, "frame", mapOf("seq" to info.presentationTimeUs / 1000))
                } catch (e: IllegalStateException) {
                    Log.w(TAG, "decoder $id: output after stop: ${e.message}")
                }
            }

            override fun onOutputFormatChanged(codec: MediaCodec, format: MediaFormat) {
                if (owner !== this@Decoder.codec) return
                // Passed on as reported; Dart works out the texture's layout with the SPS, because some decoders
                // (the emulator's) report the visible size here and no crop, while their buffers are the coded size.
                val fields = mutableMapOf<String, Any>(
                    "width" to format.getInteger(MediaFormat.KEY_WIDTH),
                    "height" to format.getInteger(MediaFormat.KEY_HEIGHT),
                    "handlesCrop" to producer.handlesCropAndRotation(),
                )
                for (key in listOf("crop-left", "crop-top", "crop-right", "crop-bottom")) {
                    if (format.containsKey(key)) fields[key] = format.getInteger(key)
                }
                Log.i(TAG, "decoder $id: output format $fields")
                emit(id, "format", fields)
            }

            override fun onError(codec: MediaCodec, e: MediaCodec.CodecException) {
                if (owner !== this@Decoder.codec) return
                fail("The phone's video decoder failed: ${e.diagnosticInfo}")
            }
        }

        private fun fail(message: String) {
            Log.w(TAG, "decoder $id: $message")
            stopCodec()
            emit(id, "error", mapOf("message" to message))
        }

        private fun stopCodec() {
            val current = codec ?: return
            codec = null
            freeInputs.clear()
            waiting.clear()
            try {
                current.stop()
            } catch (e: Exception) {
                Log.w(TAG, "decoder $id: stop: ${e.message}")
            }
            current.release()
        }

        fun release() {
            handler.post {
                released = true
                stopCodec()
                main.post { producer.release() }
                thread.quitSafely()
            }
        }
    }
}
