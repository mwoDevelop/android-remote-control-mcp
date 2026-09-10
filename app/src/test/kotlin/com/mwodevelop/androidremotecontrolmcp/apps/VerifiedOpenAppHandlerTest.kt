package com.mwodevelop.androidremotecontrolmcp.apps

import com.danielealbano.androidremotecontrolmcp.mcp.McpToolException
import com.danielealbano.androidremotecontrolmcp.services.apps.AppManager
import io.mockk.coEvery
import io.mockk.coVerify
import io.mockk.mockk
import io.modelcontextprotocol.kotlin.sdk.types.TextContent
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.withTimeout
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Assertions.assertThrows
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test

class VerifiedOpenAppHandlerTest {
    private val manager = mockk<AppManager>()
    private val args = buildJsonObject { put("package_id", "com.example.target") }

    private fun handler(
        available: Boolean = true,
        read: () -> String?,
    ): VerifiedOpenAppHandler {
        val observer =
            object : ForegroundAppObserver {
                override fun isAvailable(): Boolean = available

                override fun currentPackage(): String? = read()
            }
        return VerifiedOpenAppHandler(manager, AppActivationVerifier(observer))
    }

    @Test
    fun `visible target is confirmed and launch is requested only once`() =
        runTest {
            coEvery { manager.openApp(any()) } returns Result.success(Unit)
            val result = handler { "com.example.target" }.execute(args)
            assertTrue((result.content.first() as TextContent).text.contains("foreground_confirmed:"))
            coVerify(exactly = 1) { manager.openApp("com.example.target") }
        }

    @Test
    fun `delayed activation is confirmed`() =
        runTest {
            coEvery { manager.openApp(any()) } returns Result.success(Unit)
            var reads = 0
            val result = handler { if (++reads < 4) "com.example.launcher" else "com.example.target" }.execute(args)
            assertTrue((result.content.first() as TextContent).text.startsWith("foreground_confirmed:"))
            coVerify(exactly = 1) { manager.openApp(any()) }
        }

    @Test
    fun `timeout is unconfirmed not a claim of failure or success`() =
        runTest {
            coEvery { manager.openApp(any()) } returns Result.success(Unit)
            val result = handler { "com.example.overlay" }.execute(args)
            val text = (result.content.first() as TextContent).text
            assertTrue(text.startsWith("launch_requested_unconfirmed:"))
            assertTrue(text.contains("do not automatically repeat"))
            assertFalse(result.isError == true)
            coVerify(exactly = 1) { manager.openApp(any()) }
        }

    @Test
    fun `missing accessibility never reports confirmed`() =
        runTest {
            coEvery { manager.openApp(any()) } returns Result.success(Unit)
            val result = handler(available = false) { error("Must not read disconnected accessibility") }.execute(args)
            assertTrue((result.content.first() as TextContent).text.startsWith("launch_requested_unconfirmed:"))
        }

    @Test
    fun `null root never reports confirmed`() =
        runTest {
            coEvery { manager.openApp(any()) } returns Result.success(Unit)
            val text = (handler { null }.execute(args).content.first() as TextContent).text
            assertTrue(text.startsWith("launch_requested_unconfirmed:"))
        }

    @Test
    fun `unknown package preserves launch error`() {
        coEvery { manager.openApp(any()) } returns Result.failure(IllegalArgumentException("No launchable activity"))
        assertThrows(McpToolException.ActionFailed::class.java) {
            runTest { handler { error("Must not observe rejected launch") }.execute(args) }
        }
    }

    @Test
    fun `blank package fails before launch`() {
        assertThrows(McpToolException.InvalidParams::class.java) {
            runTest { handler { null }.execute(buildJsonObject { put("package_id", " ") }) }
        }
        coVerify(exactly = 0) { manager.openApp(any()) }
    }

    @Test
    fun `parent cancellation propagates without retry`() {
        coEvery { manager.openApp(any()) } returns Result.success(Unit)
        assertThrows(CancellationException::class.java) {
            runTest { withTimeout(300) { handler { null }.execute(args) } }
        }
        coVerify(exactly = 1) { manager.openApp(any()) }
    }
}
