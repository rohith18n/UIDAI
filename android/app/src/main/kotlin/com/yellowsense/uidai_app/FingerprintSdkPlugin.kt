package com.yellowsense.uidai_app

import android.content.Context
import com.yellowsense.sdk.FingerprintAuthSdk
import com.yellowsense.sdk.iso.MinutiaPoint
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch

/**
 * Flutter Platform Channel Plugin bridging Dart calls to Native Kotlin SDK.
 */
class FingerprintSdkPlugin : FlutterPlugin, MethodChannel.MethodCallHandler {

    private lateinit var channel: MethodChannel
    private var sdk: FingerprintAuthSdk? = null
    private val scope = CoroutineScope(Dispatchers.Main)

    override fun onAttachedToEngine(flutterPluginBinding: FlutterPlugin.FlutterPluginBinding) {
        channel = MethodChannel(flutterPluginBinding.binaryMessenger, "com.yellowsense.uidai/fingerprint_sdk")
        channel.setMethodCallHandler(this)
        sdk = FingerprintAuthSdk(flutterPluginBinding.applicationContext)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "processImageOffline" -> {
                val imageBytes = call.argument<ByteArray>("imageBytes")
                if (imageBytes == null) {
                    result.error("INVALID_ARGUMENT", "imageBytes cannot be null", null)
                    return
                }

                scope.launch {
                    val pipelineResult = sdk?.processImageOffline(imageBytes)
                    if (pipelineResult != null) {
                        val resultMap = mapOf(
                            "success" to pipelineResult.success,
                            "mode" to "offline_on_device",
                            "message" to pipelineResult.message,
                            "total_execution_time_ms" to pipelineResult.totalExecutionTimeMs,
                            "execution_time_ms" to pipelineResult.totalExecutionTimeMs,
                            "is_finger_detected" to pipelineResult.isFingerDetected,
                            "blur_score" to pipelineResult.blurScore,
                            "brightness" to pipelineResult.brightness,
                            "glare_detected" to pipelineResult.glareDetected,
                            "is_live" to pipelineResult.isLive,
                            "liveness" to mapOf(
                                "is_live" to pipelineResult.isLive,
                                "confidence" to pipelineResult.livenessScore
                            ),
                            "liveness_score" to pipelineResult.livenessScore,
                            "minutiae_count" to pipelineResult.minutiaeCount,
                            "iso_template" to pipelineResult.isoTemplateBase64,
                            "cropped_image" to pipelineResult.croppedBase64,
                            "preprocessed_image" to pipelineResult.preprocessedBase64,
                            "visualization_image" to pipelineResult.visualizationBase64,
                            "images" to mapOf(
                                "original" to pipelineResult.originalBase64,
                                "cropped" to pipelineResult.croppedBase64,
                                "preprocessed" to pipelineResult.preprocessedBase64,
                                "visualization" to pipelineResult.visualizationBase64
                            ),
                            "guidance" to pipelineResult.guidance,
                            "minutiae" to pipelineResult.minutiaeList.map {
                                mapOf(
                                    "x" to it.x,
                                    "y" to it.y,
                                    "direction" to it.direction,
                                    "type" to it.type,
                                    "confidence" to it.quality
                                )
                            },
                            "minutiae_list" to pipelineResult.minutiaeList.map {
                                mapOf(
                                    "x" to it.x,
                                    "y" to it.y,
                                    "direction" to it.direction,
                                    "type" to it.type,
                                    "quality" to it.quality
                                )
                            }
                        )
                        result.success(resultMap)
                    } else {
                        result.error("SDK_ERROR", "Pipeline execution failed", null)
                    }
                }
            }

            "processSlapOffline" -> {
                val imageBytes = call.argument<ByteArray>("imageBytes")
                val handSide = call.argument<String>("handSide") ?: "right"
                if (imageBytes == null) {
                    result.error("INVALID_ARGUMENT", "imageBytes cannot be null", null)
                    return
                }

                scope.launch {
                    val slapResult = sdk?.processSlapOffline(imageBytes, handSide)
                    if (slapResult != null) {
                        val resultMap = mapOf(
                            "success" to slapResult.success,
                            "mode" to "offline_native_kotlin",
                            "message" to slapResult.message,
                            "hand_side" to slapResult.handSide,
                            "finger_count" to slapResult.fingerCount,
                            "total_minutiae" to slapResult.totalMinutiae,
                            "composite_b64" to slapResult.compositeBase64,
                            "total_execution_time_ms" to slapResult.totalExecutionTimeMs,
                            "execution_time_ms" to slapResult.totalExecutionTimeMs,
                            "fingers" to slapResult.fingers.map { f ->
                                mapOf(
                                    "finger_position" to f.fingerPosition,
                                    "position" to f.position,
                                    "iso_code" to f.isoCode,
                                    "detection_conf" to f.detectionConf,
                                    "minutiae_count" to f.minutiaeCount,
                                    "iso_template" to f.isoTemplateBase64,
                                    "template_b64" to f.isoTemplateBase64,
                                    "cropped_b64" to f.croppedBase64,
                                    "preprocessed_b64" to f.preprocessedBase64,
                                    "visualization_b64" to f.visualizationBase64,
                                    "execution_time_ms" to f.executionTimeMs,
                                    "liveness" to mapOf(
                                        "is_live" to f.isLive,
                                        "confidence" to f.livenessScore
                                    ),
                                    "minutiae" to f.minutiaeList.map { m ->
                                        mapOf(
                                            "x" to m.x,
                                            "y" to m.y,
                                            "direction" to m.direction,
                                            "type" to m.type,
                                            "confidence" to m.quality
                                        )
                                    }
                                )
                            }
                        )
                        result.success(resultMap)
                    } else {
                        result.error("SDK_ERROR", "Slap pipeline execution failed", null)
                    }
                }
            }

            "verifyOffline" -> {
                val minutiae1Raw = call.argument<List<Map<String, Any>>>("minutiae1")
                val minutiae2Raw = call.argument<List<Map<String, Any>>>("minutiae2")

                val m1 = parseMinutiae(minutiae1Raw)
                val m2 = parseMinutiae(minutiae2Raw)

                scope.launch {
                    val verResult = sdk?.verifyOffline(m1, m2)
                    if (verResult != null) {
                        val resultMap = mapOf(
                            "matched" to verResult.matched,
                            "confidence" to verResult.confidenceScore,
                            "match_count" to verResult.matchCount,
                            "execution_time_ms" to verResult.executionTimeMs,
                            "message" to verResult.message
                        )
                        result.success(resultMap)
                    } else {
                        result.error("MATCH_ERROR", "Verification failed", null)
                    }
                }
            }

            else -> result.notImplemented()
        }
    }

    private fun parseMinutiae(rawList: List<Map<String, Any>>?): List<MinutiaPoint> {
        if (rawList == null) return emptyList()
        return rawList.mapNotNull { map ->
            val x = (map["x"] as? Number)?.toInt() ?: return@mapNotNull null
            val y = (map["y"] as? Number)?.toInt() ?: return@mapNotNull null
            val dir = (map["direction"] as? Number)?.toDouble() ?: 0.0
            val type = (map["type"] as? String) ?: "RIG"
            val qual = (map["quality"] as? Number)?.toDouble() ?: 1.0
            MinutiaPoint(x, y, dir, type, qual)
        }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
        sdk?.close()
        sdk = null
    }
}
