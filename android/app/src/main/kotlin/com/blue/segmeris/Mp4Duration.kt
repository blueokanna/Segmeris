package com.blue.segmeris

import java.io.RandomAccessFile

/** Reads the movie duration used by galleries; fragmented or concatenated output is rejected. */
internal object Mp4Duration {
    fun readMs(path: String): Long? = runCatching {
        RandomAccessFile(path, "r").use { file ->
            var movieCount = 0
            var duration: Long? = null
            var boxes = 0
            fun scan(start: Long, end: Long, inMovie: Boolean) {
                var position = start
                while (position < end) {
                    require(++boxes <= 8192 && end - position >= 8)
                    file.seek(position)
                    var size = file.readInt().toLong() and 0xffffffffL
                    val type = file.readInt()
                    var header = 8L
                    if (size == 1L) { size = file.readLong(); header = 16L }
                    if (size == 0L) size = end - position
                    require(size >= header && size <= end - position)
                    when (type) {
                        0x6d6f6f66 -> error("Fragmented MP4 is not a finalized gallery output") // moof
                        0x6d6f6f76 -> { // moov
                            require(!inMovie && ++movieCount == 1)
                            scan(position + header, position + size, true)
                        }
                        0x6d766864 -> if (inMovie) { // mvhd
                            require(duration == null && size - header >= 20)
                            val version = file.readUnsignedByte()
                            require(version == 0 || version == 1)
                            require(size - header >= if (version == 1) 32 else 20)
                            file.skipBytes(3 + if (version == 1) 16 else 8)
                            val scale = file.readInt().toLong() and 0xffffffffL
                            require(scale > 0)
                            val ticks = if (version == 1) file.readLong() else file.readInt().toLong() and 0xffffffffL
                            require(ticks > 0 && ticks <= Long.MAX_VALUE / 1000L)
                            require(version != 0 || ticks != 0xffffffffL)
                            duration = ticks * 1000L / scale
                        }
                    }
                    position += size
                }
            }
            scan(0, file.length(), false)
            duration?.takeIf { movieCount == 1 && it > 0 }
        }
    }.getOrNull()
}
