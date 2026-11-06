package com.bluevale.segmeris

import android.media.MediaExtractor
import android.media.MediaFormat
import android.media.MediaMetadataRetriever
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.filters.SdkSuppress
import androidx.test.platform.app.InstrumentationRegistry
import java.io.File
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith

/** Runs the platform muxer/codec on three six-second fMP4 fragments. */
@RunWith(AndroidJUnit4::class)
@SdkSuppress(minSdkVersion = 25)
class MediaDurationInstrumentedTest {
    @Test fun quickRemuxRetainsDurationAndFrames() = roundTrip(0)
    @Test fun fullTranscodeRetainsDurationAndFrames() = roundTrip(250)

    private fun roundTrip(bitrate: Int) {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val assets = instrumentation.context.assets
        val directory = File(instrumentation.targetContext.cacheDir, "duration-test-" + System.nanoTime())
        check(directory.mkdirs())
        try {
            val init = assets.open("hls-duration/init.mp4").use { it.readBytes() }
            repeat(3) { index ->
                File(directory, "video_%05d.part".format(index)).outputStream().use { output ->
                    output.write(init)
                    assets.open("hls-duration/index" + index + ".m4s").use { it.copyTo(output) }
                }
            }
            val result = File(directory, "output.mp4")
            assertTrue(MediaTranscoder.transcodeDir(directory.path, "video", 3, result.path, bitrate, 0, 18_000))
            val containerMs = Mp4Duration.readMs(result.path) ?: -1L
            assertTrue("movie duration: $containerMs", containerMs in 17_500L..19_000L)
            val retriever = MediaMetadataRetriever()
            try {
                retriever.setDataSource(result.path)
                val displayedMs = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION)!!.toLong()
                assertTrue("system duration: $displayedMs", displayedMs in 17_500L..19_000L)
            } finally { retriever.release() }
            val extractor = MediaExtractor()
            try {
                extractor.setDataSource(result.path)
                val video = (0 until extractor.trackCount).first { extractor.getTrackFormat(it).getString(MediaFormat.KEY_MIME)!!.startsWith("video/") }
                extractor.selectTrack(video)
                var frames = 0
                while (extractor.sampleTime >= 0) { frames++; if (!extractor.advance()) break }
                assertEquals("all 180 source frames must survive", 180, frames)
            } finally { extractor.release() }
        } finally { directory.deleteRecursively() }
    }
}
