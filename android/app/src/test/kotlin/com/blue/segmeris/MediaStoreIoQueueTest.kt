package com.blue.segmeris

import io.flutter.plugin.common.MethodChannel
import java.io.IOException
import java.util.concurrent.CountDownLatch
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import org.junit.Assert.*
import org.junit.Test

class MediaStoreIoQueueTest {
    private class Reply : MethodChannel.Result {
        var calls = 0
        var value: Any? = null
        var error: String? = null
        var thread: Thread? = null
        override fun success(result: Any?) { calls++; value = result; thread = Thread.currentThread() }
        override fun error(code: String, message: String?, details: Any?) {
            calls++; error = code; thread = Thread.currentThread()
        }
        override fun notImplemented() { fail("Unexpected notImplemented") }
    }

    @Test fun oneWorkerRunsOffCallerAndRepliesThroughMainDispatcher() {
        val callbacks = LinkedBlockingQueue<Runnable>()
        val queue = MediaStoreIoQueue(postToMain = { callbacks.add(it) })
        val caller = Thread.currentThread()
        val started = CountDownLatch(1)
        val release = CountDownLatch(1)
        val secondStarted = AtomicBoolean(false)
        val first = Reply()
        val second = Reply()
        try {
            queue.submit(first, "SAVE_FAILED") {
                assertNotSame(caller, Thread.currentThread())
                started.countDown()
                check(release.await(5, TimeUnit.SECONDS))
                "content://media/external_primary/downloads/123"
            }
            assertTrue(started.await(5, TimeUnit.SECONDS))
            queue.submit(second, "DELETE_FAILED") { secondStarted.set(true); true }
            assertFalse(secondStarted.get())
            assertEquals(0, first.calls)
            release.countDown()
            repeat(2) { callbacks.poll(5, TimeUnit.SECONDS)!!.run() }
            assertEquals("content://media/external_primary/downloads/123", first.value)
            assertEquals(true, second.value)
            assertSame(caller, first.thread)
            assertSame(caller, second.thread)
            assertEquals(1, first.calls)
            assertEquals(1, second.calls)
        } finally { release.countDown(); queue.close() }
    }

    @Test fun saturatedQueueRejectsWithoutRunningOnCaller() {
        val callbacks = LinkedBlockingQueue<Runnable>()
        val queue = MediaStoreIoQueue(queueCapacity = 1, postToMain = { callbacks.add(it) })
        val started = CountDownLatch(1)
        val release = CountDownLatch(1)
        val rejected = Reply()
        val ranRejected = AtomicBoolean(false)
        try {
            queue.submit(Reply(), "SAVE_FAILED") { started.countDown(); release.await(); true }
            assertTrue(started.await(5, TimeUnit.SECONDS))
            queue.submit(Reply(), "SAVE_FAILED") { true }
            queue.submit(rejected, "SAVE_FAILED") { ranRejected.set(true); true }
            callbacks.poll(5, TimeUnit.SECONDS)!!.run()
            assertEquals("IO_BUSY", rejected.error)
            assertFalse(ranRejected.get())
            assertEquals(1, rejected.calls)
        } finally { release.countDown(); queue.close() }
    }

    @Test fun closingInterruptsActiveWorkCancelsQueuedWorkAndRepliesExactlyOnce() {
        val callbacks = LinkedBlockingQueue<Runnable>()
        val queue = MediaStoreIoQueue(postToMain = { callbacks.add(it) })
        val started = CountDownLatch(1)
        val cleaned = AtomicBoolean(false)
        val queuedRan = AtomicBoolean(false)
        val active = Reply()
        val queued = Reply()
        val afterClose = Reply()
        try {
            queue.submit(active, "SAVE_FAILED") {
                try {
                    started.countDown()
                    CountDownLatch(1).await()
                } finally { cleaned.set(true) }
            }
            assertTrue(started.await(5, TimeUnit.SECONDS))
            queue.submit(queued, "DELETE_FAILED") { queuedRan.set(true); true }
            queue.close()
            queue.close()
            queue.submit(afterClose, "SAVE_FAILED") { fail("Closed queue executed work") }
            repeat(3) { callbacks.poll(5, TimeUnit.SECONDS)!!.run() }
            assertTrue(cleaned.get())
            assertFalse(queuedRan.get())
            listOf(active, queued, afterClose).forEach {
                assertEquals("IO_CANCELLED", it.error)
                assertEquals(1, it.calls)
            }
            assertTrue(callbacks.isEmpty())
        } finally { queue.close() }
    }

    @Test fun failuresProduceExplicitChannelErrorsAndWorkerContinues() {
        val callbacks = LinkedBlockingQueue<Runnable>()
        val queue = MediaStoreIoQueue(postToMain = { callbacks.add(it) })
        val failure = Reply()
        val permission = Reply()
        val invalid = Reply()
        val success = Reply()
        try {
            queue.submit(failure, "DELETE_FAILED") { throw IOException("Cannot delete file") }
            queue.submit(permission, "DELETE_FAILED") { throw SecurityException("Access denied") }
            queue.submit(invalid, "DELETE_FAILED") { throw IllegalArgumentException("Collection URI") }
            queue.submit(success, "DELETE_FAILED") { true }
            repeat(4) { callbacks.poll(5, TimeUnit.SECONDS)!!.run() }
            assertEquals("DELETE_FAILED", failure.error)
            assertEquals("PERMISSION_DENIED", permission.error)
            assertEquals("INVALID_ARGS", invalid.error)
            assertEquals(true, success.value)
        } finally { queue.close() }
    }

    @Test fun alreadyCommittedResultSurvivesLifecycleCloseBeforeMainDelivery() {
        val callbacks = LinkedBlockingQueue<Runnable>()
        val queue = MediaStoreIoQueue(postToMain = { callbacks.add(it) })
        val reply = Reply()
        queue.submit(reply, "SAVE_FAILED") { "/download/completed.mp4" }
        val completed = callbacks.poll(5, TimeUnit.SECONDS)!!
        queue.close()
        completed.run()
        assertEquals("/download/completed.mp4", reply.value)
        assertEquals(1, reply.calls)
        assertTrue(callbacks.isEmpty())
    }
}
