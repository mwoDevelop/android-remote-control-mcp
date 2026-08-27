package com.mwodevelop.androidremotecontrol.shizukuadmin

import kotlinx.coroutines.test.runTest
import org.junit.jupiter.api.Assertions.assertArrayEquals
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Test
import java.io.ByteArrayInputStream

class BoundedOutputTest {
    @Test
    fun `retains output within limit`() =
        runTest {
            val result = ByteArrayInputStream("hello".toByteArray()).readBounded(10)

            assertArrayEquals("hello".toByteArray(), result.bytes)
            assertEquals(false, result.truncated)
        }

    @Test
    fun `caps retained bytes while draining excess`() =
        runTest {
            val input = ByteArray(32 * 1024) { (it % 251).toByte() }
            val stream = ByteArrayInputStream(input)
            val result = stream.readBounded(1024)

            assertArrayEquals(input.copyOf(1024), result.bytes)
            assertEquals(true, result.truncated)
            assertEquals(-1, stream.read())
        }
}
