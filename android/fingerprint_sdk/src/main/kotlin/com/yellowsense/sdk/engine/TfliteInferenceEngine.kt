package com.yellowsense.sdk.engine

import android.content.Context
import android.graphics.Bitmap
import android.graphics.RectF
import org.tensorflow.lite.Interpreter
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

            // 2. Run inference: Output shape is [1, 8, 13125]
            val outputBuffer = ByteBuffer.allocateDirect(1 * 8 * 13125 * 4).apply {
                order(ByteOrder.nativeOrder())
            }
            yolo.run(inputBuffer, outputBuffer)
            outputBuffer.rewind()

            // 3. Read output tensor: 8 rows x 13125 columns
            // row 0: cx, row 1: cy, row 2: w, row 3: h
            // rows 4..7: class scores (0: FingerTips, 1: FingerTips-2DFX, 2: Fingerprint, 3: finger)
            val classNames = arrayOf("FingerTips", "FingerTips-2DFX", "Fingerprint", "finger")
            val numCols = 13125
            val out = Array(8) { FloatArray(numCols) }
            for (row in 0 until 8) {
                for (col in 0 until numCols) {
                    out[row][col] = outputBuffer.float
                }
            }

            val rawDets = mutableListOf<DetectionBox>()
            val scaleX = origW / 800.0f
            val scaleY = origH / 800.0f
            val minArea = (origW * origH) * 0.002f

            for (col in 0 until numCols) {
                val cx = out[0][col]
                val cy = out[1][col]
                val bw = out[2][col]
                val bh = out[3][col]

                // Find max class score
                var maxScore = 0.0f
                var bestCls = 0
                for (cls in 0 until 4) {
                    val score = out[4 + cls][col]
                    if (score > maxScore) {
                        maxScore = score
                        bestCls = cls
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

    fun close() {
        u2netInterpreter?.close()
        yoloInterpreter?.close()
    }
}
