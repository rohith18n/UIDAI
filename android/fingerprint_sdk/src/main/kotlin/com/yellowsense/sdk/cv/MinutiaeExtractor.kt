package com.yellowsense.sdk.cv

import android.graphics.Bitmap
import com.yellowsense.sdk.iso.MinutiaPoint
import kotlin.math.PI
import kotlin.math.atan2
import kotlin.math.sqrt

/**
 * Minutiae Feature Extraction Component.
 * Extracts ridge endings and bifurcations from preprocessed fingerprint images.
 */
object MinutiaeExtractor {

    /**
     * Extracts minutiae points from preprocessed fingerprint bitmap image.
     */
    fun extractMinutiae(bitmap: Bitmap, maxPoints: Int = 45): List<MinutiaPoint> {
        val width = bitmap.width
        val height = bitmap.height
        val pixels = IntArray(width * height)
        bitmap.getPixels(pixels, 0, width, 0, 0, width, height)

        // Binarize image thresholding
        val binary = BooleanArray(width * height)
        for (i in pixels.indices) {
            val c = pixels[i]
            val gray = (0.299 * ((c shr 16) and 0xFF) + 0.587 * ((c shr 8) and 0xFF) + 0.114 * (c and 0xFF)).toInt()
            binary[i] = gray < 128
        }

        val minutiaeList = mutableListOf<MinutiaPoint>()

        // 8-neighbor crossing number method for skeletonized/preprocessed ridge analysis
        val margin = 15
        for (y in margin until height - margin step 3) {
            for (x in margin until width - margin step 3) {
                val idx = y * width + x
                if (!binary[idx]) continue

                // 8 neighbors order: P2, P3, P4, P5, P6, P7, P8, P9
                val p2 = binary[(y - 1) * width + x]
                val p3 = binary[(y - 1) * width + (x + 1)]
                val p4 = binary[y * width + (x + 1)]
                val p5 = binary[(y + 1) * width + (x + 1)]
                val p6 = binary[(y + 1) * width + x]
                val p7 = binary[(y + 1) * width + (x - 1)]
                val p8 = binary[y * width + (x - 1)]
                val p9 = binary[(y - 1) * width + (x - 1)]

                val neighbors = arrayOf(p2, p3, p4, p5, p6, p7, p8, p9, p2)
                var transitions = 0
                for (n in 0 until 8) {
                    if (!neighbors[n] && neighbors[n + 1]) {
                        transitions++
                    }
                }

                var activeNeighbors = 0
                for (n in 0 until 8) {
                    if (neighbors[n]) activeNeighbors++
                }

                // Crossing Number logic: CN = 1 -> Ridge Ending, CN = 3 -> Bifurcation
                val type = when {
                    activeNeighbors == 1 -> "ENDING"
                    activeNeighbors == 3 -> "BIFURCATION"
                    else -> null
                }

                if (type != null) {
                    // Compute local ridge orientation theta
                    var dx = 0.0
                    var dy = 0.0
                    if (p4) dx += 1.0
                    if (p8) dx -= 1.0
                    if (p6) dy += 1.0
                    if (p2) dy -= 1.0
                    if (p3) { dx += 0.7; dy -= 0.7 }
                    if (p5) { dx += 0.7; dy += 0.7 }
                    if (p7) { dx -= 0.7; dy += 0.7 }
                    if (p9) { dx -= 0.7; dy -= 0.7 }

                    val angle = atan2(dy, dx)

                    // Ensure minimum distance spacing between minutiae (NMS)
                    var tooClose = false
                    for (existing in minutiaeList) {
                        val dist = sqrt(((existing.x - x) * (existing.x - x) + (existing.y - y) * (existing.y - y)).toDouble())
                        if (dist < 10.0) {
                            tooClose = true
                            break
                        }
                    }

                    if (!tooClose) {
                        minutiaeList.add(
                            MinutiaPoint(
                                x = x,
                                y = y,
                                direction = angle,
                                type = type,
                                quality = 0.9
                            )
                        )
                    }
                }

                if (minutiaeList.size >= maxPoints) break
            }
            if (minutiaeList.size >= maxPoints) break
        }

        return minutiaeList
    }
}
