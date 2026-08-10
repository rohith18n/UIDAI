package com.yellowsense.sdk

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.util.Base64
import com.yellowsense.sdk.cv.MinutiaeExtractor
import com.yellowsense.sdk.cv.OpencvImageProcessor
import com.yellowsense.sdk.engine.TfliteInferenceEngine
import com.yellowsense.sdk.iso.IsoTemplateGenerator
import com.yellowsense.sdk.iso.MinutiaPoint
import com.yellowsense.sdk.matcher.MinutiaeMatcher
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/**
 * Main Façade Class for YellowSense UIDAI Offline On-Device Fingerprint SDK.
 */
class FingerprintAuthSdk(private val context: Context) {

    private val tfliteEngine = TfliteInferenceEngine(context)

    data class PipelineResult(
        val success: Boolean,
        val message: String,
        val totalExecutionTimeMs: Long,
        val isFingerDetected: Boolean,
        val blurScore: Double,
        val brightness: Double,
        val glareDetected: Boolean,
        val isLive: Boolean,
        val livenessScore: Float,
        val minutiaeCount: Int,
        val minutiaeList: List<MinutiaPoint>,
        val isoTemplateBase64: String,
        val croppedBase64: String,
        val preprocessedBase64: String,
        val guidance: String
    )

    data class VerificationResult(
        val matched: Boolean,
        val confidenceScore: Double,
        val matchCount: Int,
        val executionTimeMs: Long,
        val message: String
    )

    /**
     * Executes complete 7-stage fingerprint pipeline locally on-device in < 5s total time.
     */
    suspend fun processImageOffline(imageBytes: ByteArray): PipelineResult = withContext(Dispatchers.Default) {
        val startTime = System.currentTimeMillis()

        try {
            val bitmap = BitmapFactory.decodeByteArray(imageBytes, 0, imageBytes.size)
                ?: return@withContext PipelineResult(
                    success = false,
                    message = "Invalid image payload",
                    totalExecutionTimeMs = System.currentTimeMillis() - startTime,
                    isFingerDetected = false,
                    blurScore = 0.0,
                    brightness = 0.0,
                    glareDetected = false,
                    isLive = false,
                    livenessScore = 0.0f,
                    minutiaeCount = 0,
                    minutiaeList = emptyList(),
                    isoTemplateBase64 = "",
                    croppedBase64 = "",
                    preprocessedBase64 = "",
                    guidance = "Failed to decode image"
                )

            // Stage 1: Quality Check (Blur, Brightness, Glare)
            val quality = OpencvImageProcessor.assessQuality(bitmap)

            // Stage 2: ROI Alignment
            val roi = OpencvImageProcessor.checkRoiAlignment(
                bitmap,
                bitmap.width / 2.0f,
                bitmap.height / 2.0f
            )

            // Stage 3: Enhancement & Preprocessing
            val enhancedBitmap = OpencvImageProcessor.enhanceContrast(bitmap)

            // Stage 4: Liveness Verification
            val liveness = tfliteEngine.evaluateLiveness(bitmap)

            // Stage 5: Minutiae Feature Extraction
            val minutiaeList = MinutiaeExtractor.extractMinutiae(enhancedBitmap)

            // Stage 6: ISO/IEC 19794-4 Template Export
            val isoBase64 = IsoTemplateGenerator.generateIsoTemplateBase64(
                minutiae = minutiaeList,
                imageWidth = bitmap.width,
                imageHeight = bitmap.height
            )

            // Stage 7: Base64 Conversions for UI Visualization
            val croppedB64 = OpencvImageProcessor.bitmapToBase64(bitmap, 80)
            val preprocessedB64 = OpencvImageProcessor.bitmapToBase64(enhancedBitmap, 80)

            val totalTime = System.currentTimeMillis() - startTime
            val isFingerDetected = minutiaeList.size >= 8 && quality.blurScore >= 20.0
            val resolvedGuidance = if (isFingerDetected) quality.guidance else "No finger detected - place finger inside oval"

            PipelineResult(
                success = true,
                message = if (isFingerDetected) "Offline pipeline execution successful" else "No finger detected in capture",
                totalExecutionTimeMs = totalTime,
                isFingerDetected = isFingerDetected,
                blurScore = quality.blurScore,
                brightness = quality.brightness,
                glareDetected = quality.glareDetected,
                isLive = liveness.isLive,
                livenessScore = liveness.liveScore,
                minutiaeCount = minutiaeList.size,
                minutiaeList = minutiaeList,
                isoTemplateBase64 = isoBase64,
                croppedBase64 = croppedB64,
                preprocessedBase64 = preprocessedB64,
                guidance = resolvedGuidance
            )
        } catch (e: Exception) {
            PipelineResult(
                success = false,
                message = "Execution error: ${e.localizedMessage}",
                totalExecutionTimeMs = System.currentTimeMillis() - startTime,
                isFingerDetected = false,
                blurScore = 0.0,
                brightness = 0.0,
                glareDetected = false,
                isLive = false,
                livenessScore = 0.0f,
                minutiaeCount = 0,
                minutiaeList = emptyList(),
                isoTemplateBase64 = "",
                croppedBase64 = "",
                preprocessedBase64 = "",
                guidance = "Pipeline exception: ${e.localizedMessage}"
            )
        }
    }

    /**
     * Performs 1:1 on-device verification matching between two minutiae sets.
     */
    suspend fun verifyOffline(
        minutiae1: List<MinutiaPoint>,
        minutiae2: List<MinutiaPoint>
    ): VerificationResult = withContext(Dispatchers.Default) {
        val matchResult = MinutiaeMatcher.compareTemplates(minutiae1, minutiae2)
        VerificationResult(
            matched = matchResult.isMatch,
            confidenceScore = matchResult.score,
            matchCount = matchResult.matchCount,
            executionTimeMs = matchResult.executionTimeMs,
            message = if (matchResult.isMatch) "Identity Verified" else "Mismatch"
        )
    }

    fun close() {
        tfliteEngine.close()
    }
}
