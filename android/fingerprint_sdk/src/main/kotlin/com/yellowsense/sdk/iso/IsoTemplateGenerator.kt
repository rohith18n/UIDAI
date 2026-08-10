package com.yellowsense.sdk.iso

import android.util.Base64
import java.nio.ByteBuffer
import java.nio.ByteOrder
import kotlin.math.PI

/**
 * Minutian Data Class representing a detected fingerprint feature point.
 */
data class MinutiaPoint(
    val x: Int,
    val y: Int,
    val direction: Double, // Angle in radians (-PI to PI or 0 to 2*PI)
    val type: String,      // "RIG" / "ENDING" or "BIF" / "BIFURCATION"
    val quality: Double = 1.0
)

/**
 * ISO/IEC 19794-4 Standard Biometric Template Generator.
 * Encodes fingerprint minutiae features into standardized 28-byte header binary format.
 */
object IsoTemplateGenerator {

    private const val MAGIC_HEADER = "FMR\u0000" // 4 bytes
    private const val VERSION = "20"            // 2 bytes '2', '0'
    private const val DPI_500_IN_PPCM = 197     // 500 DPI converted to pixels per cm

    /**
     * Generates a 28-byte header ISO 19794-4 binary template from minutiae points.
     */
    fun generateIsoTemplateBytes(
        minutiae: List<MinutiaPoint>,
        imageWidth: Int = 320,
        imageHeight: Int = 320
    ): ByteArray {
        val minutiaeCount = minutiae.size
        // 28 bytes header + 6 bytes per minutia
        val totalLength = 28 + (minutiaeCount * 6)

        val buffer = ByteBuffer.allocate(totalLength)
        buffer.order(ByteOrder.BIG_ENDIAN)

        // 1. Format Identifier: 'F', 'M', 'R', '\0' (4 bytes)
        buffer.put('F'.code.toByte())
        buffer.put('M'.code.toByte())
        buffer.put('R'.code.toByte())
        buffer.put(0.toByte())

        // 2. Version: '2', '0' (2 bytes)
        buffer.put('2'.code.toByte())
        buffer.put('0'.code.toByte())

        // 3. Record Length (4 bytes)
        buffer.putInt(totalLength)

        // 4. Capture Device Equipment Compliance ID (2 bytes)
        buffer.putShort(0.toShort())

        // 5. Image Size X (Width in pixels) (2 bytes)
        buffer.putShort(imageWidth.toShort())

        // 6. Image Size Y (Height in pixels) (2 bytes)
        buffer.putShort(imageHeight.toShort())

        // 7. X Resolution (Pixels per cm) (2 bytes)
        buffer.putShort(DPI_500_IN_PPCM.toShort())

        // 8. Y Resolution (Pixels per cm) (2 bytes)
        buffer.putShort(DPI_500_IN_PPCM.toShort())

        // 9. Number of Finger Views (1 byte)
        buffer.put(1.toByte())

        // 10. Reserved Byte (1 byte)
        buffer.put(0.toByte())

        // 11. Impression Type (1 byte: 0 = Live-scan plain)
        buffer.put(0.toByte())

        // 12. Finger Quality (1 byte: 100 = Excellent)
        buffer.put(100.toByte())

        // 13. Number of Minutiae (1 byte)
        buffer.put(minutiaeCount.coerceAtMost(255).toByte())

        // Minutiae Record Payloads (6 bytes each)
        for (m in minutiae) {
            val x = m.x.coerceIn(0, imageWidth)
            val y = m.y.coerceIn(0, imageHeight)

            // Normalize angle to [0, 255]
            var normAngle = ((m.direction + PI) / (2 * PI)) * 255.0
            if (normAngle < 0) normAngle = 0.0
            if (normAngle > 255) normAngle = 255.0
            val angleByte = normAngle.toInt() and 0xFF

            // Minutiae Type: 1 = Ridge Ending, 2 = Bifurcation, 0 = Other
            val typeByte = if (m.type.contains("RIG", ignoreCase = true) || m.type.contains("ENDING", ignoreCase = true)) {
                1
            } else if (m.type.contains("BIF", ignoreCase = true)) {
                2
            } else {
                0
            }

            buffer.putShort(x.toShort())
            buffer.putShort(y.toShort())
            buffer.put(angleByte.toByte())
            buffer.put(typeByte.toByte())
        }

        return buffer.array()
    }

    /**
     * Generates Base64 encoded ISO/IEC 19794-4 template string.
     */
    fun generateIsoTemplateBase64(
        minutiae: List<MinutiaPoint>,
        imageWidth: Int = 320,
        imageHeight: Int = 320
    ): String {
        val bytes = generateIsoTemplateBytes(minutiae, imageWidth, imageHeight)
        return Base64.encodeToString(bytes, Base64.NO_WRAP)
    }
}
