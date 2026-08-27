package com.xjz.mixsocial.core

import android.os.Handler
import android.os.Looper
import com.xjz.mixsocial.go.mobilecore.Mobilecore
import com.xjz.mixsocial.go.mobilecore.Tieba
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executors
import org.json.JSONArray
import org.json.JSONObject

class MixsocialCorePlugin : FlutterPlugin, MethodChannel.MethodCallHandler {
    private lateinit var channel: MethodChannel
    private val executor = Executors.newCachedThreadPool()
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
        executor.execute {
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
                    "tieba.detail" -> {
                        val arguments = arguments(call)
                        requireTieba().detailWithRequest(
                            arguments["requestId"]?.toString() ?: "",
                            arguments["ref"]?.toString() ?: "{}",
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

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
        tieba?.close()
        tieba = null
        executor.shutdownNow()
    }
}
