package com.yellowsense.sdk.engine

import android.content.Context
import android.graphics.Bitmap
import android.graphics.RectF
import org.tensorflow.lite.Interpreter
import com.yellowsense.sdk.iso.MinutiaPoint
import java.io.FileInputStream
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.nio.channels.FileChannel
import kotlin.math.max
import kotlin.math.min

/**
 * On-Device TensorFlow Lite Multithreaded Execution Engine.
 *
 * Loads and runs:
 *   1. U2-Net fingertip segmentation (u2net_320x320_float32.tflite)
 *   2. Multi-finger YOLO detector (best_float32.tflite)
 */
class TfliteInferenceEngine(private val context: Context) {

    private var u2netInterpreter: Interpreter? = null
    private var yoloInterpreter: Interpreter? = null
    private var minutiaeInterpreter: Interpreter? = null
    private var isInitialized = false

    data class DetectionBox(
        val boundingBox: RectF,
        val confidence: Float,
        val classId: Int,
        val className: String
    )

    data class LivenessResult(
        val isLive: Boolean,
        val liveScore: Float,
        val spoofScore: Float,
        val threshold: Float = 0.5f
    )

    init {
        initInterpreters()
    }

    private fun initInterpreters() {
        try {
            val options = Interpreter.Options().apply {
                setNumThreads(4)
                setUseNNAPI(true)
            }
            val u2netBuffer = loadModelFile("u2net_320x320_float32.tflite")
            if (u2netBuffer != null) {
                u2netInterpreter = Interpreter(u2netBuffer, options)
            }
            val yoloBuffer = loadModelFile("best_float32.tflite")
            if (yoloBuffer != null) {
                yoloInterpreter = Interpreter(yoloBuffer, options)
            }
            val minutiaeBuffer = loadModelFile("minutiae_net.tflite")
            if (minutiaeBuffer != null) {
                minutiaeInterpreter = Interpreter(minutiaeBuffer, options)
            }
            isInitialized = true
        } catch (e: Exception) {
            isInitialized = false
        }
    }

    private fun loadModelFile(modelName: String): ByteBuffer? {
        return try {
            val fileDescriptor = context.assets.openFd(modelName)
            val inputStream = FileInputStream(fileDescriptor.fileDescriptor)
            val fileChannel = inputStream.channel
            fileChannel.map(FileChannel.MapMode.READ_ONLY, fileDescriptor.startOffset, fileDescriptor.declaredLength)
        } catch (e: Exception) {
            null
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // YOLO MULTI-FINGER DETECTION — exact replica of backend detect_all_finger_boxes
    // ─────────────────────────────────────────────────────────────────────────
    fun detectFingers(
        bitmap: Bitmap,
        confThreshold: Float = 0.15f,
        iouThreshold: Float = 0.45f
    ): List<DetectionBox> {
        val yolo = yoloInterpreter ?: return emptyList()
        val origW = bitmap.width
        val origH = bitmap.height

        try {
            // 1. Resize to 800x800 and normalize [0, 1] RGB
            val resized = Bitmap.createScaledBitmap(bitmap, 800, 800, true)
            val inputBuffer = ByteBuffer.allocateDirect(1 * 800 * 800 * 3 * 4).apply {
                order(ByteOrder.nativeOrder())
            }

            val pixels = IntArray(800 * 800)
            resized.getPixels(pixels, 0, 800, 0, 0, 800, 800)

            for (color in pixels) {
                inputBuffer.putFloat(((color shr 16) and 0xFF) / 255.0f)
                inputBuffer.putFloat(((color shr 8) and 0xFF) / 255.0f)
                inputBuffer.putFloat((color and 0xFF) / 255.0f)
            }

            // 2. Read output tensor shape and allocate buffer
            val outTensor = yolo.getOutputTensor(0)
            val shape = outTensor.shape() // e.g. [1, 8, 13125] or [1, 13125, 8]
            val totalElements = outTensor.numElements()
            val outputBuffer = ByteBuffer.allocateDirect(totalElements * 4).apply {
                order(ByteOrder.nativeOrder())
            }
            yolo.run(inputBuffer, outputBuffer)
            outputBuffer.rewind()

            val classNames = arrayOf("FingerTips", "FingerTips-2DFX", "Fingerprint", "finger")
            val rawDets = mutableListOf<DetectionBox>()
            val scaleX = origW / 800.0f
            val scaleY = origH / 800.0f
            val minArea = (origW * origH) * 0.001f

            val isLayoutAnchorsFirst = (shape.size == 3 && shape[1] > shape[2]) // [1, 13125, 8]
            val numAnchors = if (shape.size == 3) (if (isLayoutAnchorsFirst) shape[1] else shape[2]) else 13125
            val numAttrs = if (shape.size == 3) (if (isLayoutAnchorsFirst) shape[2] else shape[1]) else 8

            if (isLayoutAnchorsFirst) {
                // Layout [1, numAnchors, numAttrs] — contiguous per anchor
                for (a in 0 until numAnchors) {
                    val cx = outputBuffer.float
                    val cy = outputBuffer.float
                    val bw = outputBuffer.float
                    val bh = outputBuffer.float

                    var maxScore = 0.0f
                    var bestCls = 0
                    for (c in 0 until (numAttrs - 4)) {
                        val s = outputBuffer.float
                        if (s > maxScore) {
                            maxScore = s
                            bestCls = c.coerceIn(0, classNames.size - 1)
                        }
                    }

                    if (maxScore >= confThreshold) {
                        val x1 = max(0f, (cx - bw / 2.0f) * scaleX)
                        val y1 = max(0f, (cy - bh / 2.0f) * scaleY)
                        val x2 = min(origW.toFloat(), (cx + bw / 2.0f) * scaleX)
                        val y2 = min(origH.toFloat(), (cy + bh / 2.0f) * scaleY)

                        if ((x2 - x1) * (y2 - y1) >= minArea) {
                            rawDets.add(
                                DetectionBox(
                                    boundingBox = RectF(x1, y1, x2, y2),
                                    confidence = maxScore,
                                    classId = bestCls,
                                    className = classNames[bestCls]
                                )
                            )
                        }
                    }
                }
            } else {
                // Layout [1, numAttrs, numAnchors] — contiguous per attribute row
                val out = Array(numAttrs) { FloatArray(numAnchors) }
                for (r in 0 until numAttrs) {
                    for (a in 0 until numAnchors) {
                        out[r][a] = outputBuffer.float
                    }
                }

                for (a in 0 until numAnchors) {
                    val cx = out[0][a]
                    val cy = out[1][a]
                    val bw = out[2][a]
                    val bh = out[3][a]

                    var maxScore = 0.0f
                    var bestCls = 0
                    for (c in 0 until (numAttrs - 4)) {
                        val s = out[4 + c][a]
                        if (s > maxScore) {
                            maxScore = s
                            bestCls = c.coerceIn(0, classNames.size - 1)
                        }
                    }

                    if (maxScore >= confThreshold) {
                        val x1 = max(0f, (cx - bw / 2.0f) * scaleX)
                        val y1 = max(0f, (cy - bh / 2.0f) * scaleY)
                        val x2 = min(origW.toFloat(), (cx + bw / 2.0f) * scaleX)
                        val y2 = min(origH.toFloat(), (cy + bh / 2.0f) * scaleY)

                        if ((x2 - x1) * (y2 - y1) >= minArea) {
                            rawDets.add(
                                DetectionBox(
                                    boundingBox = RectF(x1, y1, x2, y2),
                                    confidence = maxScore,
                                    classId = bestCls,
                                    className = classNames[bestCls]
                                )
                            )
                        }
                    }
                }
            }

            // 4. Class-Agnostic Non-Maximum Suppression (IoU)
            val sorted = rawDets.sortedByDescending { it.confidence }
            val kept = mutableListOf<DetectionBox>()

            for (d in sorted) {
                var overlap = false
                for (k in kept) {
                    if (computeIoU(d.boundingBox, k.boundingBox) > iouThreshold) {
                        overlap = true
                        break
                    }
                }
                if (!overlap) {
                    kept.add(d)
                    if (kept.size >= 6) break
                }
            }

            // 5. Sort left to right
            return kept.sortedBy { it.boundingBox.centerX() }

        } catch (e: Exception) {
            return emptyList()
        }
    }

    private fun computeIoU(a: RectF, b: RectF): Float {
        val interLeft = max(a.left, b.left)
        val interTop = max(a.top, b.top)
        val interRight = min(a.right, b.right)
        val interBottom = min(a.bottom, b.bottom)

        val interW = max(0f, interRight - interLeft)
        val interH = max(0f, interBottom - interTop)
        val interArea = interW * interH

        if (interArea <= 0f) return 0f

        val areaA = (a.right - a.left) * (a.bottom - a.top)
        val areaB = (b.right - b.left) * (b.bottom - b.top)
        val unionArea = areaA + areaB - interArea

        return if (unionArea > 0f) interArea / unionArea else 0f
    }

    /**
     * Runs U2-Net neural segmentation to extract the exact fingertip mask.
     */
    fun segmentFingertip(bitmap: Bitmap, thresh: Float = 0.30f): BooleanArray {
        val w = bitmap.width
        val h = bitmap.height

        if (u2netInterpreter == null) {
            return buildEllipseFallbackMask(w, h)
        }

        return try {
            val resized = Bitmap.createScaledBitmap(bitmap, 320, 320, true)
            val inputBuffer = ByteBuffer.allocateDirect(1 * 320 * 320 * 3 * 4).apply {
                order(ByteOrder.nativeOrder())
            }

            val pixels = IntArray(320 * 320)
            resized.getPixels(pixels, 0, 320, 0, 0, 320, 320)

            for (color in pixels) {
                inputBuffer.putFloat(((color shr 16) and 0xFF) / 255.0f)
                inputBuffer.putFloat(((color shr 8) and 0xFF) / 255.0f)
                inputBuffer.putFloat((color and 0xFF) / 255.0f)
            }

            val outputBuffer = ByteBuffer.allocateDirect(1 * 320 * 320 * 1 * 4).apply {
                order(ByteOrder.nativeOrder())
            }
            u2netInterpreter?.run(inputBuffer, outputBuffer)
            outputBuffer.rewind()

            val probMap = FloatArray(320 * 320) { outputBuffer.float }

            val rawMask = ByteArray(w * h)
            for (y in 0 until h) {
                val sy = (y.toFloat() / h * 319f).coerceIn(0f, 319f)
                val y0 = sy.toInt(); val y1 = min(319, y0 + 1); val dy = sy - y0
                for (x in 0 until w) {
                    val sx = (x.toFloat() / w * 319f).coerceIn(0f, 319f)
                    val x0 = sx.toInt(); val x1 = min(319, x0 + 1); val dx = sx - x0
                    val pTop = probMap[y0 * 320 + x0] * (1f - dx) + probMap[y0 * 320 + x1] * dx
                    val pBot = probMap[y1 * 320 + x0] * (1f - dx) + probMap[y1 * 320 + x1] * dx
                    rawMask[y * w + x] = if ((pTop * (1f - dy) + pBot * dy) > thresh) 1 else 0
                }
            }

            val cleanMask = applyConvexHullMask(rawMask, w, h)
            val result = BooleanArray(w * h)
            for (i in cleanMask.indices) result[i] = cleanMask[i] == 1.toByte()
            result
        } catch (e: Exception) {
            buildEllipseFallbackMask(w, h)
        }
    }

    private fun applyConvexHullMask(rawMask: ByteArray, w: Int, h: Int): ByteArray {
        var minX = w; var maxX = 0; var minY = h; var maxY = 0
        var count = 0
        for (y in 0 until h) {
            for (x in 0 until w) {
                if (rawMask[y * w + x] == 1.toByte()) {
                    count++
                    if (x < minX) minX = x; if (x > maxX) maxX = x
                    if (y < minY) minY = y; if (y > maxY) maxY = y
                }
            }
        }

        if (count == 0) return rawMask

        val pts = mutableListOf<Pair<Int, Int>>()
        for (y in minY..maxY step max(1, (maxY - minY) / 120)) {
            for (x in minX..maxX step max(1, (maxX - minX) / 120)) {
                if (rawMask[y * w + x] == 1.toByte()) pts.add(Pair(x, y))
            }
        }

        if (pts.size < 3) {
            val clean = ByteArray(w * h)
            for (y in minY..maxY) for (x in minX..maxX) clean[y * w + x] = 1
            return clean
        }

        val hull = jarvisMarch(pts)
        return fillPolygon(hull, w, h)
    }

    private fun jarvisMarch(pts: List<Pair<Int, Int>>): List<Pair<Int, Int>> {
        if (pts.size < 3) return pts
        val n = pts.size
        val hull = mutableListOf<Pair<Int, Int>>()

        var start = 0
        for (i in 1 until n) if (pts[i].first < pts[start].first) start = i

        var cur = start
        do {
            hull.add(pts[cur])
            var next = (cur + 1) % n
            for (i in 0 until n) {
                val cross = cross(pts[cur], pts[next], pts[i])
                if (cross < 0) next = i
            }
            cur = next
        } while (cur != start && hull.size < n)

        return hull
    }

    private fun cross(o: Pair<Int, Int>, a: Pair<Int, Int>, b: Pair<Int, Int>): Long {
        return (a.first - o.first).toLong() * (b.second - o.second) -
                (a.second - o.second).toLong() * (b.first - o.first)
    }

    private fun fillPolygon(hull: List<Pair<Int, Int>>, w: Int, h: Int): ByteArray {
        val out = ByteArray(w * h)
        if (hull.isEmpty()) return out

        val minY = hull.minOf { it.second }.coerceIn(0, h - 1)
        val maxY = hull.maxOf { it.second }.coerceIn(0, h - 1)
        val n = hull.size

        for (y in minY..maxY) {
            val intersects = mutableListOf<Int>()
            for (i in 0 until n) {
                val p1 = hull[i]; val p2 = hull[(i + 1) % n]
                val y1 = p1.second; val y2 = p2.second
                if ((y1 <= y && y2 > y) || (y2 <= y && y1 > y)) {
                    val xIntersect = p1.first + (y - y1).toFloat() / (y2 - y1) * (p2.first - p1.first)
                    intersects.add(xIntersect.toInt())
                }
            }
            intersects.sort()
            var i = 0
            while (i + 1 < intersects.size) {
                val x1 = intersects[i].coerceIn(0, w - 1)
                val x2 = intersects[i + 1].coerceIn(0, w - 1)
                for (x in x1..x2) out[y * w + x] = 1
                i += 2
            }
        }
        return out
    }

    private fun buildEllipseFallbackMask(w: Int, h: Int): BooleanArray {
        val cx = w / 2.0; val cy = h * 0.48; val rx = w * 0.47; val ry = h * 0.49
        return BooleanArray(w * h) { idx ->
            val x = idx % w; val y = idx / w
            val dx = (x - cx) / rx; val dy = (y - cy) / ry
            (dx * dx + dy * dy) <= 1.0
        }
    }

    fun evaluateLiveness(bitmap: Bitmap): LivenessResult {
        val width = bitmap.width
        val height = bitmap.height
        val rawPixels = IntArray(width * height)
        bitmap.getPixels(rawPixels, 0, width, 0, 0, width, height)

        var sum = 0.0; var sqSum = 0.0
        val count = (width * height).toDouble()
        for (p in rawPixels) {
            val gray = 0.299 * ((p shr 16) and 0xFF) + 0.587 * ((p shr 8) and 0xFF) + 0.114 * (p and 0xFF)
            sum += gray; sqSum += gray * gray
        }
        val mean = sum / count
        val variance = (sqSum / count) - (mean * mean)
        val score = (variance / 850.0).coerceIn(0.30, 0.98).toFloat()

        return LivenessResult(isLive = score >= 0.45f, liveScore = score, spoofScore = 1.0f - score)
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MINUTIAENET ON-DEVICE NEURAL MINUTIAE EXTRACTION (best_f1.pth -> TFLite)
    // ─────────────────────────────────────────────────────────────────────────
    fun extractMinutiaeNet(
        bitmap: Bitmap,
        threshold: Float = 0.28f,
        nmsSize: Int = 5
    ): List<MinutiaPoint> {
        val interpreter = minutiaeInterpreter ?: return emptyList()
        val origW = bitmap.width
        val origH = bitmap.height

        try {
            // 1. Resize to 256x256 grayscale float buffer [1, 256, 256, 1] normalized [0, 1]
            val resized = Bitmap.createScaledBitmap(bitmap, 256, 256, true)
            val inputBuffer = ByteBuffer.allocateDirect(1 * 256 * 256 * 1 * 4).apply {
                order(ByteOrder.nativeOrder())
            }

            val pixels = IntArray(256 * 256)
            resized.getPixels(pixels, 0, 256, 0, 0, 256, 256)

            for (color in pixels) {
                val r = (color shr 16) and 0xFF
                val g = (color shr 8) and 0xFF
                val b = color and 0xFF
                val gray = (0.299f * r + 0.587f * g + 0.114f * b) / 255.0f
                inputBuffer.putFloat(gray)
            }
            inputBuffer.rewind()

            // 2. Prepare 4 output head arrays matching MinutiaeNet [1, 64, 64, 1]
            val locOut = Array(1) { Array(64) { Array(64) { FloatArray(1) } } }
            val cosOut = Array(1) { Array(64) { Array(64) { FloatArray(1) } } }
            val sinOut = Array(1) { Array(64) { Array(64) { FloatArray(1) } } }
            val typOut = Array(1) { Array(64) { Array(64) { FloatArray(1) } } }

            val outputs = mapOf(
                0 to locOut,
                1 to cosOut,
                2 to sinOut,
                3 to typOut
            )

            interpreter.runForMultipleInputsOutputs(arrayOf(inputBuffer), outputs)

            // 3. Local Maximum Peak Detection (NMS) with Dark Ridge Presence Filter
            val minutiae = mutableListOf<MinutiaPoint>()
            val nmsRadius = nmsSize / 2
            val sx = origW.toDouble() / 64.0
            val sy = origH.toDouble() / 64.0

            val origPixels = IntArray(origW * origH)
            bitmap.getPixels(origPixels, 0, origW, 0, 0, origW, origH)

            for (y in 2 until 62) {
                for (x in 2 until 62) {
                    val score = locOut[0][y][x][0]
                    if (score < threshold) continue

                    var isMax = true
                    for (dy in -nmsRadius..nmsRadius) {
                        for (dx in -nmsRadius..nmsRadius) {
                            if (dy == 0 && dx == 0) continue
                            val ny = (y + dy).coerceIn(0, 63)
                            val nx = (x + dx).coerceIn(0, 63)
                            if (locOut[0][ny][nx][0] > score) {
                                isMax = false
                                break
                            }
                        }
                        if (!isMax) break
                    }

                    if (isMax) {
                        val px = ((x + 0.5) * sx).toInt().coerceIn(0, origW - 1)
                        val py = ((y + 0.5) * sy).toInt().coerceIn(0, origH - 1)

                        // Strict Ridge Presence Verification: Minutiae cannot exist on pure white background
                        var hasDarkRidge = false
                        val checkR = 5
                        for (cy in -checkR..checkR) {
                            for (cx in -checkR..checkR) {
                                val nx = (px + cx).coerceIn(0, origW - 1)
                                val ny = (py + cy).coerceIn(0, origH - 1)
                                val p = origPixels[ny * origW + nx]
                                val r = (p shr 16) and 0xFF
                                val g = (p shr 8) and 0xFF
                                val b = p and 0xFF
                                if ((0.299 * r + 0.587 * g + 0.114 * b) < 135.0) {
                                    hasDarkRidge = true
                                    break
                                }
                            }
                            if (hasDarkRidge) break
                        }
                        if (!hasDarkRidge) continue // Reject ghost points in empty white space

                        val cosVal = cosOut[0][y][x][0]
                        val sinVal = sinOut[0][y][x][0]
                        val typVal = typOut[0][y][x][0]
                        val angle = kotlin.math.atan2(sinVal.toDouble(), cosVal.toDouble())
                        val typeStr = if (typVal > 0.5f) "BIF" else "RIG"

                        minutiae.add(
                            MinutiaPoint(
                                x = px,
                                y = py,
                                direction = angle,
                                type = typeStr,
                                quality = score.toDouble()
                            )
                        )
                    }
                }
            }

            return minutiae
        } catch (e: Exception) {
            return emptyList()
        }
    }

    fun close() {
        u2netInterpreter?.close()
        yoloInterpreter?.close()
        minutiaeInterpreter?.close()
    }
}
