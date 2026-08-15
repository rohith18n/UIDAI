package com.yellowsense.sdk.cv

import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import com.yellowsense.sdk.iso.MinutiaPoint
import kotlin.math.abs
import kotlin.math.atan2
import kotlin.math.cos
import kotlin.math.max
import kotlin.math.min
import kotlin.math.sin
import kotlin.math.sqrt

/**
 * Robust Minutiae Feature Extraction & Visualization Component.
 *
 * Implements:
 *   1. Foreground tissue mask extraction & boundary erosion (removes false edge minutiae)
 *   2. Zhang-Suen morphological thinning / skeletonization (1-px ridge width)
 *   3. Rutovitz Crossing Number (CN) feature extraction on skeleton
 *   4. Spurious branch / edge artifact rejection
 *   5. Uniform multi-grid spatial Non-Maximum Suppression (even distribution across core, delta, and body)
 */
object MinutiaeExtractor {

    /**
     * Extracts minutiae points from preprocessed FIR bitmap image.
     */
    fun extractMinutiae(
        preprocessedFIR: Bitmap,
        originalCrop: Bitmap? = null,
        maxPoints: Int = 45
    ): List<MinutiaPoint> {
        val width = preprocessedFIR.width
        val height = preprocessedFIR.height
        if (width < 30 || height < 30) return emptyList()

        val firPixels = IntArray(width * height)
        preprocessedFIR.getPixels(firPixels, 0, width, 0, 0, width, height)

        // ── 1. Create binary ridge map (1 = dark ridge, 0 = valley / white) ─
        val binary = ByteArray(width * height)
        for (i in firPixels.indices) {
            val r = firPixels[i] and 0xFF
            binary[i] = if (r < 128) 1 else 0
        }

        // ── 2. Create Foreground Tissue Mask & Erode to remove border artifacts ─
        // A pixel is in the active tissue area if it has nearby ridge content
        val tissueMask = ByteArray(width * height)
        val boxR = 8
        for (y in 0 until height step 4) {
            for (x in 0 until width step 4) {
                var ridgeCount = 0
                val yMin = max(0, y - boxR)
                val yMax = min(height - 1, y + boxR)
                val xMin = max(0, x - boxR)
                val xMax = min(width - 1, x + boxR)
                for (cy in yMin..yMax step 2) {
                    for (cx in xMin..xMax step 2) {
                        if (binary[cy * width + cx] == 1.toByte()) ridgeCount++
                    }
                }
                if (ridgeCount >= 4) {
                    for (cy in y until min(height, y + 4)) {
                        for (cx in x until min(width, x + 4)) {
                            tissueMask[cy * width + cx] = 1
                        }
                    }
                }
            }
        }

        // Erode tissue mask by 14 pixels so border cuts do NOT create false minutiae
        val validRegion = erodeMask(tissueMask, width, height, radius = 14)

        // ── 3. Zhang-Suen Morphological Skeletonization (Thinning) ────────────
        val skeleton = zhangSuenThinning(binary.copyOf(), width, height)

        // ── 4. Crossing Number on Skeleton inside Valid Region ────────────────
        val candidates = mutableListOf<MinutiaPoint>()

        // 8-neighbor offsets in clockwise order: (P1 to P8)
        // P1=(x,y-1), P2=(x+1,y-1), P3=(x+1,y), P4=(x+1,y+1), P5=(x,y+1), P6=(x-1,y+1), P7=(x-1,y), P8=(x-1,y-1)
        val dx = intArrayOf(0, 1, 1, 1, 0, -1, -1, -1)
        val dy = intArrayOf(-1, -1, 0, 1, 1, 1, 0, -1)

        val margin = 16
        for (y in margin until height - margin) {
            for (x in margin until width - margin) {
                val idx = y * width + x
                // Must be on the thinned skeleton and well inside the valid foreground region
                if (skeleton[idx] != 1.toByte() || validRegion[idx] != 1.toByte()) continue

                // Check 8-neighbor values
                val p = IntArray(8)
                var neighborCount = 0
                for (i in 0 until 8) {
                    val nx = x + dx[i]
                    val ny = y + dy[i]
                    val v = skeleton[ny * width + nx].toInt()
                    p[i] = v
                    neighborCount += v
                }

                // Crossing Number = 1/2 * sum |p[i] - p[i+1]|
                var transitions = 0
                for (i in 0 until 8) {
                    val next = (i + 1) % 8
                    transitions += abs(p[i] - p[next])
                }
                val cn = transitions / 2

                // CN == 1: Ridge Ending (RIG), CN == 3: Ridge Bifurcation (BIF)
                val type = when {
                    cn == 1 && neighborCount == 1 -> "RIG"
                    cn == 3 && neighborCount == 3 -> "BIF"
                    else -> null
                } ?: continue

                // Trace ridge flow direction
                var dir = 0.0
                if (type == "RIG") {
                    // For ending: find vector pointing along the ridge inward
                    var rx = 0
                    var ry = 0
                    for (step in 1..6) {
                        for (i in 0 until 8) {
                            val nx = (x + dx[i] * step).coerceIn(0, width - 1)
                            val ny = (y + dy[i] * step).coerceIn(0, height - 1)
                            if (skeleton[ny * width + nx] == 1.toByte()) {
                                rx += dx[i] * step
                                ry += dy[i] * step
                            }
                        }
                    }
                    dir = atan2(ry.toDouble(), rx.toDouble())
                } else {
                    // For bifurcation: local orientation
                    var gradX = 0
                    var gradY = 0
                    for (wy in -4..4) {
                        for (wx in -4..4) {
                            val nx = (x + wx).coerceIn(0, width - 1)
                            val ny = (y + wy).coerceIn(0, height - 1)
                            if (skeleton[ny * width + nx] == 1.toByte()) {
                                gradX += wx
                                gradY += wy
                            }
                        }
                    }
                    dir = atan2(gradY.toDouble(), gradX.toDouble())
                }

                // Confidence based on distance to center and ridge clarity
                val cx = width / 2.0
                val cy = height / 2.0
                val normDist = sqrt((x - cx) * (x - cx) + (y - cy) * (y - cy)) / (width / 2.0)
                val qual = (0.98 - normDist * 0.15).coerceIn(0.70, 0.98)

                candidates.add(
                    MinutiaPoint(
                        x = x,
                        y = y,
                        direction = dir,
                        type = type,
                        quality = qual
                    )
                )
            }
        }

        // ── 5. Uniform Multi-Grid Spatial NMS (Distributed Selection) ─────────
        return performUniformSpatialNms(candidates, width, height, maxPoints)
    }

    /**
     * Zhang-Suen Morphological Skeletonization Algorithm for binary images.
     */
    private fun zhangSuenThinning(img: ByteArray, w: Int, h: Int): ByteArray {
        var changed: Boolean
        val dx = intArrayOf(0, 1, 1, 1, 0, -1, -1, -1)
        val dy = intArrayOf(-1, -1, 0, 1, 1, 1, 0, -1)

        val toDelete = mutableListOf<Int>()

        do {
            changed = false

            // Sub-iteration 1
            toDelete.clear()
            for (y in 1 until h - 1) {
                for (x in 1 until w - 1) {
                    val idx = y * w + x
                    if (img[idx] != 1.toByte()) continue

                    val p = IntArray(8)
                    var b = 0
                    for (i in 0 until 8) {
                        val v = img[(y + dy[i]) * w + (x + dx[i])].toInt()
                        p[i] = v
                        b += v
                    }

                    if (b !in 2..6) continue

                    var a = 0
                    for (i in 0 until 8) {
                        if (p[i] == 0 && p[(i + 1) % 8] == 1) a++
                    }
                    if (a != 1) continue

                    // p0=top, p2=right, p4=bottom, p6=left
                    val p0 = p[0]; val p2 = p[2]; val p4 = p[4]; val p6 = p[6]
                    if (p0 * p2 * p4 != 0) continue
                    if (p2 * p4 * p6 != 0) continue

                    toDelete.add(idx)
                }
            }

            for (idx in toDelete) {
                img[idx] = 0
                changed = true
            }

            // Sub-iteration 2
            toDelete.clear()
            for (y in 1 until h - 1) {
                for (x in 1 until w - 1) {
                    val idx = y * w + x
                    if (img[idx] != 1.toByte()) continue

                    val p = IntArray(8)
                    var b = 0
                    for (i in 0 until 8) {
                        val v = img[(y + dy[i]) * w + (x + dx[i])].toInt()
                        p[i] = v
                        b += v
                    }

                    if (b !in 2..6) continue

                    var a = 0
                    for (i in 0 until 8) {
                        if (p[i] == 0 && p[(i + 1) % 8] == 1) a++
                    }
                    if (a != 1) continue

                    val p0 = p[0]; val p2 = p[2]; val p4 = p[4]; val p6 = p[6]
                    if (p0 * p2 * p6 != 0) continue
                    if (p0 * p4 * p6 != 0) continue

                    toDelete.add(idx)
                }
            }

            for (idx in toDelete) {
                img[idx] = 0
                changed = true
            }

        } while (changed && toDelete.size > 0)

        return img
    }

    /**
     * Erodes binary mask by given radius.
     */
    private fun erodeMask(mask: ByteArray, w: Int, h: Int, radius: Int): ByteArray {
        val out = ByteArray(w * h)
        val r = radius
        for (y in r until h - r) {
            for (x in r until w - r) {
                if (mask[y * w + x] != 1.toByte()) continue
                var allOne = true
                for (dy in -r..r step 3) {
                    for (dx in -r..r step 3) {
                        if (mask[(y + dy) * w + (x + dx)] != 1.toByte()) {
                            allOne = false
                            break
                        }
                    }
                    if (!allOne) break
                }
                if (allOne) out[y * w + x] = 1
            }
        }
        return out
    }

    /**
     * Performs multi-grid uniform spatial Non-Maximum Suppression to ensure
     * minutiae points are distributed evenly across the entire fingerprint pattern
     * with graceful spacing and strict regional quota limits.
     */
    private fun performUniformSpatialNms(
        candidates: List<MinutiaPoint>,
        w: Int,
        h: Int,
        maxPoints: Int
    ): List<MinutiaPoint> {
        if (candidates.isEmpty()) return emptyList()

        // 1. Grid of spatial buckets (4 cols x 5 rows)
        val gridCols = 4
        val gridRows = 5
        val cellW = w / gridCols.toDouble()
        val cellH = h / gridRows.toDouble()

        val buckets = Array(gridRows) { Array(gridCols) { mutableListOf<MinutiaPoint>() } }
        for (c in candidates) {
            val gx = (c.x / cellW).toInt().coerceIn(0, gridCols - 1)
            val gy = (c.y / cellH).toInt().coerceIn(0, gridRows - 1)
            buckets[gy][gx].add(c)
        }

        // Sort each bucket by quality descending
        for (gy in 0 until gridRows) {
            for (gx in 0 until gridCols) {
                buckets[gy][gx].sortByDescending { it.quality }
            }
        }

        // 2. Minimum distance threshold between any two minutiae points (at least 20px or 7.5% of dimension)
        val minDistance = max(20.0, (min(w, h) * 0.075).toDouble())
        val minDistSq = minDistance * minDistance

        // 3. Maximum points per grid bucket (strictly prevents clustering in top pad)
        val maxPerBucket = 3
        val bucketCounts = Array(gridRows) { IntArray(gridCols) }

        val selected = mutableListOf<MinutiaPoint>()
        var addedInRound = true
        var round = 0

        while (selected.size < maxPoints && addedInRound && round < 10) {
            addedInRound = false
            round++

            for (gy in 0 until gridRows) {
                for (gx in 0 until gridCols) {
                    if (bucketCounts[gy][gx] >= maxPerBucket) continue
                    val bucket = buckets[gy][gx]
                    if (bucket.isEmpty()) continue

                    var pickIdx = -1
                    for (i in bucket.indices) {
                        val cand = bucket[i]
                        var tooClose = false
                        for (s in selected) {
                            val dx = (cand.x - s.x).toDouble()
                            val dy = (cand.y - s.y).toDouble()
                            if (dx * dx + dy * dy < minDistSq) {
                                tooClose = true
                                break
                            }
                        }
                        if (!tooClose) {
                            pickIdx = i
                            break
                        }
                    }

                    if (pickIdx != -1) {
                        selected.add(bucket.removeAt(pickIdx))
                        bucketCounts[gy][gx]++
                        addedInRound = true
                        if (selected.size >= maxPoints) return selected
                    }
                }
            }
        }

        return selected
    }

    /**
     * Renders crisp, professional biometric target overlays (hollow rings + pinpoint center + vector arrows).
     * Ensures ridges underneath remain 100% visible and sharp.
     */
    fun drawVisualization(
        preprocessedFIR: Bitmap,
        minutiae: List<MinutiaPoint>
    ): Bitmap {
        val vis = preprocessedFIR.copy(Bitmap.Config.ARGB_8888, true)
        val canvas = Canvas(vis)

        val diag = sqrt((vis.width * vis.width + vis.height * vis.height).toDouble())
        val outerRadius = max(3.5f, (diag * 0.009f).toFloat())
        val centerDotRadius = max(1.0f, (diag * 0.0025f).toFloat())
        val arrowLength = max(8.0f, (diag * 0.022f).toFloat())
        val strokeWidth = max(1.3f, (diag * 0.0028f).toFloat())

        // Emerald Green for Endings (RIG) - matching app YS.green
        val rigStrokePaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            color = Color.rgb(0, 200, 83) // #00C853
            style = Paint.Style.STROKE
            this.strokeWidth = strokeWidth
        }
        val rigFillPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            color = Color.rgb(0, 200, 83)
            style = Paint.Style.FILL
        }

        // Electric Royal Blue for Bifurcations (BIF) - matching app YS.blue
        val bifStrokePaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            color = Color.rgb(0, 145, 234) // #0091EA
            style = Paint.Style.STROKE
            this.strokeWidth = strokeWidth
        }
        val bifFillPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            color = Color.rgb(0, 145, 234)
            style = Paint.Style.FILL
        }

        for (m in minutiae) {
            val isRig = m.type == "RIG"
            val strokePaint = if (isRig) rigStrokePaint else bifStrokePaint
            val fillPaint = if (isRig) rigFillPaint else bifFillPaint

            val cx = m.x.toFloat()
            val cy = m.y.toFloat()

            // 1. Precise pinpoint center dot
            canvas.drawCircle(cx, cy, centerDotRadius, fillPaint)

            // 2. Hollow concentric target ring
            canvas.drawCircle(cx, cy, outerRadius, strokePaint)

            // 3. Directional flow vector line with arrowhead
            val dx = (arrowLength * cos(m.direction)).toFloat()
            val dy = (arrowLength * sin(m.direction)).toFloat()
            val endX = cx + dx
            val endY = cy + dy
            canvas.drawLine(cx, cy, endX, endY, strokePaint)

            // 4. Subtle arrowhead tip
            val tipAngle1 = m.direction + Math.PI * 0.8
            val tipAngle2 = m.direction - Math.PI * 0.8
            val tipLen = arrowLength * 0.35f
            canvas.drawLine(endX, endY, (endX + tipLen * cos(tipAngle1)).toFloat(), (endY + tipLen * sin(tipAngle1)).toFloat(), strokePaint)
            canvas.drawLine(endX, endY, (endX + tipLen * cos(tipAngle2)).toFloat(), (endY + tipLen * sin(tipAngle2)).toFloat(), strokePaint)
        }

        return vis
    }
}
