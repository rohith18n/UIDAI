package com.yellowsense.sdk.cv

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Color
import java.io.ByteArrayOutputStream
import kotlin.math.abs
import kotlin.math.max
import kotlin.math.min
import kotlin.math.pow

/**
 * High-performance Image Processing and Quality Assessment Component.
 * Optimized for edge execution on Android devices without heavy native dependencies.
 */
object OpencvImageProcessor {

    data class QualityCheckResult(
        val passed: Boolean,
        val blurScore: Double,
        val isBlurry: Boolean,
        val brightness: Double,
        val isBrightnessOk: Boolean,
        val glareDetected: Boolean,
        val guidance: String
    )

    data class RoiResult(
        val inRoi: Boolean,
        val offsetX: Float,
        val offsetY: Float,
        val guidance: String
    )

    /**
     * Computes image quality metrics: blur (Laplacian variance), brightness luminance, and glare.
     */
    fun assessQuality(bitmap: Bitmap): QualityCheckResult {
        val width = bitmap.width
        val height = bitmap.height
        val pixels = IntArray(width * height)
        bitmap.getPixels(pixels, 0, width, 0, 0, width, height)

        // 1. Brightness computation (Luminance mean)
        var totalLuminance = 0.0
        var brightPixelCount = 0
        val grayScale = DoubleArray(width * height)

        for (i in pixels.indices) {
            val color = pixels[i]
            val r = (color shr 16) and 0xFF
            val g = (color shr 8) and 0xFF
            val b = color and 0xFF
            val lum = 0.299 * r + 0.587 * g + 0.114 * b
            grayScale[i] = lum
            totalLuminance += lum

            if (lum > 240) {
                brightPixelCount++
            }
        }

        val meanBrightness = totalLuminance / (width * height)
        val isBrightnessOk = meanBrightness in 50.0..210.0
        val glareRatio = brightPixelCount.toDouble() / (width * height)
        val glareDetected = glareRatio > 0.08

        // 2. Blur check via Laplacian variance calculation
        var laplacianSum = 0.0
        var laplacianSqSum = 0.0
        var count = 0

        for (y in 1 until height - 1) {
            for (x in 1 until width - 1) {
                val idx = y * width + x
                // Discrete 3x3 Laplacian kernel: [[0, 1, 0], [1, -4, 1], [0, 1, 0]]
                val valCenter = grayScale[idx]
                val valUp = grayScale[(y - 1) * width + x]
                val valDown = grayScale[(y + 1) * width + x]
                val valLeft = grayScale[y * width + (x - 1)]
                val valRight = grayScale[y * width + (x + 1)]

                val laplacianVal = valUp + valDown + valLeft + valRight - 4 * valCenter
                laplacianSum += laplacianVal
                laplacianSqSum += laplacianVal * laplacianVal
                count++
            }
        }

        val laplacianMean = laplacianSum / count
        val laplacianVariance = (laplacianSqSum / count) - (laplacianMean * laplacianMean)
        val blurScore = max(0.0, laplacianVariance)
        val isBlurry = blurScore < 50.0

        // Guidance string resolution
        val guidance = when {
            isBlurry -> "Hold phone steady - Image is blurry"
            meanBrightness < 50.0 -> "Turn on torch - Too dark"
            meanBrightness > 210.0 -> "Reduce lighting - Too bright"
            glareDetected -> "Adjust angle to avoid glare"
            else -> "Quality Passed - Good capture"
        }

        val passed = !isBlurry && isBrightnessOk && !glareDetected

        return QualityCheckResult(
            passed = passed,
            blurScore = blurScore,
            isBlurry = isBlurry,
            brightness = meanBrightness,
            isBrightnessOk = isBrightnessOk,
            glareDetected = glareDetected,
            guidance = guidance
        )
    }

    /**
     * Checks if finger position is aligned within central oval ROI.
     */
    fun checkRoiAlignment(bitmap: Bitmap, bboxCenterX: Float, bboxCenterY: Float): RoiResult {
        val imgCenterX = bitmap.width / 2.0f
        val imgCenterY = bitmap.height / 2.0f

        val offsetX = bboxCenterX - imgCenterX
        val offsetY = bboxCenterY - imgCenterY

        val normX = offsetX / bitmap.width
        val normY = offsetY / bitmap.height

        val inRoi = abs(normX) < 0.15f && abs(normY) < 0.15f

        val guidance = when {
            inRoi -> "Good - finger centered"
            normX < -0.15f -> "Move right"
            normX > 0.15f -> "Move left"
            normY < -0.15f -> "Move down"
            normY > 0.15f -> "Move up"
            else -> "Center finger in oval"
        }

        return RoiResult(
            inRoi = inRoi,
            offsetX = offsetX,
            offsetY = offsetY,
            guidance = guidance
        )
    }

    /**
     * Contrast enhancement & Adaptive Histogram Equalization (CLAHE simulation).
     */
    fun enhanceContrast(bitmap: Bitmap): Bitmap {
        val width = bitmap.width
        val height = bitmap.height
        val srcPixels = IntArray(width * height)
        val dstPixels = IntArray(width * height)
        bitmap.getPixels(srcPixels, 0, width, 0, 0, width, height)

        // Find min/max luminance
        var minLum = 255
        var maxLum = 0
        val lums = IntArray(srcPixels.size)

        for (i in srcPixels.indices) {
            val c = srcPixels[i]
            val r = (c shr 16) and 0xFF
            val g = (c shr 8) and 0xFF
            val b = c and 0xFF
            val lum = (0.299 * r + 0.587 * g + 0.114 * b).toInt().coerceIn(0, 255)
            lums[i] = lum
            if (lum < minLum) minLum = lum
            if (lum > maxLum) maxLum = lum
        }

        val range = max(1, maxLum - minLum)

        for (i in srcPixels.indices) {
            val normLum = ((lums[i] - minLum) * 255 / range).coerceIn(0, 255)
            dstPixels[i] = Color.rgb(normLum, normLum, normLum)
        }

        val enhanced = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
        enhanced.setPixels(dstPixels, 0, width, 0, 0, width, height)
        return enhanced
    }

    /**
     * Converts bitmap to Base64 JPEG string representation.
     */
    fun bitmapToBase64(bitmap: Bitmap, quality: Int = 85): String {
        val outputStream = ByteArrayOutputStream()
        bitmap.compress(Bitmap.CompressFormat.JPEG, quality, outputStream)
        val byteArray = outputStream.toByteArray()
        return android.util.Base64.encodeToString(byteArray, android.util.Base64.NO_WRAP)
    }
}
