package com.bluevale.segmeris

import java.io.ByteArrayOutputStream
import java.io.DataOutputStream
import java.io.File
import org.junit.Assert.*
import org.junit.Test

class Mp4DurationTest {
    private fun box(type: String, body: ByteArray): ByteArray {
        val output = ByteArrayOutputStream()
        DataOutputStream(output).use { it.writeInt(body.size + 8); it.writeBytes(type); it.write(body) }
        return output.toByteArray()
    }
    private fun movie(milliseconds: Int): ByteArray {
        val header = ByteArrayOutputStream()
        DataOutputStream(header).use {
            it.writeInt(0); it.writeLong(0); it.writeInt(1000); it.writeInt(milliseconds)
        }
        return box("moov", box("mvhd", header.toByteArray()))
    }
    private fun duration(bytes: ByteArray): Long? {
        val file = File.createTempFile("segmeris-duration", ".mp4")
        return try { file.writeBytes(bytes); Mp4Duration.readMs(file.absolutePath) } finally { file.delete() }
    }
    @Test fun readsFinalizedMovieDuration() { assertEquals(18000L, duration(movie(18000))) }
    @Test fun rejectsFragmentedSixSecondHeader() {
        assertNull(duration(movie(6000) + box("moof", byteArrayOf())))
    }
    @Test fun rejectsConcatenatedMovieHeaders() { assertNull(duration(movie(6000) + movie(6000))) }
    @Test fun rejectsUnknownDurationSentinel() { assertNull(duration(movie(-1))) }
    @Test fun rejectsTruncatedAndZeroDurationMovies() {
        assertNull(duration(movie(0)))
        assertNull(duration(movie(18000).dropLast(1).toByteArray()))
    }
}
