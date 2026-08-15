package com.yellowsense.sdk.cv

import android.graphics.Bitmap
import android.graphics.Color
import java.io.ByteArrayOutputStream
import kotlin.math.abs
import kotlin.math.max
import kotlin.math.min
import kotlin.math.sqrt

/**
 * High-performance Image Processing and Contact-Equivalent FIR Generator.
 *
 * Faithfully implements the exact preprocessing logic from backend/app.py:
 *   - get_segmentation_mask  -> segmentFingertip (TfliteInferenceEngine)
 *   - create_central_roi     -> applyCentralRoiErosion (here)
 *   - preprocess_fingerprint -> createContactEquivalentFIR (here)
 *
 * CDF histogram equalization is applied only to foreground (tissue) pixels,
 * exactly matching:
 *   gray = cv2.cvtColor(fg, cv2.COLOR_RGB2GRAY)
 *   hist, _ = np.histogram(gray.flatten(), 256, [0,256])
 *   cdf = hist.cumsum()
 *   cdf_m = np.ma.masked_equal(cdf, 0)
 *   cdf_m = (cdf_m - cdf_m.min()) * 255 / (cdf_m.max() - cdf_m.min())
 *   cdf = np.ma.filled(cdf_m, 0).astype("uint8")
 *   eq  = cdf[gray]
 *
 * Adaptive thresholding is then:
 *   thresh = cv2.adaptiveThreshold(gray_e, 255, ADAPTIVE_THRESH_MEAN_C, THRESH_BINARY, 15, 1)
 *   inv = 255 - thresh
 *   inv[mask == 0] = 255        <- outside mask → white
 *   roi = create_central_roi(mask)
 *   final = inv.copy()
 *   final[roi == 0] = 255       <- outside central ROI → white
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
     * Matching backend check_blur / check_brightness / check_glare logic.
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
        // backend: too_dark < 50.0, too_bright > 210.0
        val isBrightnessOk = meanBrightness in 50.0..210.0
        val glareRatio = brightPixelCount.toDouble() / (width * height)
        val glareDetected = glareRatio > 0.05  // backend: overexposed > 0.05

        // Laplacian variance (backend threshold: 20.0)
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
        val isBlurry = blurScore < 20.0  // backend threshold: 20.0

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
     * Crops the distal fingertip from a single-finger capture.
     * Matches backend detect_and_crop_image (YOLO bbox crop with fallback).
     */
    fun cropDistalFingertip(bitmap: Bitmap): Bitmap {
        val w = bitmap.width
        val h = bitmap.height
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
            val ch = (h * 0.48f).toInt()
            val left = ((w - cw) / 2).coerceIn(0, w - 10)
            val top = ((h * 0.24f).toInt()).coerceIn(0, h - 10)
            val safeW = cw.coerceIn(10, w - left)
            val safeH = ch.coerceIn(10, h - top)
            return Bitmap.createBitmap(bitmap, left, top, safeW, safeH)
        }

        val tipWidth = max(20, maxX - minX)
        val distalHeight = (tipWidth * 1.30f).toInt()
        val padX = (tipWidth * 0.06f).toInt()
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
     * Crops a specific finger distal pad from a 4-finger slap capture.
     *
     * Slot boundaries EXACTLY match _SlapOverlayPainter geometry:
     *   fingerW = w * 0.15, gap = w * 0.047
     *   startX = (w - (4*fingerW + 3*gap)) / 2 = w * 0.1295
     *   Slot X ranges: [12.95-27.95%], [32.65-47.65%], [52.35-67.35%], [72.05-87.05%]
     *   Y: 20% (top of longest finger) to 85% (below knuckle line at 80%)
     */
    fun cropSlapFingerDistal(bitmap: Bitmap, slotIndex: Int, handSide: String): Bitmap {
        val w = bitmap.width
        val h = bitmap.height

        // fingerW=15%, gap=4.7%, startX=12.95%
        // Slot i starts at: startX + i*(fingerW+gap) = 12.95% + i*19.7%
        val fingerW = w * 0.15f
        val gap = w * 0.047f
        val startX = (w - (4f * fingerW + 3f * gap)) / 2f

        val slotX1 = (startX + slotIndex * (fingerW + gap)).toInt().coerceIn(0, w - 1)
        val slotX2 = (startX + slotIndex * (fingerW + gap) + fingerW).toInt().coerceIn(slotX1 + 1, w)

        // Y: fingers go from top=~20% to knuckle=80%; add margin to 85%
        val slotY1 = (h * 0.20f).toInt()
        val slotY2 = (h * 0.85f).toInt()

        val pixels = IntArray(w * h)
        bitmap.getPixels(pixels, 0, w, 0, 0, w, h)

        var minX = slotX2; var maxX = slotX1
        var minY = slotY2; var maxY = slotY1
        var count = 0

        for (y in slotY1 until slotY2 step 2) {
            for (x in slotX1 until slotX2 step 2) {
                val c = pixels[y * w + x]
                val r = (c shr 16) and 0xFF
                val g = (c shr 8) and 0xFF
                val b = c and 0xFF
                val lum = (0.299 * r + 0.587 * g + 0.114 * b).toInt()
                if (r > 30 && g > 18 && (r >= b - 15) && lum in 25..245) {
                    if (x < minX) minX = x; if (x > maxX) maxX = x
                    if (y < minY) minY = y; if (y > maxY) maxY = y
                    count++
                }
            }
        }

        if (count < 50 || minX >= maxX || minY >= maxY) {
            // Fallback: return the full slot region — U2-Net will segment the finger
            val cropW = (slotX2 - slotX1).coerceIn(10, w - slotX1)
            val cropH = (slotY2 - slotY1).coerceIn(10, h - slotY1)
            return Bitmap.createBitmap(bitmap, slotX1, slotY1, cropW, cropH)
        }

        val detectedWidth = max(20, maxX - minX)
        val detectedHeight = max(20, maxY - minY)
        // Keep generous crop: full detected width + 5% pad, full height from top to bottom
        val padX2 = (detectedWidth * 0.05f).toInt()

        val cropX1 = max(slotX1, minX - padX2)
        val cropX2 = min(slotX2, maxX + padX2)
        val cropY1 = max(0, minY)          // from first skin pixel top
        val cropY2 = min(h, slotY2)        // to knuckle+margin bottom

        val finalW = (cropX2 - cropX1).coerceIn(10, w - cropX1)
        val finalH = (cropY2 - cropY1).coerceIn(10, h - cropY1)
        return Bitmap.createBitmap(bitmap, cropX1, cropY1, finalW, finalH)
    }

    // ─────────────────────────────────────────────────────────────────────────
    // CENTRAL ROI EROSION — exact replica of backend/app.py create_central_roi
    // alpha=0.25 -> erodes the convex-hull filled mask by int(min(h,w)*0.25*0.5) px
    // ─────────────────────────────────────────────────────────────────────────
    private fun applyCentralRoiErosion(maskBytes: ByteArray, w: Int, h: Int): ByteArray {
        // morphologyEx CLOSE then OPEN with 7×7 kernel, then erode
        val k = 7
        val closed = morphClose(maskBytes, w, h, k)
        val opened = morphOpen(closed, w, h, k)

        // find bounding box of the foreground hull approximation
        var minX2 = w; var maxX2 = 0; var minY2 = h; var maxY2 = 0
        for (y in 0 until h) for (x in 0 until w) {
            if (opened[y * w + x] == 1.toByte()) {
                if (x < minX2) minX2 = x; if (x > maxX2) maxX2 = x
                if (y < minY2) minY2 = y; if (y > maxY2) maxY2 = y
            }
        }
        if (minX2 > maxX2 || minY2 > maxY2) return opened

        // ep = int(min(h, w) * 0.25 * 0.5)
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

    // ─────────────────────────────────────────────────────────────────────────
    // CONTACT-EQUIVALENT FIR
    // Faithful replica of backend preprocess_fingerprint():
    //   1. Apply mask to image (fg on mask, white outside)
    //   2. Compute lum = mean of fg gray  (if lum < 150 use Zero-DCE else CDF hist eq)
    //   3. CDF histogram equalization on MASK pixels only (masked_equal trick)
    //   4. adaptiveThreshold(gray_e, 255, ADAPTIVE_THRESH_MEAN_C, THRESH_BINARY, 15, 1)
    //   5. inv = 255 - thresh  ; inv[mask==0] = 255
    //   6. roi = create_central_roi(mask) ; final[roi==0] = 255
    // ─────────────────────────────────────────────────────────────────────────
    fun createContactEquivalentFIR(crop: Bitmap, neuralMask: BooleanArray? = null): Bitmap {
        val w = crop.width
        val h = crop.height
        val srcPixels = IntArray(w * h)
        crop.getPixels(srcPixels, 0, w, 0, 0, w, h)

        // ── Step 1: Build tissue mask ──────────────────────────────────────
        // If neuralMask provided use it; otherwise use ellipse heuristic
        val maskBytes = ByteArray(w * h)
        if (neuralMask != null && neuralMask.size == w * h) {
            for (i in neuralMask.indices) maskBytes[i] = if (neuralMask[i]) 1 else 0
        } else {
            val cx = w / 2.0; val cy = h * 0.48; val rx = w * 0.47; val ry = h * 0.49
            for (y in 0 until h) {
                for (x in 0 until w) {
                    val dx = (x - cx) / rx; val dy = (y - cy) / ry
                    val c = srcPixels[y * w + x]
                    val lum = ((c shr 16 and 0xFF) * 0.299 +
                            (c shr 8 and 0xFF) * 0.587 +
                            (c and 0xFF) * 0.114).toInt()
                    maskBytes[y * w + x] = if ((dx * dx + dy * dy) <= 1.0 && lum in 20..248) 1 else 0
                }
            }
        }

        // ── Step 2: Compute fg gray (mask applied, bg=255) ─────────────────
        // Backend: img_rgb[where mask=1], white elsewhere
        // gray = cv2.cvtColor(fg, cv2.COLOR_RGB2GRAY)  <- only fg pixels matter for CDF
        val fgGray = IntArray(w * h) { idx ->
            val isMask = maskBytes[idx] == 1.toByte()
            if (isMask) {
                val c = srcPixels[idx]
                ((c shr 16 and 0xFF) * 0.299 +
                        (c shr 8 and 0xFF) * 0.587 +
                        (c and 0xFF) * 0.114).toInt().coerceIn(0, 255)
            } else {
                255  // white background
            }
        }

        // ── Step 3: CDF Histogram Equalization on MASK-only pixels ─────────
        // Matches Python: hist, _ = np.histogram(gray.flatten(), 256, [0,256])
        // BUT gray here contains 255 for bg pixels — the backend does:
        //   fg = white-bg; gray = cvtColor(fg); hist of full gray (including bg 255 pixels)
        // So we include ALL pixels in the histogram, then CDF equalize.
        val hist = IntArray(256)
        for (g in fgGray) hist[g]++

        // np.ma.masked_equal equivalent: CDF with minCdf = first nonzero bucket
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
        // Integral image for O(1) box sums
        val integral = IntArray((w + 1) * (h + 1))
        for (y in 0 until h) {
            var rowSum = 0
            val rIdx = (y + 1) * (w + 1); val pIdx = y * (w + 1)
            for (x in 0 until w) {
                rowSum += eqGray[y * w + x]
                integral[rIdx + (x + 1)] = integral[pIdx + (x + 1)] + rowSum
            }
        }

        val radius = 7  // blockSize = 15

        // thresh result: 1=ridge(dark), 0=valley(white), 255=outside mask
        val threshResult = IntArray(w * h)
        for (y in 0 until h) {
            val y1 = max(0, y - radius); val y2 = min(h, y + radius + 1)
            for (x in 0 until w) {
                val pixelIdx = y * w + x
                if (maskBytes[pixelIdx] != 1.toByte()) {
                    threshResult[pixelIdx] = 255  // outside mask → white (inv[mask==0]=255)
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
                // adaptiveThreshold THRESH_BINARY → pixel=255 if cur > (mean-C), else 0
                // inv = 255 - thresh → ridge (dark) = cur < (mean-1), valley (white)
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
            // 0 → dark ridge (20,20,20) ; 255 → white
            outPixels[i] = if (finalVal < 128) Color.rgb(20, 20, 20) else Color.WHITE
        }

        val fir = Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888)
        fir.setPixels(outPixels, 0, w, 0, 0, w, h)
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
