package com.blue.segmeris

import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.IOException
import java.io.InterruptedIOException
import java.nio.file.Files
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import org.junit.Assert.*
import org.junit.Test

class MediaStoreFileIoTest {
    private fun withDirectory(test: (File) -> Unit) {
        val directory = Files.createTempDirectory("segmeris-file-io-").toFile()
        try { test(directory) } finally { directory.deleteRecursively() }
    }

    @Test fun duplicateExportsPreserveUserFileAndUseNumberedNames() = withDirectory { root ->
        val source = File(root, "source.mp4").apply { writeText("new export") }
        val destination = File(root, "downloads").apply { mkdirs() }
        val existing = File(destination, "video.mp4").apply { writeText("user original") }
        val first = MediaStoreHelper.copyToUniqueFile(source, destination, "video.mp4")
        val second = MediaStoreHelper.copyToUniqueFile(source, destination, "video.mp4")
        assertEquals("user original", existing.readText())
        assertEquals("video (1).mp4", first.name)
        assertEquals("video (2).mp4", second.name)
        assertEquals("new export", first.readText())
        assertEquals("new export", second.readText())
    }

    @Test fun exportingIntoSourceDirectoryNeverTruncatesSource() = withDirectory { root ->
        val source = File(root, "video.mp4").apply { writeText("source content") }
        val saved = MediaStoreHelper.copyToUniqueFile(source, root, source.name)
        assertEquals("video (1).mp4", saved.name)
        assertEquals("source content", source.readText())
        assertEquals(source.readText(), saved.readText())
    }

    @Test fun failedCopyRemovesOnlyTheNewDestination() = withDirectory { root ->
        val existing = File(root, "video.mp4").apply { writeText("user original") }
        assertThrows(IOException::class.java) {
            MediaStoreHelper.copyToUniqueFile(File(root, "missing-source"), root, "video.mp4")
        }
        assertEquals(listOf(existing.name), root.list()!!.toList())
        assertEquals("user original", existing.readText())
    }

    @Test fun concurrentReservationsDoNotOverwriteEachOther() = withDirectory { root ->
        val first = File(root, "first").apply { writeText("first export") }
        val second = File(root, "second").apply { writeText("second export") }
        val directory = File(root, "downloads")
        val start = CountDownLatch(1)
        val workers = Executors.newFixedThreadPool(2)
        try {
            val results = listOf(first, second).map { source ->
                workers.submit<File> {
                    check(start.await(5, TimeUnit.SECONDS))
                    MediaStoreHelper.copyToUniqueFile(source, directory, "same.mp4")
                }
            }
            start.countDown()
            val files = results.map { it.get(5, TimeUnit.SECONDS) }
            assertNotEquals(files[0], files[1])
            assertEquals(setOf("first export", "second export"), files.map { it.readText() }.toSet())
        } finally { workers.shutdownNow() }
    }

    @Test fun interruptionDuringReadStopsBeforePublishingTheChunk() {
        val output = ByteArrayOutputStream()
        val input = object : ByteArrayInputStream(ByteArray(100_000) { 42 }) {
            override fun read(bytes: ByteArray, offset: Int, length: Int): Int {
                val count = super.read(bytes, offset, length)
                Thread.currentThread().interrupt()
                return count
            }
        }
        try {
            assertThrows(InterruptedIOException::class.java) { MediaStoreHelper.copyInterruptibly(input, output) }
            assertEquals(0, output.size())
        } finally { Thread.interrupted() }
    }

    @Test fun cancelledExportCreatesNoPartialFile() = withDirectory { root ->
        val source = File(root, "source").apply { writeText("data") }
        Thread.currentThread().interrupt()
        try {
            assertThrows(InterruptedIOException::class.java) {
                MediaStoreHelper.copyToUniqueFile(source, root, "target.mp4")
            }
        } finally { Thread.interrupted() }
        assertEquals(listOf("source"), root.list()!!.toList())
    }

    @Test fun callerFileNameCannotEscapeDestination() = withDirectory { root ->
        val source = File(root, "source").apply { writeText("data") }
        val directory = File(root, "downloads")
        val target = MediaStoreHelper.copyToUniqueFile(source, directory, "../escape.mp4")
        assertEquals(directory.canonicalFile, target.canonicalFile.parentFile)
        assertEquals("data", target.readText())
    }
}
