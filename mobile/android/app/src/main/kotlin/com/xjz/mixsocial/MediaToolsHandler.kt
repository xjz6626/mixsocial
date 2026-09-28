package com.xjz.mixsocial

import android.app.Activity
import android.content.ClipData
import android.content.Intent
import android.graphics.BitmapFactory
import android.net.Uri
import android.os.Handler
import android.os.Looper
import androidx.core.content.FileProvider
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.net.HttpURLConnection
import java.net.URI
import java.util.UUID
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean

/** Narrow, user-initiated media actions, isolated from platform account cookies. */
class MediaToolsHandler(private val activity: Activity, messenger: BinaryMessenger) {
    private val channel = MethodChannel(messenger, "mixsocial/media_tools")
    private val worker = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())
    private val busy = AtomicBoolean(false)
    private var closed = false
    private var ready = false
    private val pendingLinks = ArrayDeque<Map<String, String>>()
    private var pendingSave: Pair<File, MethodChannel.Result>? = null
    private val directory get() = File(activity.cacheDir, "mixsocial_share").apply { mkdirs() }

    init { channel.setMethodCallHandler(::handle) }

    fun receiveIntent(intent: Intent?) {
        val text = try {
            when (intent?.action) {
                Intent.ACTION_SEND -> if (intent.type == "text/plain") {
                    intent.getStringExtra(Intent.EXTRA_TEXT)
                } else null
                Intent.ACTION_VIEW -> intent.dataString
                else -> null
            }
        } catch (_: Exception) { null } ?: return
        if (text.length > 65536) return
        val event = mapOf("id" to UUID.randomUUID().toString(), "text" to text)
        if (ready) channel.invokeMethod("incomingLink", event)
        else {
            if (pendingLinks.size >= 8) pendingLinks.removeFirst()
            pendingLinks.addLast(event)
        }
    }

    private fun handle(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "initialLink" -> {
                    ready = true
                    result.success(if (pendingLinks.isEmpty()) null else pendingLinks.removeFirst())
                    while (pendingLinks.isNotEmpty()) channel.invokeMethod("incomingLink", pendingLinks.removeFirst())
                }
                "shareText" -> {
                    val text = requireNotNull(call.argument<String>("text"))
                    require(text.isNotBlank() && text.length <= 131072)
                    val intent = Intent(Intent.ACTION_SEND).apply {
                        type = "text/plain"
                        putExtra(Intent.EXTRA_TEXT, text)
                    }
                    activity.startActivity(Intent.createChooser(intent, "分享"))
                    result.success(null)
                }
                "shareTextFile" -> exclusive(result) {
                    val text = requireNotNull(call.argument<String>("text"))
                    val name = requireNotNull(call.argument<String>("fileName"))
                    val mime = requireNotNull(call.argument<String>("mimeType"))
                    require(name.matches(Regex("^[a-zA-Z0-9][a-zA-Z0-9._-]{0,79}$")))
                    require(mime == "application/json" || mime == "text/plain")
                    val bytes = text.toByteArray(Charsets.UTF_8)
                    require(bytes.size <= 4 * 1024 * 1024)
                    val file = File(directory, "${UUID.randomUUID()}-$name")
                    file.writeBytes(bytes)
                    pruneCache(file)
                    main.post { finishShare(file, mime, result) }
                }
                "saveImage", "shareImage" -> exclusive(result) {
                    val source = requireNotNull(call.argument<String>("source"))
                    val urls = requireNotNull(call.argument<List<String>>("urls"))
                    require(urls.size in 1..3)
                    var image: Pair<File, String>? = null
                    for (url in urls) {
                        try { image = downloadImage(url, source); break } catch (_: Exception) { }
                    }
                    val downloaded = image ?: throw IllegalStateException("下载失败")
                    pruneCache(downloaded.first)
                    main.post {
                        if (closed) { downloaded.first.delete(); busy.set(false); return@post }
                        if (call.method == "shareImage") finishShare(downloaded.first, downloaded.second, result)
                        else {
                            try {
                                pendingSave = downloaded.first to result
                                activity.startActivityForResult(Intent(Intent.ACTION_CREATE_DOCUMENT).apply {
                                    addCategory(Intent.CATEGORY_OPENABLE)
                                    type = downloaded.second
                                    putExtra(Intent.EXTRA_TITLE, downloaded.first.name)
                                }, SAVE_REQUEST)
                            } catch (_: Exception) {
                                pendingSave = null
                                downloaded.first.delete()
                                busy.set(false)
                                result.error("save_failed", "无法打开系统保存位置选择器", null)
                            }
                        }
                    }
                }
                "resolveLink" -> worker.execute {
                    try {
                        val url = requireNotNull(call.argument<String>("url"))
                        var uri = URI(url)
                        require(uri.host == "xhslink.com")
                        val deadline = System.nanoTime() + 20_000_000_000L
                        repeat(6) {
                            require(System.nanoTime() < deadline)
                            require(validLink(uri))
                            if (uri.host != "xhslink.com" && uri.path.matches(Regex("^/(explore|discovery/item)/[a-fA-F0-9]{24}/?$"))) {
                                main.post { result.success(uri.toString()) }; return@execute
                            }
                            val connection = connect(uri)
                            try {
                                val code = connection.responseCode
                                require(code in 300..399)
                                uri = uri.resolve(requireNotNull(connection.getHeaderField("Location")))
                            } finally { connection.disconnect() }
                        }
                        throw IllegalStateException("redirect limit")
                    } catch (_: Exception) {
                        main.post { result.error("resolve_failed", "短链接未能解析，请复制完整笔记链接", null) }
                    }
                }
                "cacheBytes" -> worker.execute {
                    val bytes = directory.listFiles()?.filter { it.isFile }?.sumOf { it.length() } ?: 0L
                    main.post { result.success(bytes) }
                }
                "clearCache" -> exclusive(result) {
                    var failed = false
                    directory.listFiles()?.filter { it.isFile }?.forEach { if (!it.delete()) failed = true }
                    main.post {
                        busy.set(false)
                        if (failed) result.error("cache_failed", "部分临时图片仍被使用，请稍后重试", null)
                        else result.success(null)
                    }
                }
                else -> result.notImplemented()
            }
        } catch (_: Exception) { result.error("invalid_argument", "操作参数无效", null) }
    }

    private fun exclusive(result: MethodChannel.Result, action: () -> Unit) {
        if (!busy.compareAndSet(false, true)) {
            result.error("busy", "另一项保存、分享或清理操作尚未完成", null)
            return
        }
        worker.execute {
            try { action() } catch (_: Exception) {
                busy.set(false)
                main.post { result.error("media_failed", "操作失败，请检查网络或图片地址后重试", null) }
            }
        }
    }

    private fun connect(uri: URI): HttpURLConnection {
        val connection = uri.toURL().openConnection() as HttpURLConnection
        connection.instanceFollowRedirects = false
        connection.connectTimeout = 8000
        connection.readTimeout = 8000
        connection.useCaches = false
        connection.setRequestProperty("Cookie", "")
        connection.setRequestProperty("User-Agent", "Mozilla/5.0 (Linux; Android 15) AppleWebKit/537.36 Chrome/131.0.0.0 Mobile Safari/537.36")
        return connection
    }

    private fun validBase(uri: URI): Boolean = uri.scheme == "https" && uri.userInfo == null &&
        (uri.port == -1 || uri.port == 443) && uri.toString().length <= 8192

    private fun validLink(uri: URI): Boolean = validBase(uri) &&
        uri.host in setOf("xhslink.com", "www.xiaohongshu.com", "xiaohongshu.com")

    private fun validImage(uri: URI, source: String): Boolean {
        if (!validBase(uri)) return false
        val host = uri.host ?: return false
        val domains = when (source) {
            "xhs" -> listOf("xhscdn.com", "xiaohongshu.com")
            "tieba" -> listOf("baidu.com", "bdimg.com", "bdstatic.com", "bcebos.com")
            "zhihu" -> listOf("zhimg.com", "zhihu.com")
            else -> return false
        }
        return domains.any { host == it || host.endsWith(".$it") }
    }

    private fun downloadImage(url: String, source: String): Pair<File, String> {
        var uri = URI(url)
        val deadline = System.nanoTime() + 30_000_000_000L
        repeat(4) {
            require(validImage(uri, source))
            require(System.nanoTime() < deadline)
            val connection = connect(uri)
            connection.setRequestProperty("Accept", "image/jpeg,image/png,image/webp,image/gif")
            connection.setRequestProperty("Referer", when (source) {
                "xhs" -> "https://www.xiaohongshu.com/"
                "zhihu" -> "https://www.zhihu.com/"
                else -> "https://tieba.baidu.com/"
            })
            var partial: File? = null
            try {
                val code = connection.responseCode
                if (code in 300..399) {
                    uri = uri.resolve(requireNotNull(connection.getHeaderField("Location")))
                } else {
                    require(code == 200)
                    val declared = connection.contentType?.substringBefore(';')?.lowercase()
                    require(declared in setOf("image/jpeg", "image/png", "image/webp", "image/gif", "application/octet-stream"))
                    require(connection.contentLengthLong <= MAX_IMAGE_BYTES)
                    partial = File(directory, "${UUID.randomUUID()}.part")
                    connection.inputStream.use { input -> partial.outputStream().use { output ->
                        val buffer = ByteArray(32768)
                        var total = 0L
                        while (true) {
                            require(System.nanoTime() < deadline)
                            val count = input.read(buffer)
                            if (count < 0) break
                            total += count
                            require(total <= MAX_IMAGE_BYTES)
                            output.write(buffer, 0, count)
                        }
                    } }
                    val options = BitmapFactory.Options().apply { inJustDecodeBounds = true }
                    BitmapFactory.decodeFile(partial.absolutePath, options)
                    require(options.outWidth > 0 && options.outHeight > 0)
                    require(options.outWidth.toLong() * options.outHeight <= 150_000_000L)
                    val extension = when (options.outMimeType) {
                        "image/jpeg" -> "jpg"
                        "image/png" -> "png"
                        "image/webp" -> "webp"
                        "image/gif" -> "gif"
                        else -> throw IllegalArgumentException("unsupported image")
                    }
                    val file = File(directory, "mixsocial-${UUID.randomUUID()}.$extension")
                    require(partial.renameTo(file))
                    return file to options.outMimeType
                }
            } finally { partial?.delete(); connection.disconnect() }
        }
        throw IllegalArgumentException("redirect limit")
    }

    private fun pruneCache(keep: File) {
        val files = directory.listFiles()?.filter { it.isFile && it != keep }?.sortedBy { it.lastModified() } ?: return
        var total = files.sumOf { it.length() } + keep.length()
        val cutoff = System.currentTimeMillis() - 86_400_000L
        for (file in files) {
            if (file.lastModified() < cutoff || total > 96 * 1024 * 1024) {
                val length = file.length()
                if (file.delete()) total -= length
            }
        }
    }

    private fun finishShare(file: File, mime: String, result: MethodChannel.Result) {
        try {
            if (closed) return
            val uri = FileProvider.getUriForFile(activity, "${activity.packageName}.media_files", file)
            activity.startActivity(Intent.createChooser(Intent(Intent.ACTION_SEND).apply {
                type = mime
                putExtra(Intent.EXTRA_STREAM, uri)
                clipData = ClipData.newRawUri("Mixsocial", uri)
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            }, "分享"))
            result.success(null)
        } catch (_: Exception) { result.error("share_failed", "无法打开系统分享面板", null) }
        finally { busy.set(false) }
    }

    fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode != SAVE_REQUEST) return false
        val pending = pendingSave ?: return true
        pendingSave = null
        val (file, result) = pending
        val uri = data?.data
        if (resultCode != Activity.RESULT_OK || uri == null || uri.scheme != "content") {
            file.delete(); busy.set(false)
            result.error("cancelled", "已取消保存", null)
            return true
        }
        worker.execute {
            try {
                requireNotNull(activity.contentResolver.openOutputStream(uri, "w")).use { output -> file.inputStream().use { it.copyTo(output) } }
                main.post { result.success(null) }
            } catch (_: Exception) { main.post { result.error("save_failed", "写入失败，请重新选择保存位置", null) } }
            finally { file.delete(); busy.set(false) }
        }
        return true
    }

    fun close() {
        closed = true
        channel.setMethodCallHandler(null)
        pendingSave?.first?.delete()
        pendingSave = null
        worker.shutdownNow()
    }

    companion object {
        private const val SAVE_REQUEST = 27183
        private const val MAX_IMAGE_BYTES = 20L * 1024 * 1024
    }
}
