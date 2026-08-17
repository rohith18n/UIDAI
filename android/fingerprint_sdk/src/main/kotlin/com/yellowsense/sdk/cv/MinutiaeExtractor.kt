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
        maxPoints: Int = 85
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

        // ── 2. Create Foreground Tissue Mask with moderate boundary erosion ──
        val tissueMask = ByteArray(width * height)
        val boxR = 6
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
                if (ridgeCount >= 3) {
                    for (cy in y until min(height, y + 4)) {
                        for (cx in x until min(width, x + 4)) {
                            tissueMask[cy * width + cx] = 1
                        }
                    }
                }
            }
        }

        // Erode tissue mask by 8 pixels (preserves valid core/delta while avoiding boundary cuts)
        val validRegion = erodeMask(tissueMask, width, height, radius = 8)

        // ── 3. Zhang-Suen Morphological Skeletonization (Thinning) ────────────
        val skeleton = zhangSuenThinning(binary.copyOf(), width, height)

        // ── 4. Rutovitz Crossing Number & Connected-Path Angle Tracing ─────────
        val rawCandidates = mutableListOf<MinutiaPoint>()

        // 8-neighbor offsets in clockwise order:
        // P0=(x,y-1), P1=(x+1,y-1), P2=(x+1,y), P3=(x+1,y+1),
        // P4=(x,y+1), P5=(x-1,y+1), P6=(x-1,y), P7=(x-1,y-1)
        val dx = intArrayOf(0, 1, 1, 1, 0, -1, -1, -1)
        val dy = intArrayOf(-1, -1, 0, 1, 1, 1, 0, -1)

        val margin = 8
        for (y in margin until height - margin) {
            for (x in margin until width - margin) {
                val idx = y * width + x
                if (skeleton[idx] != 1.toByte() || validRegion[idx] != 1.toByte()) continue

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

                if (cn == 1 && neighborCount == 1) {
                    // ── RIDGE ENDING (RIG) ──────────────────────────────────
                    // Trace single skeleton path inward along the ridge (avoiding crosstalk from other ridges)
                    val (pathLen, angle) = traceEndingRidgePath(skeleton, width, height, x, y, dx, dy)
                    if (pathLen >= 3) {
                        val cx = width / 2.0
                        val cy = height / 2.0
                        val normDist = sqrt((x - cx) * (x - cx) + (y - cy) * (y - cy)) / (width / 2.0)
                        val qual = (0.98 - normDist * 0.15).coerceIn(0.75, 0.98)
                        rawCandidates.add(MinutiaPoint(x, y, angle, "RIG", qual))
                    }
                } else if (cn == 3 && neighborCount == 3) {
                    // ── RIDGE BIFURCATION (BIF) ─────────────────────────────
                    // Trace all 3 branches from the fork to verify valid bifurcation & compute trunk angle
                    val (validBif, angle) = traceBifurcationBranches(skeleton, width, height, x, y, dx, dy)
                    if (validBif) {
                        val cx = width / 2.0
                        val cy = height / 2.0
                        val normDist = sqrt((x - cx) * (x - cx) + (y - cy) * (y - cy)) / (width / 2.0)
                        val qual = (0.98 - normDist * 0.15).coerceIn(0.75, 0.98)
                        rawCandidates.add(MinutiaPoint(x, y, angle, "BIF", qual))
                    }
                }
            }
        }

        // ── 5. Spurious Minutiae Filtering (Broken ridges & Spurious Opposites) ─
        val filtered = filterSpuriousMinutiae(rawCandidates)

        // ── 6. Uniform Multi-Grid Spatial NMS (High-yield balanced distribution) ─
        return performUniformSpatialNms(filtered, width, height, maxPoints)
    }

    /**
     * Follows the 8-connected skeleton path from a ridge ending to calculate its true orientation.
     */
    private fun traceEndingRidgePath(
        skeleton: ByteArray,
        w: Int,
        h: Int,
        startX: Int,
        startY: Int,
        dx: IntArray,
        dy: IntArray
    ): Pair<Int, Double> {
        var currX = startX
        var currY = startY
        var prevX = startX
        var prevY = startY
        var pathLen = 0

        for (step in 1..10) {
            var nextX = -1
            var nextY = -1

            for (i in 0 until 8) {
                val nx = currX + dx[i]
                val ny = currY + dy[i]
                if (nx in 0 until w && ny in 0 until h) {
                    if (skeleton[ny * w + nx] == 1.toByte() && !(nx == prevX && ny == prevY)) {
                        nextX = nx
                        nextY = ny
                        break
                    }
                }
            }

            if (nextX == -1) break
            prevX = currX
            prevY = currY
            currX = nextX
            currY = nextY
            pathLen++
        }

        val angle = if (pathLen > 0) {
            atan2((currY - startY).toDouble(), (currX - startX).toDouble())
        } else 0.0

        return Pair(pathLen, angle)
    }

    /**
     * Traces the 3 diverging branches of a bifurcation to reject spurs and find the trunk direction.
     */
    private fun traceBifurcationBranches(
        skeleton: ByteArray,
        w: Int,
        h: Int,
        startX: Int,
        startY: Int,
        dx: IntArray,
        dy: IntArray
    ): Pair<Boolean, Double> {
        val branchNeighbors = mutableListOf<Pair<Int, Int>>()
        for (i in 0 until 8) {
            val nx = startX + dx[i]
            val ny = startY + dy[i]
            if (nx in 0 until w && ny in 0 until h && skeleton[ny * w + nx] == 1.toByte()) {
                branchNeighbors.add(Pair(nx, ny))
            }
        }

        if (branchNeighbors.size < 3) return Pair(false, 0.0)

        val branchAngles = mutableListOf<Double>()
        var shortestBranch = 99

        for (bn in branchNeighbors.take(3)) {
            var currX = bn.first
            var currY = bn.second
            var prevX = startX
            var prevY = startY
            var bLen = 1

            for (step in 2..8) {
                var nextX = -1
                var nextY = -1
                for (i in 0 until 8) {
                    val nx = currX + dx[i]
                    val ny = currY + dy[i]
                    if (nx in 0 until w && ny in 0 until h) {
                        if (skeleton[ny * w + nx] == 1.toByte() && !(nx == prevX && ny == prevY)) {
                            nextX = nx
                            nextY = ny
                            break
                        }
                    }
                }
                if (nextX == -1) break
                prevX = currX
                prevY = currY
                currX = nextX
                currY = nextY
                bLen++
            }

            if (bLen < shortestBranch) shortestBranch = bLen
            branchAngles.add(atan2((currY - startY).toDouble(), (currX - startX).toDouble()))
        }

        // If any branch terminates too quickly (< 3 px), it is a spur artifact
        if (shortestBranch < 3) return Pair(false, 0.0)

        // The bifurcation orientation is the average angle pointing inward from the fork
        var sumCos = 0.0
        var sumSin = 0.0
        for (a in branchAngles) {
            sumCos += cos(a)
            sumSin += sin(a)
        }
        val angle = atan2(sumSin, sumCos)

        return Pair(true, angle)
    }

    /**
     * Filters out opposing broken-ridge endings and excessively close false minutiae.
     */
    private fun filterSpuriousMinutiae(candidates: List<MinutiaPoint>): List<MinutiaPoint> {
        val keep = BooleanArray(candidates.size) { true }

        for (i in candidates.indices) {
            if (!keep[i]) continue
            val m1 = candidates[i]

            for (j in i + 1 until candidates.size) {
                if (!keep[j]) continue
                val m2 = candidates[j]

                val dSq = (m1.x - m2.x) * (m1.x - m2.x) + (m1.y - m2.y) * (m1.y - m2.y)

                // 1. Broken ridge artifact: two endings within 12px facing each other (~180° opposite)
                if (dSq <= 144 && m1.type == "RIG" && m2.type == "RIG") {
                    var diffAngle = abs(m1.direction - m2.direction)
                    if (diffAngle > Math.PI) diffAngle = (2 * Math.PI - diffAngle)
                    if (diffAngle > Math.PI * 0.65) {
                        keep[i] = false
                        keep[j] = false
                        break
                    }
                }

                // 2. Overlapping duplicate minutiae within 8px
                if (dSq <= 64) {
                    if (m1.quality >= m2.quality) {
                        keep[j] = false
                    } else {
                        keep[i] = false
                        break
                    }
                }
            }
        }

        return candidates.filterIndexed { idx, _ -> keep[idx] }
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
                for (dy in -r..r step 2) {
                    for (dx in -r..r step 2) {
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
     * minutiae points are distributed evenly across the entire fingerprint pattern.
     */
    private fun performUniformSpatialNms(
        candidates: List<MinutiaPoint>,
        w: Int,
        h: Int,
        maxPoints: Int
    ): List<MinutiaPoint> {
        if (candidates.isEmpty()) return emptyList()

        // 1. Grid of spatial buckets (5 cols x 5 rows)
        val gridCols = 5
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

        // 2. Minimum distance threshold between any two minutiae points (10px or 3.5% of dimension)
        val minDistance = max(10.0, (min(w, h) * 0.035).toDouble())
        val minDistSq = minDistance * minDistance

        // 3. Maximum points per grid bucket
        val maxPerBucket = 5
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
                            val dX = (cand.x - s.x).toDouble()
                            val dY = (cand.y - s.y).toDouble()
                            if (dX * dX + dY * dY < minDistSq) {
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
     * Renders crisp, professional biometric target overlays.
     * Hollow contrasting rings + pinpoint center + true directional ridge vectors.
     * Ridge pattern underneath remains 100% visible and sharp.
     */
    fun drawVisualization(
        preprocessedFIR: Bitmap,
        minutiae: List<MinutiaPoint>
    ): Bitmap {
        val vis = preprocessedFIR.copy(Bitmap.Config.ARGB_8888, true)
        val canvas = Canvas(vis)

        val diag = sqrt((vis.width * vis.width + vis.height * vis.height).toDouble())
        val outerRadius = max(4.0f, (diag * 0.010f).toFloat())
        val centerDotRadius = max(1.2f, (diag * 0.003f).toFloat())
        val arrowLength = max(10.0f, (diag * 0.024f).toFloat())
        val strokeWidth = max(1.5f, (diag * 0.0032f).toFloat())

        // Emerald Green for Endings (RIG) - #00C853
        val rigStrokePaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            color = Color.rgb(0, 200, 83)
            style = Paint.Style.STROKE
            this.strokeWidth = strokeWidth
        }
        val rigFillPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            color = Color.rgb(0, 200, 83)
            style = Paint.Style.FILL
        }

        // Royal Electric Blue for Bifurcations (BIF) - #0091EA
        val bifStrokePaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            color = Color.rgb(0, 145, 234)
            style = Paint.Style.STROKE
            this.strokeWidth = strokeWidth
        }
        val bifFillPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            color = Color.rgb(0, 145, 234)
            style = Paint.Style.FILL
        }

        // White shadow/halo paint for high-contrast visibility against dark ridges
        val haloPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            color = Color.WHITE
            style = Paint.Style.STROKE
            this.strokeWidth = strokeWidth + 1.2f
        }

        for (m in minutiae) {
            val isRig = m.type == "RIG"
            val strokePaint = if (isRig) rigStrokePaint else bifStrokePaint
            val fillPaint = if (isRig) rigFillPaint else bifFillPaint

            val cx = m.x.toFloat()
            val cy = m.y.toFloat()

            // Directional flow vector line with subtle pointer
            val dx = (arrowLength * cos(m.direction)).toFloat()
            val dy = (arrowLength * sin(m.direction)).toFloat()
            val endX = cx + dx
            val endY = cy + dy

            // 1. Halo outline for crisp contrast
            canvas.drawCircle(cx, cy, outerRadius, haloPaint)
            canvas.drawLine(cx, cy, endX, endY, haloPaint)

            // 2. Hollow concentric target ring
            canvas.drawCircle(cx, cy, outerRadius, strokePaint)

            // 3. Precise pinpoint center dot
            canvas.drawCircle(cx, cy, centerDotRadius, fillPaint)

            // 4. Directional vector line
            canvas.drawLine(cx, cy, endX, endY, strokePaint)

            // 5. Sleek directional pointer tip
            val tipAngle1 = m.direction + Math.PI * 0.82
            val tipAngle2 = m.direction - Math.PI * 0.82
            val tipLen = arrowLength * 0.28f
            canvas.drawLine(endX, endY, (endX + tipLen * cos(tipAngle1)).toFloat(), (endY + tipLen * sin(tipAngle1)).toFloat(), strokePaint)
            canvas.drawLine(endX, endY, (endX + tipLen * cos(tipAngle2)).toFloat(), (endY + tipLen * sin(tipAngle2)).toFloat(), strokePaint)
        }

        return vis
    }
}
