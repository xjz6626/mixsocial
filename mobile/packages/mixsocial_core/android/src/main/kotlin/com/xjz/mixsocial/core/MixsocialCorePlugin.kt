package com.xjz.mixsocial.core

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.os.Handler
import android.os.Looper
import com.xjz.mixsocial.go.mobilecore.Mobilecore
import com.xjz.mixsocial.go.mobilecore.Tieba
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import java.net.HttpURLConnection
import java.net.URL
import java.util.concurrent.Executors
import org.json.JSONArray
import org.json.JSONObject

class MixsocialCorePlugin : FlutterPlugin, MethodChannel.MethodCallHandler {
    private lateinit var channel: MethodChannel
    private val executor = Executors.newCachedThreadPool()
    private val mediaExecutor = Executors.newFixedThreadPool(4)
    private val mainHandler = Handler(Looper.getMainLooper())
    @Volatile private var tieba: Tieba? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel = MethodChannel(binding.binaryMessenger, "mixsocial/core")
        channel.setMethodCallHandler(this)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        if (call.method == "tieba.cancel") {
            val requestId = (call.arguments as? Map<*, *>)?.get("requestId")?.toString().orEmpty()
            tieba?.cancel(requestId)
            result.success(null)
            return
        }
        val selectedExecutor = if (call.method == "media.fetchImage") mediaExecutor else executor
        selectedExecutor.execute {
            try {
                val value: Any? = when (call.method) {
                    "tieba.configure" -> {
                        val arguments = call.arguments as? Map<*, *> ?: emptyMap<String, Any>()
                        val forums = arguments["forums"] as? List<*> ?: emptyList<Any>()
                        val config = JSONObject()
                            .put("forums", JSONArray(forums))
                            .put("timeout", arguments["timeout"]?.toString() ?: "45s")
                        tieba?.close()
                        tieba = Mobilecore.newTieba(config.toString())
                        null
                    }
                    "tieba.browse" -> {
                        val arguments = arguments(call)
                        requireTieba().browseWithRequest(
                            arguments["requestId"]?.toString() ?: "",
                            arguments["channel"]?.toString() ?: "recommend",
                            arguments["cursor"]?.toString() ?: "",
                        )
                    }
                    "tieba.search" -> {
                        val arguments = arguments(call)
                        requireTieba().searchWithRequest(
                            arguments["requestId"]?.toString() ?: "",
                            arguments["query"]?.toString() ?: "",
                            arguments["cursor"]?.toString() ?: "",
                        )
                    }
                    "tieba.forum" -> {
                        val arguments = arguments(call)
                        requireTieba().forumWithRequest(
                            arguments["requestId"]?.toString() ?: "",
                            arguments["forum"]?.toString() ?: "",
                            arguments["cursor"]?.toString() ?: "",
                            (arguments["sortType"] as? Number)?.toLong() ?: 0L,
                        )
                    }
                    "tieba.searchForum" -> {
                        val arguments = arguments(call)
                        requireTieba().searchForumWithRequest(
                            arguments["requestId"]?.toString() ?: "",
                            arguments["forum"]?.toString() ?: "",
                            arguments["query"]?.toString() ?: "",
                            arguments["cursor"]?.toString() ?: "",
                        )
                    }
                    "tieba.followingForums" -> {
                        val arguments = arguments(call)
                        requireTieba().followingForumsWithRequest(
                            arguments["requestId"]?.toString() ?: "",
                        )
                    }
                    "tieba.detail" -> {
                        val arguments = arguments(call)
                        requireTieba().detailWithRequest(
                            arguments["requestId"]?.toString() ?: "",
                            arguments["ref"]?.toString() ?: "{}",
                        )
                    }
                    "tieba.detailPage" -> {
                        val arguments = arguments(call)
                        requireTieba().detailPageWithRequest(
                            arguments["requestId"]?.toString() ?: "",
                            arguments["ref"]?.toString() ?: "{}",
                            arguments["cursor"]?.toString() ?: "",
                            arguments["reverse"] as? Boolean ?: false,
                            arguments["onlyOriginalPoster"] as? Boolean ?: false,
                        )
                    }
                    "tieba.floorReplies" -> {
                        val arguments = arguments(call)
                        requireTieba().floorRepliesWithRequest(
                            arguments["requestId"]?.toString() ?: "",
                            arguments["ref"]?.toString() ?: "{}",
                            arguments["cursor"]?.toString() ?: "",
                        )
                    }
                    "tieba.login" -> {
                        val arguments = arguments(call)
                        requireTieba().loginWithCredentialRequest(
                            arguments["requestId"]?.toString() ?: "",
                            arguments["credential"]?.toString() ?: "",
                        )
                    }
                    "tieba.clearCredential" -> {
                        requireTieba().clearCredential()
                        null
                    }
                    "media.fetchImage" -> fetchImage(arguments(call))
                    else -> {
                        mainHandler.post { result.notImplemented() }
                        return@execute
                    }
                }
                mainHandler.post { result.success(value) }
            } catch (error: Throwable) {
                mainHandler.post {
                    result.error(errorCode(error), error.message ?: error.javaClass.simpleName, null)
                }
            }
        }
    }

    private fun arguments(call: MethodCall): Map<*, *> =
        call.arguments as? Map<*, *> ?: throw IllegalArgumentException("${call.method} requires arguments")

    private fun errorCode(error: Throwable): String {
        val message = error.message.orEmpty().lowercase()
        return when {
            "context canceled" in message || "cancelled" in message -> "CANCELLED"
            "deadline exceeded" in message || "timeout" in message || "超时" in message -> "TIMEOUT"
            error is IllegalArgumentException || "invalid" in message || "不能为空" in message -> "INVALID_ARGUMENT"
            "登录" in message || "bduss" in message || "credential" in message -> "AUTH"
            else -> "CORE"
        }
    }

    private fun requireTieba(): Tieba = tieba ?: throw IllegalStateException("Tieba core is not configured")

    private fun fetchImage(arguments: Map<*, *>): ByteArray {
        val rawUrl = arguments["url"]?.toString().orEmpty()
        require(rawUrl.startsWith("https://") || rawUrl.startsWith("http://")) {
            "无效的媒体地址"
        }
        val headers = arguments["headers"] as? Map<*, *> ?: emptyMap<String, String>()
        val maxDimension = ((arguments["maxDimension"] as? Number)?.toInt() ?: 2048)
            .coerceIn(256, 4096)
        val downloaded = download(rawUrl, headers)
        return normalizeImage(downloaded, maxDimension)
    }

    private fun download(rawUrl: String, headers: Map<*, *>): ByteArray {
        var current = rawUrl
        repeat(6) { redirectCount ->
            val connection = URL(current).openConnection() as HttpURLConnection
            try {
                connection.instanceFollowRedirects = false
                connection.connectTimeout = 15_000
                connection.readTimeout = 30_000
                connection.useCaches = true
                connection.setRequestProperty("Accept-Encoding", "identity")
                headers.forEach { (key, value) ->
                    if (key != null && value != null) {
                        connection.setRequestProperty(key.toString(), value.toString())
                    }
                }
                val status = connection.responseCode
                if (status in 300..399) {
                    val location = connection.getHeaderField("Location")
                        ?: error("媒体重定向缺少地址（HTTP $status）")
                    current = URL(URL(current), location).toString()
                    require(current.startsWith("https://") || current.startsWith("http://")) {
                        "媒体重定向到了不支持的协议"
                    }
                    if (redirectCount == 5) error("媒体重定向次数过多")
                    return@repeat
                }
                if (status !in 200..299) {
                    error("媒体服务器返回 HTTP $status")
                }
                val declaredLength = connection.contentLengthLong
                if (declaredLength > MAX_IMAGE_BYTES) {
                    error("媒体文件过大（${declaredLength / 1024 / 1024} MB）")
                }
                connection.inputStream.use { input ->
                    val output = ByteArrayOutputStream(
                        if (declaredLength > 0 && declaredLength <= Int.MAX_VALUE.toLong()) {
                            declaredLength.toInt()
                        } else {
                            64 * 1024
                        },
                    )
                    val buffer = ByteArray(32 * 1024)
                    var total = 0L
                    while (true) {
                        val read = input.read(buffer)
                        if (read < 0) break
                        total += read
                        if (total > MAX_IMAGE_BYTES) error("媒体文件超过 25 MB")
                        output.write(buffer, 0, read)
                    }
                    if (total == 0L) error("媒体服务器返回了空文件")
                    return output.toByteArray()
                }
            } finally {
                connection.disconnect()
            }
        }
        error("媒体重定向失败")
    }

    private fun normalizeImage(source: ByteArray, maxDimension: Int): ByteArray {
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeByteArray(source, 0, source.size, bounds)
        if (bounds.outWidth <= 0 || bounds.outHeight <= 0) {
            error("Android 无法解码该图片")
        }

        var sampleSize = 1
        while (bounds.outWidth / sampleSize > maxDimension * 2 ||
            bounds.outHeight / sampleSize > maxDimension * 2
        ) {
            sampleSize *= 2
        }
        val options = BitmapFactory.Options().apply {
            inSampleSize = sampleSize
            inPreferredConfig = Bitmap.Config.ARGB_8888
        }
        var bitmap = BitmapFactory.decodeByteArray(source, 0, source.size, options)
            ?: error("Android 无法解码该图片")
        try {
            val longest = maxOf(bitmap.width, bitmap.height)
            if (longest > maxDimension) {
                val scale = maxDimension.toFloat() / longest.toFloat()
                val scaled = Bitmap.createScaledBitmap(
                    bitmap,
                    (bitmap.width * scale).toInt().coerceAtLeast(1),
                    (bitmap.height * scale).toInt().coerceAtLeast(1),
                    true,
                )
                if (scaled !== bitmap) {
                    bitmap.recycle()
                    bitmap = scaled
                }
            }
            val output = ByteArrayOutputStream()
            val format = if (bitmap.hasAlpha()) Bitmap.CompressFormat.PNG else Bitmap.CompressFormat.JPEG
            val quality = if (format == Bitmap.CompressFormat.JPEG) 92 else 100
            check(bitmap.compress(format, quality, output)) { "Android 无法转换该图片" }
            return output.toByteArray()
        } finally {
            bitmap.recycle()
        }
    }

    private companion object {
        const val MAX_IMAGE_BYTES = 25L * 1024L * 1024L
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
        tieba?.close()
        tieba = null
        executor.shutdownNow()
        mediaExecutor.shutdownNow()
    }
}
