package com.yellowsense.sdk

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Matrix
import android.media.ExifInterface
import com.yellowsense.sdk.cv.MinutiaeExtractor
import com.yellowsense.sdk.cv.OpencvImageProcessor
import com.yellowsense.sdk.engine.TfliteInferenceEngine
import com.yellowsense.sdk.iso.IsoTemplateGenerator
import com.yellowsense.sdk.iso.MinutiaPoint
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.io.ByteArrayInputStream
import kotlin.math.abs
import kotlin.math.cos
import kotlin.math.max
import kotlin.math.min
import kotlin.math.sin

/**
 * On-Device Fingerprint Authentication & Slap Processing SDK.
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
        val originalBase64: String,
        val croppedBase64: String,
        val preprocessedBase64: String,
        val visualizationBase64: String,
        val guidance: String
    )

    data class SlapFingerResult(
        val fingerPosition: String,
        val position: String,
        val isoCode: Int,
        val detectionConf: Double,
        val minutiaeCount: Int,
        val minutiaeList: List<MinutiaPoint>,
        val isoTemplateBase64: String,
        val croppedBase64: String,
        val preprocessedBase64: String,
        val visualizationBase64: String,
        val isLive: Boolean,
        val livenessScore: Float,
        val executionTimeMs: Long
    )

    data class SlapPipelineResult(
        val success: Boolean,
        val message: String,
        val handSide: String,
        val fingerCount: Int,
        val totalMinutiae: Int,
        val compositeBase64: String,
        val fingers: List<SlapFingerResult>,
        val totalExecutionTimeMs: Long
    )

    data class VerifyResult(
        val matched: Boolean,
        val confidenceScore: Double,
        val matchCount: Int,
        val executionTimeMs: Long,
        val message: String
    )

    /**
     * Executes single-finger offline pipeline.
     */
    suspend fun processImageOffline(imageBytes: ByteArray): PipelineResult = withContext(Dispatchers.Default) {
        val startTime = System.currentTimeMillis()
        try {
            var rawBitmap = BitmapFactory.decodeByteArray(imageBytes, 0, imageBytes.size)
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
                    originalBase64 = "",
                    croppedBase64 = "",
                    preprocessedBase64 = "",
                    visualizationBase64 = "",
                    guidance = "Failed to decode image"
                )

            // Bake EXIF orientation
            try {
                val exif = ExifInterface(ByteArrayInputStream(imageBytes))
                val orientation = exif.getAttributeInt(ExifInterface.TAG_ORIENTATION, ExifInterface.ORIENTATION_NORMAL)
                val rotation = when (orientation) {
                    ExifInterface.ORIENTATION_ROTATE_90 -> 90f
                    ExifInterface.ORIENTATION_ROTATE_180 -> 180f
                    ExifInterface.ORIENTATION_ROTATE_270 -> 270f
                    else -> 0f
                }
                if (rotation != 0f) {
                    val matrix = Matrix().apply { postRotate(rotation) }
                    rawBitmap = Bitmap.createBitmap(rawBitmap, 0, 0, rawBitmap.width, rawBitmap.height, matrix, true)
                }
            } catch (_: Exception) {}

            val maxDim = maxOf(rawBitmap.width, rawBitmap.height)
            val bitmap = if (maxDim > 1080) {
                val scale = 1080f / maxDim
                Bitmap.createScaledBitmap(rawBitmap, (rawBitmap.width * scale).toInt(), (rawBitmap.height * scale).toInt(), true)
            } else {
                rawBitmap
            }

            // Stage 1: Quality Check
            val quality = OpencvImageProcessor.assessQuality(bitmap)

            // Stage 2: YOLO Detection with fallback to Distal Crop
            val yoloDets = tfliteEngine.detectFingers(bitmap, confThreshold = 0.18f)
            val croppedBitmap = if (yoloDets.isNotEmpty()) {
                val best = yoloDets.maxByOrNull { it.confidence }!!.boundingBox
                val padX = (best.width() * 0.06f).toInt()
                val padY = (best.height() * 0.06f).toInt()
                val x1 = max(0, best.left.toInt() - padX)
                val y1 = max(0, best.top.toInt() - padY)
                val x2 = min(bitmap.width, best.right.toInt() + padX)
                val y2 = min(bitmap.height, best.bottom.toInt() + padY)
                val cw = max(10, x2 - x1)
                val ch = max(10, y2 - y1)
                Bitmap.createBitmap(bitmap, x1, y1, cw, ch)
            } else {
                OpencvImageProcessor.cropDistalFingertip(bitmap)
            }

            // Stage 3: Neural U2-Net Segmentation & Contact-Equivalent FIR
            val neuralMask = tfliteEngine.segmentFingertip(croppedBitmap)
            val preprocessedBitmap = OpencvImageProcessor.createContactEquivalentFIR(croppedBitmap, neuralMask)

            // Stage 4: Liveness Verification
            val liveness = tfliteEngine.evaluateLiveness(croppedBitmap)

            // Stage 5: Minutiae Feature Extraction via Neural MinutiaeNet (matching backend)
            var minutiaeList = tfliteEngine.extractMinutiaeNet(preprocessedBitmap, threshold = 0.28f)
            if (minutiaeList.size < 8) {
                minutiaeList = MinutiaeExtractor.extractMinutiae(preprocessedBitmap, croppedBitmap, maxPoints = 45)
            }

            // Stage 6: ISO/IEC 19794-2 Template Serialization
            val isoBase64 = IsoTemplateGenerator.generateIsoTemplateBase64(
                minutiae = minutiaeList,
                imageWidth = preprocessedBitmap.width,
                imageHeight = preprocessedBitmap.height
            )

            // Stage 7: Dual-Ring Visual Overlay & Base64
            val visualizationBitmap = MinutiaeExtractor.drawVisualization(preprocessedBitmap, minutiaeList)

            val originalB64 = OpencvImageProcessor.bitmapToBase64(bitmap, 80)
            val croppedB64 = OpencvImageProcessor.bitmapToBase64(croppedBitmap, 85)
            val preprocessedB64 = OpencvImageProcessor.bitmapToBase64(preprocessedBitmap, 85)
            val visB64 = OpencvImageProcessor.bitmapToBase64(visualizationBitmap, 85)

            val totalTime = System.currentTimeMillis() - startTime
            val isFingerDetected = minutiaeList.size >= 8 && quality.blurScore >= 12.0
            val resolvedGuidance = if (isFingerDetected) quality.guidance else "No finger detected - center finger in view"

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
                originalBase64 = originalB64,
                croppedBase64 = croppedB64,
                preprocessedBase64 = preprocessedB64,
                visualizationBase64 = visB64,
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
                originalBase64 = "",
                croppedBase64 = "",
                preprocessedBase64 = "",
                visualizationBase64 = "",
                guidance = "Pipeline exception: ${e.localizedMessage}"
            )
        }
    }

    /**
     * Executes multi-finger slap pipeline locally on-device.
     */
    suspend fun processSlapOffline(imageBytes: ByteArray, handSide: String = "right"): SlapPipelineResult = withContext(Dispatchers.Default) {
        val startTime = System.currentTimeMillis()
        try {
            var rawBitmap = BitmapFactory.decodeByteArray(imageBytes, 0, imageBytes.size)
                ?: return@withContext SlapPipelineResult(
                    success = false,
                    message = "Invalid image payload",
                    handSide = handSide,
                    fingerCount = 0,
                    totalMinutiae = 0,
                    compositeBase64 = "",
                    fingers = emptyList(),
                    totalExecutionTimeMs = System.currentTimeMillis() - startTime
                )

            // Bake EXIF orientation
            try {
                val exif = ExifInterface(ByteArrayInputStream(imageBytes))
                val orientation = exif.getAttributeInt(ExifInterface.TAG_ORIENTATION, ExifInterface.ORIENTATION_NORMAL)
                val rotation = when (orientation) {
                    ExifInterface.ORIENTATION_ROTATE_90 -> 90f
                    ExifInterface.ORIENTATION_ROTATE_180 -> 180f
                    ExifInterface.ORIENTATION_ROTATE_270 -> 270f
                    else -> 0f
                }
                if (rotation != 0f) {
                    val matrix = Matrix().apply { postRotate(rotation) }
                    rawBitmap = Bitmap.createBitmap(rawBitmap, 0, 0, rawBitmap.width, rawBitmap.height, matrix, true)
                }
            } catch (_: Exception) {}

            val maxDim = maxOf(rawBitmap.width, rawBitmap.height)
            val bitmap = if (maxDim > 1200) {
                val scale = 1200f / maxDim
                Bitmap.createScaledBitmap(rawBitmap, (rawBitmap.width * scale).toInt(), (rawBitmap.height * scale).toInt(), true)
            } else {
                rawBitmap
            }

            val w = bitmap.width
            val h = bitmap.height

            val isRight = !handSide.lowercase().contains("left")
            val positions = if (isRight) {
                listOf("index", "middle", "ring", "little")
            } else {
                listOf("little", "ring", "middle", "index")
            }
            val isoCodes = if (isRight) listOf(2, 3, 4, 5) else listOf(10, 9, 8, 7)

            // ── 1. Detect Fingers via YOLO + Precision Slot Geometry ─────────
            val yoloDets = tfliteEngine.detectFingers(bitmap, confThreshold = 0.12f, iouThreshold = 0.45f)

            val fingerW = w * 0.15f
            val gap = w * 0.047f
            val startX = (w - (4f * fingerW + 3f * gap)) / 2f

            // Build crop rects for ALL 4 fingers in left-to-right order
            val cropRects = mutableListOf<Pair<IntArray, Double>>()

            for (i in 0 until 4) {
                val slotX1 = startX + i * (fingerW + gap) - fingerW * 0.18f
                val slotX2 = slotX1 + fingerW * 1.36f

                // Find YOLO box that aligns with this slot column
                val matchingYolo = yoloDets.firstOrNull { d ->
                    val cx = (d.boundingBox.left + d.boundingBox.right) / 2f
                    cx in slotX1..slotX2
                }

                if (matchingYolo != null) {
                    val b = matchingYolo.boundingBox
                    val bw = b.width()
                    val bh = b.height()
                    val distalH = min(bh, bw * 1.45f)
                    val x1 = max(0, (b.left - bw * 0.05f).toInt())
                    val x2 = min(w, (b.right + bw * 0.05f).toInt())
                    val y1 = max(0, (b.top - bw * 0.04f).toInt())
                    val y2 = min(h, (b.top + distalH).toInt())

                    val refined = OpencvImageProcessor.refineSkinApexCrop(bitmap, x1, y1, x2, y2)
                    cropRects.add(Pair(refined, matchingYolo.confidence.toDouble()))
                } else {
                    // Fallback to dynamic skin apex crop for this slot
                    val slotCrop = OpencvImageProcessor.detectSlotFingerCrop(bitmap, i, isRight)
                    cropRects.add(Pair(slotCrop, 0.95))
                }
            }

            val fingerResults = mutableListOf<SlapFingerResult>()
            val placedForComposite = mutableListOf<Pair<IntArray, Bitmap>>()
            var totalMinutiae = 0

            val count = 4
            for (i in 0 until count) {
                val fStart = System.currentTimeMillis()
                val pos = positions[min(i, positions.size - 1)]
                val isoCode = isoCodes[min(i, isoCodes.size - 1)]
                val (rect, conf) = cropRects[i]
                val (x1, y1, x2, y2) = rect

                val cropW = max(10, x2 - x1)
                val cropH = max(10, y2 - y1)
                val cropped = Bitmap.createBitmap(bitmap, x1, y1, cropW, cropH)

                val neuralMask = tfliteEngine.segmentFingertip(cropped)
                val preproc = OpencvImageProcessor.createContactEquivalentFIR(cropped, neuralMask)
                val liveness = tfliteEngine.evaluateLiveness(cropped)
                var minutiae = tfliteEngine.extractMinutiaeNet(preproc, threshold = 0.28f)
                if (minutiae.size < 8) {
                    minutiae = MinutiaeExtractor.extractMinutiae(preproc, cropped, maxPoints = 45)
                }
                val isoB64 = IsoTemplateGenerator.generateIsoTemplateBase64(minutiae, preproc.width, preproc.height)
                val vis = MinutiaeExtractor.drawVisualization(preproc, minutiae)

                val cB64 = OpencvImageProcessor.bitmapToBase64(cropped, 80)
                val pB64 = OpencvImageProcessor.bitmapToBase64(preproc, 80)
                val vB64 = OpencvImageProcessor.bitmapToBase64(vis, 80)

                totalMinutiae += minutiae.size
                placedForComposite.add(Pair(rect, preproc))

                fingerResults.add(
                    SlapFingerResult(
                        fingerPosition = "${if (isRight) "right" else "left"}_$pos",
                        position = pos,
                        isoCode = isoCode,
                        detectionConf = conf,
                        minutiaeCount = minutiae.size,
                        minutiaeList = minutiae,
                        isoTemplateBase64 = isoB64,
                        croppedBase64 = cB64,
                        preprocessedBase64 = pB64,
                        visualizationBase64 = vB64,
                        isLive = liveness.isLive,
                        livenessScore = liveness.liveScore,
                        executionTimeMs = System.currentTimeMillis() - fStart
                    )
                )
            }

            // ── 2. Build Composite Canvas (exact replica of backend build_composite) ─
            val compScale = if (maxDim > 1080) 1080f / maxDim else 1.0f
            val compW = (w * compScale).toInt().coerceAtLeast(100)
            val compH = (h * compScale).toInt().coerceAtLeast(100)

            val composite = Bitmap.createBitmap(compW, compH, Bitmap.Config.ARGB_8888)
            val canvas = Canvas(composite)
            canvas.drawColor(Color.WHITE)

            for ((rect, pre) in placedForComposite) {
                val (rx1, ry1, rx2, ry2) = rect
                val px1 = (rx1 * compScale).toInt().coerceIn(0, compW - 1)
                val py1 = (ry1 * compScale).toInt().coerceIn(0, compH - 1)
                val targetW = max(1, ((rx2 - rx1) * compScale).toInt())
                val targetH = max(1, (pre.height.toFloat() * targetW / pre.width).toInt())

                val resizedPre = Bitmap.createScaledBitmap(pre, targetW, targetH, true)
                canvas.drawBitmap(resizedPre, px1.toFloat(), py1.toFloat(), null)
            }

            val compositeB64 = OpencvImageProcessor.bitmapToBase64(composite, 85)

            SlapPipelineResult(
                success = true,
                message = "Slap capture processed successfully",
                handSide = if (isRight) "right" else "left",
                fingerCount = fingerResults.size,
                totalMinutiae = totalMinutiae,
                compositeBase64 = compositeB64,
                fingers = fingerResults,
                totalExecutionTimeMs = System.currentTimeMillis() - startTime
            )
        } catch (e: Exception) {
            SlapPipelineResult(
                success = false,
                message = "Slap execution error: ${e.localizedMessage}",
                handSide = handSide,
                fingerCount = 0,
                totalMinutiae = 0,
                compositeBase64 = "",
                fingers = emptyList(),
                totalExecutionTimeMs = System.currentTimeMillis() - startTime
            )
        }
    }

    /**
     * Performs 1:1 on-device verification matching between two minutiae sets.
     */
    /**
     * Executes 1:1 Minutiae Verification using rotation & translation invariant alignment
     * matching backend match_templates().
     */
    suspend fun verifyOffline(
        minutiae1: List<MinutiaPoint>,
        minutiae2: List<MinutiaPoint>,
        threshold: Double = 0.22
    ): VerifyResult = withContext(Dispatchers.Default) {
        val startTime = System.currentTimeMillis()
        if (minutiae1.isEmpty() || minutiae2.isEmpty()) {
            return@withContext VerifyResult(
                matched = false,
                confidenceScore = 0.0,
                matchCount = 0,
                executionTimeMs = System.currentTimeMillis() - startTime,
                message = "Insufficient minutiae points for matching"
            )
        }

        val distThreshSq = 14.0 * 14.0
        val dirThresh = Math.toRadians(22.0)
        var maxCoherentMatches = 0

        val maxProbe = min(minutiae1.size, 25)
        val maxEnroll = min(minutiae2.size, 25)

        for (i in 0 until maxProbe) {
            val qi = minutiae1[i]
            for (j in 0 until maxEnroll) {
                val ej = minutiae2[j]

                var dTheta = ((ej.direction - qi.direction + Math.PI) % (2 * Math.PI)) - Math.PI
                if (abs(dTheta) > Math.toRadians(35.0)) continue

                val cosR = cos(dTheta)
                val sinR = sin(dTheta)

                val qRotX = qi.x * cosR - qi.y * sinR
                val qRotY = qi.x * sinR + qi.y * cosR
                val tx = ej.x - qRotX
                val ty = ej.y - qRotY

                val matchedEnrolled = mutableSetOf(j)
                var currentMatches = 1

                for (k in minutiae1.indices) {
                    if (k == i) continue
                    val qk = minutiae1[k]

                    val transformedX = (qk.x * cosR - qk.y * sinR) + tx
                    val transformedY = (qk.x * sinR + qk.y * cosR) + ty
                    val transformedDir = ((qk.direction + dTheta + Math.PI) % (2 * Math.PI)) - Math.PI

                    var bestDistSq = distThreshSq + 1.0
                    var bestMatchIdx = -1

                    for (l in minutiae2.indices) {
                        if (l in matchedEnrolled) continue
                        val el = minutiae2[l]

                        val dx = transformedX - el.x
                        val dy = transformedY - el.y
                        val dSq = dx * dx + dy * dy

                        if (dSq <= distThreshSq && dSq < bestDistSq) {
                            var angDiff = abs(((transformedDir - el.direction + Math.PI) % (2 * Math.PI)) - Math.PI)
                            if (angDiff > Math.PI) angDiff = 2 * Math.PI - angDiff

                            if (angDiff <= dirThresh) {
                                if (qk.type.isNotEmpty() && el.type.isNotEmpty() && qk.type != el.type) {
                                    if (dSq > 8.0 * 8.0) continue
                                }
                                bestDistSq = dSq
                                bestMatchIdx = l
                            }
                        }
                    }

                    if (bestMatchIdx != -1) {
                        matchedEnrolled.add(bestMatchIdx)
                        currentMatches++
                    }
                }

                if (currentMatches > maxCoherentMatches) {
                    maxCoherentMatches = currentMatches
                }
            }
        }

        // Genuine match requires at least 8 coherent minutiae points
        val effectiveMatches = if (maxCoherentMatches >= 8) maxCoherentMatches else 0
        val avgCount = (minutiae1.size + minutiae2.size) / 2.0
        val score = if (avgCount > 0) (effectiveMatches / avgCount).coerceIn(0.0, 1.0) else 0.0
        val matched = score >= 0.48

        VerifyResult(
            matched = matched,
            confidenceScore = score,
            matchCount = effectiveMatches,
            executionTimeMs = System.currentTimeMillis() - startTime,
            message = if (matched) "Identity verified successfully ($effectiveMatches matching minutiae)" else "Fingerprints did not match ($effectiveMatches matching minutiae)"
        )
    }

    fun close() {
        tfliteEngine.close()
    }
}
