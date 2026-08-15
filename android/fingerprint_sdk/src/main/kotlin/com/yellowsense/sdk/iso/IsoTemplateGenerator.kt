package com.yellowsense.sdk.iso

import android.util.Base64
import java.nio.ByteBuffer
import java.nio.ByteOrder
import kotlin.math.PI

/**
 * Minutia Data Class representing a detected fingerprint feature point.
 */
data class MinutiaPoint(
    val x: Int,
    val y: Int,
    val direction: Double, // Angle in radians (-PI to PI or 0 to 2*PI)
    val type: String,      // "RIG" (Ridge Ending) or "BIF" (Bifurcation)
    val quality: Double = 1.0
)

/**
 * Standard ISO 19794-2 Fingerprint Template Generator.
 * Directly matches UIDAI backend `export_iso_template` structure (FMR + version + count + records).
 */
object IsoTemplateGenerator {

    /**
     * Generates standard ISO/IEC 19794-2 binary template bytes.
     */
    fun generateIsoTemplateBytes(
        minutiae: List<MinutiaPoint>,
        imageWidth: Int = 320,
        imageHeight: Int = 320
    ): ByteArray {
        val count = minutiae.size
        // 3 bytes 'FMR' + 2 bytes version (1) + 2 bytes count + (6 bytes * count)
        val totalLength = 7 + (count * 6)

        val buffer = ByteBuffer.allocate(totalLength)
        buffer.order(ByteOrder.BIG_ENDIAN)

        // 1. Magic Header 'FMR'
        buffer.put('F'.code.toByte())
        buffer.put('M'.code.toByte())
        buffer.put('R'.code.toByte())

        // 2. Version (1)
        buffer.putShort(1.toShort())

        // 3. Minutiae Count
        buffer.putShort(count.toShort())

        // 4. Minutiae Payloads (>HHBB: x, y, angle, type)
        for (m in minutiae) {
            val x = m.x.coerceIn(0, 65535)
            val y = m.y.coerceIn(0, 65535)

            var normAngle = ((m.direction + PI) / (2 * PI)) * 255.0
            if (normAngle < 0.0) normAngle = 0.0
            if (normAngle > 255.0) normAngle = 255.0
            val angleByte = normAngle.toInt() and 0xFF

            val typeByte = if (m.type.contains("RIG", ignoreCase = true) || m.type.contains("ENDING", ignoreCase = true)) {
                1
            } else {
                2
            }

            buffer.putShort(x.toShort())
            buffer.putShort(y.toShort())
            buffer.put(angleByte.toByte())
            buffer.put(typeByte.toByte())
        }

        return buffer.array()
    }

    /**
     * Generates Base64 encoded ISO/IEC 19794-2 template string.
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
