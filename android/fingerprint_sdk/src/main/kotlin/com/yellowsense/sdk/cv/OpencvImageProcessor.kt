package com.yellowsense.sdk.cv

import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.RectF
import java.io.ByteArrayOutputStream
import kotlin.math.abs
import kotlin.math.max
import kotlin.math.min
import kotlin.math.sqrt

/**
 * High-performance Image Processing and Contact-Equivalent FIR Generator.
 *
 * Implements:
 *   - Distal phalanx fingertip focal cropping (square 1:1 format)
 *   - CDF histogram equalization on foreground tissue
 *   - 2D Integral adaptive mean thresholding
 *   - Central ROI erosion
 *   - Square formatting for crisp, distortion-free UI display
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
     * Centers any bitmap inside a square canvas of size max(w, h) with the specified background color.
     */
    fun toSquareBitmap(bitmap: Bitmap, bgColor: Int = Color.WHITE): Bitmap {
        val w = bitmap.width
        val h = bitmap.height
        if (w == h) return bitmap
        val size = max(w, h)
        val square = Bitmap.createBitmap(size, size, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(square)
        canvas.drawColor(bgColor)
        val left = ((size - w) / 2).toFloat()
        val top = ((size - h) / 2).toFloat()
        canvas.drawBitmap(bitmap, left, top, null)
        return square
    }

    /**
     * Computes image quality metrics: blur (Laplacian variance), brightness luminance, and glare.
     */
    fun assessQuality(bitmap: Bitmap): QualityCheckResult {
        val width = bitmap.width
        val height = bitmap.height
        val pixels = IntArray(width * height)
        bitmap.getPixels(pixels, 0, width, 0, 0, width, height)

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
            if (lum > 240) brightPixelCount++
        }

        val meanBrightness = totalLuminance / (width * height)
        val isBrightnessOk = meanBrightness in 50.0..210.0
        val glareRatio = brightPixelCount.toDouble() / (width * height)
        val glareDetected = glareRatio > 0.05

        var laplacianSqSum = 0.0
        var laplacianSum = 0.0
        var count = 0
        for (y in 1 until height - 1 step 2) {
            for (x in 1 until width - 1 step 2) {
                val idx = y * width + x
                val laplacianVal = grayScale[(y - 1) * width + x] +
                        grayScale[(y + 1) * width + x] +
                        grayScale[y * width + (x - 1)] +
                        grayScale[y * width + (x + 1)] -
                        4 * grayScale[idx]
                laplacianSum += laplacianVal
                laplacianSqSum += laplacianVal * laplacianVal
                count++
            }
        }
        val laplacianMean = if (count > 0) laplacianSum / count else 0.0
        val laplacianVariance = if (count > 0) (laplacianSqSum / count) - (laplacianMean * laplacianMean) else 0.0
        val blurScore = max(0.0, laplacianVariance)
        val isBlurry = blurScore < 15.0

        val guidance = when {
            isBlurry -> "Finger is blurry — tap screen to focus 🔍"
            meanBrightness < 50.0 -> "Image is darker — open flash 💡"
            meanBrightness > 210.0 -> "Too bright — reduce exposure"
            glareDetected -> "Glare detected — adjust angle"
            else -> "Good — capture ready"
        }

        return QualityCheckResult(
            passed = !isBlurry && isBrightnessOk && !glareDetected,
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
        val inRoi = abs(normX) < 0.22f && abs(normY) < 0.22f

        val guidance = when {
            inRoi -> "Good - finger centered"
            normX < -0.22f -> "Move right"
            normX > 0.22f -> "Move left"
            normY < -0.22f -> "Move down"
            normY > 0.22f -> "Move up"
            else -> "Center finger in oval"
        }

        return RoiResult(inRoi = inRoi, offsetX = offsetX, offsetY = offsetY, guidance = guidance)
    }

    /**
     * Crops ONLY the required distal fingertip pad from a bounding box or single-finger capture.
     * Returns a square 1:1 image containing only the fingerprint pad.
     */
    fun cropDistalFingertip(bitmap: Bitmap, bbox: RectF? = null): Bitmap {
        val w = bitmap.width
        val h = bitmap.height

        if (bbox != null) {
            val bw = bbox.width()
            val bh = bbox.height()
            // Distal phalanx is the top ~1.15x width of the finger
            val distalH = min(bh, bw * 1.18f)
            val padX = (bw * 0.05f).toInt()
            val padY = (distalH * 0.04f).toInt()
            val x1 = max(0, bbox.left.toInt() - padX)
            val y1 = max(0, bbox.top.toInt() - padY)
            val x2 = min(w, bbox.right.toInt() + padX)
            val y2 = min(h, bbox.top.toInt() + distalH.toInt() + padY)
            val cw = max(10, x2 - x1)
            val ch = max(10, y2 - y1)
            val crop = Bitmap.createBitmap(bitmap, x1, y1, cw, ch)
            return toSquareBitmap(crop)
        }

        val pixels = IntArray(w * h)
        bitmap.getPixels(pixels, 0, w, 0, 0, w, h)

        val scanX1 = (w * 0.20f).toInt()
        val scanX2 = (w * 0.80f).toInt()
        val scanY1 = (h * 0.18f).toInt()
        val scanY2 = (h * 0.82f).toInt()

        var minX = scanX2; var maxX = scanX1
        var minY = scanY2; var maxY = scanY1
        var skinPixels = 0

        for (y in scanY1 until scanY2 step 2) {
            for (x in scanX1 until scanX2 step 2) {
                val c = pixels[y * w + x]
                val r = (c shr 16) and 0xFF
                val g = (c shr 8) and 0xFF
                val b = c and 0xFF
                val lum = (0.299 * r + 0.587 * g + 0.114 * b).toInt()
                if (r > 30 && g > 18 && (r >= b - 15) && lum in 25..245) {
                    if (x < minX) minX = x; if (x > maxX) maxX = x
                    if (y < minY) minY = y; if (y > maxY) maxY = y
                    skinPixels++
                }
            }
        }

        if (skinPixels < 120 || minX >= maxX || minY >= maxY) {
            val cw = (w * 0.46f).toInt()
            val ch = (cw * 1.15f).toInt()
            val left = ((w - cw) / 2).coerceIn(0, w - 10)
            val top = ((h * 0.24f).toInt()).coerceIn(0, h - ch)
            val safeW = cw.coerceIn(10, w - left)
            val safeH = ch.coerceIn(10, h - top)
            return Bitmap.createBitmap(bitmap, left, top, safeW, safeH)
        }

        val tipWidth = max(20, maxX - minX)
        val distalHeight = (tipWidth * 1.18f).toInt()
        val padX = (tipWidth * 0.05f).toInt()
        val padTop = (tipWidth * 0.04f).toInt()

        val cropX1 = max(0, minX - padX)
        val cropX2 = min(w, maxX + padX)
        val cropY1 = max(0, minY - padTop)
        val cropY2 = min(h, cropY1 + distalHeight)

        val finalW = (cropX2 - cropX1).coerceIn(10, w - cropX1)
        val finalH = (cropY2 - cropY1).coerceIn(10, h - cropY1)
        return Bitmap.createBitmap(bitmap, cropX1, cropY1, finalW, finalH)
    }

    /**
     * Crops ONLY the required distal fingertip pad from a slap slot.
     * Returns a square 1:1 image.
     */
    /**
     * Finds the true skin fingertip apex in a bounding region and crops only the distal pad.
     * Guarantees that dark / black background above the finger is NEVER cropped!
     */
    fun refineSkinApexCrop(bitmap: Bitmap, x1: Int, y1: Int, x2: Int, y2: Int): IntArray {
        val w = bitmap.width
        val h = bitmap.height
        val cw = max(10, x2 - x1)
        val ch = max(10, y2 - y1)

        val pixels = IntArray(cw * ch)
        bitmap.getPixels(pixels, 0, cw, x1, y1, cw, ch)

        var apexY = -1
        var minSkinX = cw
        var maxSkinX = 0
        var totalSkin = 0

        for (localY in 0 until ch) {
            var rowSkin = 0
            for (localX in 0 until cw) {
                val c = pixels[localY * cw + localX]
                val r = (c shr 16) and 0xFF
                val g = (c shr 8) and 0xFF
                val b = c and 0xFF
                val lum = (0.299 * r + 0.587 * g + 0.114 * b).toInt()

                // Skin chrominance test
                if (r > 42 && g > 24 && (r >= b - 12) && (r - g) in 0..110 && lum in 32..245) {
                    rowSkin++
                    if (localX < minSkinX) minSkinX = localX
                    if (localX > maxSkinX) maxSkinX = localX
                    totalSkin++
                }
            }
            if (rowSkin >= max(4, cw / 16) && apexY == -1) {
                apexY = localY
            }
        }

        if (totalSkin >= 60 && apexY != -1 && minSkinX < maxSkinX) {
            val globalApexY = y1 + apexY
            val fingerWidth = max(20, maxSkinX - minSkinX)
            val distalH = (fingerWidth * 1.20f).toInt()
            val padX = (fingerWidth * 0.06f).toInt()
            val padTop = (fingerWidth * 0.03f).toInt()

            val rx1 = max(0, x1 + minSkinX - padX)
            val rx2 = min(w, x1 + maxSkinX + padX)
            val ry1 = max(0, globalApexY - padTop)
            val ry2 = min(h, ry1 + distalH)
            return intArrayOf(rx1, ry1, rx2, ry2)
        }

        return intArrayOf(x1, y1, x2, y2)
    }

    /**
     * Detects and extracts the distal fingertip in a slap camera slot using skin chroma & apex scanning.
     */
    fun detectSlotFingerCrop(bitmap: Bitmap, slotIndex: Int, isRightHand: Boolean): IntArray {
        val w = bitmap.width
        val h = bitmap.height

        val slotW = w * 0.15f
        val gap = w * 0.047f
        val startX = (w - (4f * slotW + 3f * gap)) / 2f

        val sx1 = (startX + slotIndex * (slotW + gap) - slotW * 0.10f).toInt().coerceIn(0, w - 1)
        val sx2 = (startX + slotIndex * (slotW + gap) + slotW * 1.10f).toInt().coerceIn(sx1 + 1, w)

        val topFractions = if (isRightHand) {
            floatArrayOf(0.24f, 0.16f, 0.22f, 0.32f)
        } else {
            floatArrayOf(0.32f, 0.22f, 0.16f, 0.24f)
        }
        val botFractions = if (isRightHand) {
            floatArrayOf(0.65f, 0.58f, 0.62f, 0.72f)
        } else {
            floatArrayOf(0.72f, 0.62f, 0.58f, 0.65f)
        }

        val sy1 = (h * topFractions[slotIndex]).toInt().coerceIn(0, h - 1)
        val sy2 = (h * botFractions[slotIndex]).toInt().coerceIn(sy1 + 1, h)

        return refineSkinApexCrop(bitmap, sx1, sy1, sx2, sy2)
    }

    /**
     * Crops ONLY the required distal fingertip pad from a slap slot.
     * Returns a square 1:1 image.
     */
    fun cropSlapFingerDistal(bitmap: Bitmap, slotIndex: Int, handSide: String): Bitmap {
        val isRight = !handSide.lowercase().contains("left")
        val rect = detectSlotFingerCrop(bitmap, slotIndex, isRight)
        val (x1, y1, x2, y2) = rect
        val cw = max(10, x2 - x1)
        val ch = max(10, y2 - y1)
        val crop = Bitmap.createBitmap(bitmap, x1, y1, cw, ch)
        return toSquareBitmap(crop)
    }

    private fun applyCentralRoiErosion(maskBytes: ByteArray, w: Int, h: Int): ByteArray {
        val k = 7
        val closed = morphClose(maskBytes, w, h, k)
        val opened = morphOpen(closed, w, h, k)

        var minX2 = w; var maxX2 = 0; var minY2 = h; var maxY2 = 0
        for (y in 0 until h) for (x in 0 until w) {
            if (opened[y * w + x] == 1.toByte()) {
                if (x < minX2) minX2 = x; if (x > maxX2) maxX2 = x
                if (y < minY2) minY2 = y; if (y > maxY2) maxY2 = y
            }
        }
        if (minX2 > maxX2 || minY2 > maxY2) return opened

        val ep = (min(h, w) * 0.25 * 0.5).toInt()
        if (ep <= 1) return opened

        return morphErode(opened, w, h, ep)
    }

    private fun morphClose(mask: ByteArray, w: Int, h: Int, k: Int): ByteArray {
        return morphErode(morphDilate(mask, w, h, k), w, h, k)
    }

    private fun morphOpen(mask: ByteArray, w: Int, h: Int, k: Int): ByteArray {
        return morphDilate(morphErode(mask, w, h, k), w, h, k)
    }

    private fun morphDilate(mask: ByteArray, w: Int, h: Int, k: Int): ByteArray {
        val out = ByteArray(w * h)
        val r = k / 2
        for (y in 0 until h) {
            for (x in 0 until w) {
                var found = false
                outer@ for (dy in -r..r) {
                    for (dx in -r..r) {
                        val nx = (x + dx).coerceIn(0, w - 1)
                        val ny = (y + dy).coerceIn(0, h - 1)
                        if (mask[ny * w + nx] == 1.toByte()) { found = true; break@outer }
                    }
                }
                out[y * w + x] = if (found) 1 else 0
            }
        }
        return out
    }

    private fun morphErode(mask: ByteArray, w: Int, h: Int, k: Int): ByteArray {
        val out = ByteArray(w * h)
        val r = k / 2
        for (y in 0 until h) {
            for (x in 0 until w) {
                var allOne = true
                outer@ for (dy in -r..r) {
                    for (dx in -r..r) {
                        val nx = (x + dx).coerceIn(0, w - 1)
                        val ny = (y + dy).coerceIn(0, h - 1)
                        if (mask[ny * w + nx] != 1.toByte()) { allOne = false; break@outer }
                    }
                }
                out[y * w + x] = if (allOne) 1 else 0
            }
        }
        return out
    }

    /**
     * Contact-Equivalent FIR Preprocessing.
     * Always returns a crisp, square (1:1) FIR image with strict background rejection.
     */
    fun createContactEquivalentFIR(crop: Bitmap, neuralMask: BooleanArray? = null): Bitmap {
        val w = crop.width
        val h = crop.height
        val srcPixels = IntArray(w * h)
        crop.getPixels(srcPixels, 0, w, 0, 0, w, h)

        // ── Step 1: Build tissue mask (with strict black background rejection) ─
        val maskBytes = ByteArray(w * h)
        var totalSkinPixels = 0

        if (neuralMask != null && neuralMask.size == w * h) {
            for (i in neuralMask.indices) {
                if (neuralMask[i]) {
                    val c = srcPixels[i]
                    val r = (c shr 16) and 0xFF
                    val g = (c shr 8) and 0xFF
                    val b = c and 0xFF
                    val lum = (0.299 * r + 0.587 * g + 0.114 * b).toInt()
                    if (lum > 30 && r > 35 && (r >= b - 15)) {
                        maskBytes[i] = 1
                        totalSkinPixels++
                    } else {
                        maskBytes[i] = 0
                    }
                } else {
                    maskBytes[i] = 0
                }
            }
        } else {
            val cx = w / 2.0; val cy = h * 0.48; val rx = w * 0.47; val ry = h * 0.49
            for (y in 0 until h) {
                for (x in 0 until w) {
                    val dx = (x - cx) / rx; val dy = (y - cy) / ry
                    val c = srcPixels[y * w + x]
                    val r = (c shr 16) and 0xFF
                    val g = (c shr 8) and 0xFF
                    val b = c and 0xFF
                    val lum = (0.299 * r + 0.587 * g + 0.114 * b).toInt()
                    if ((dx * dx + dy * dy) <= 1.0 && lum in 32..245 && r > 40 && r >= b - 15) {
                        maskBytes[y * w + x] = 1
                        totalSkinPixels++
                    } else {
                        maskBytes[y * w + x] = 0
                    }
                }
            }
        }

        // If no finger present in crop (e.g. black room background), return blank white canvas
        if (totalSkinPixels < max(30, (w * h * 0.03).toInt())) {
            val blank = Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888)
            Canvas(blank).drawColor(Color.WHITE)
            return blank
        }

        // ── Step 2: Compute fg gray (mask applied, bg=255) ─────────────────
        val fgGray = IntArray(w * h) { idx ->
            val isMask = maskBytes[idx] == 1.toByte()
            if (isMask) {
                val c = srcPixels[idx]
                ((c shr 16 and 0xFF) * 0.299 +
                        (c shr 8 and 0xFF) * 0.587 +
                        (c and 0xFF) * 0.114).toInt().coerceIn(0, 255)
            } else {
                255
            }
        }

        // ── Step 3: CDF Histogram Equalization on ALL pixels ───────────────
        val hist = IntArray(256)
        for (g in fgGray) hist[g]++

        val cdf = IntArray(256)
        var runSum = 0; var minCdf = -1
        for (i in 0 until 256) {
            runSum += hist[i]
            cdf[i] = runSum
            if (runSum > 0 && minCdf == -1) minCdf = runSum
        }
        val total = w * h
        minCdf = max(1, minCdf)
        val denom = max(1, total - minCdf)
        val lut = IntArray(256) { i ->
            if (cdf[i] == 0) 0 else (((cdf[i] - minCdf) * 255) / denom).coerceIn(0, 255)
        }

        val eqGray = IntArray(w * h) { i -> lut[fgGray[i]] }

        // ── Step 4: Adaptive Mean Thresholding (blockSize=15, C=1) ──────────
        val integral = IntArray((w + 1) * (h + 1))
        for (y in 0 until h) {
            var rowSum = 0
            val rIdx = (y + 1) * (w + 1); val pIdx = y * (w + 1)
            for (x in 0 until w) {
                rowSum += eqGray[y * w + x]
                integral[rIdx + (x + 1)] = integral[pIdx + (x + 1)] + rowSum
            }
        }

        val radius = 7

        val threshResult = IntArray(w * h)
        for (y in 0 until h) {
            val y1 = max(0, y - radius); val y2 = min(h, y + radius + 1)
            for (x in 0 until w) {
                val pixelIdx = y * w + x
                if (maskBytes[pixelIdx] != 1.toByte()) {
                    threshResult[pixelIdx] = 255
                    continue
                }
                val x1 = max(0, x - radius); val x2 = min(w, x + radius + 1)
                val count = (x2 - x1) * (y2 - y1)
                val boxSum = integral[y2 * (w + 1) + x2] -
                        integral[y1 * (w + 1) + x2] -
                        integral[y2 * (w + 1) + x1] +
                        integral[y1 * (w + 1) + x1]
                val localMean = if (count > 0) (boxSum.toDouble() / count) else 128.0
                val cur = eqGray[pixelIdx]
                threshResult[pixelIdx] = if (cur < (localMean - 1.0)) 0 else 255
            }
        }

        // ── Step 5: Central ROI erosion — final[roi==0] = 255 ─────────────
        val roi = applyCentralRoiErosion(maskBytes, w, h)
        val outPixels = IntArray(w * h)
        for (i in 0 until w * h) {
            val isInRoi = roi[i] == 1.toByte()
            val val_ = threshResult[i]
            val finalVal = if (!isInRoi) 255 else val_
            outPixels[i] = if (finalVal < 128) Color.rgb(20, 20, 20) else Color.WHITE
        }

        // ── Step 6: Auto-crop bottom content (matching backend preprocess_fingerprint)
        var lastRowWithContent = h - 1
        for (y in h - 1 downTo 0) {
            var hasContent = false
            for (x in 0 until w) {
                if (outPixels[y * w + x] != Color.WHITE) {
                    hasContent = true
                    break
                }
            }
            if (hasContent) {
                lastRowWithContent = y
                break
            }
        }
        val pad = (h * 0.02f).toInt()
        val finalH = min(h, lastRowWithContent + pad + 1).coerceAtLeast(10)

        val fir = Bitmap.createBitmap(w, finalH, Bitmap.Config.ARGB_8888)
        fir.setPixels(outPixels, 0, w, 0, 0, w, finalH)
        return fir
    }

    /**
     * Converts bitmap to Base64 JPEG string representation.
     */
    fun bitmapToBase64(bitmap: Bitmap, quality: Int = 85): String {
        val outputStream = ByteArrayOutputStream()
        bitmap.compress(Bitmap.CompressFormat.JPEG, quality, outputStream)
        return android.util.Base64.encodeToString(outputStream.toByteArray(), android.util.Base64.NO_WRAP)
    }
}
