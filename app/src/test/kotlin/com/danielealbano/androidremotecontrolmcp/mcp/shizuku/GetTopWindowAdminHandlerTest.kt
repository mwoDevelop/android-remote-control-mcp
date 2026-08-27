package com.danielealbano.androidremotecontrolmcp.mcp.shizuku

import com.danielealbano.androidremotecontrolmcp.mcp.McpToolException
import com.danielealbano.androidremotecontrolmcp.mcp.auth.McpAuthClientClass
import com.danielealbano.androidremotecontrolmcp.mcp.auth.McpAuthClientClassElement
import com.mwodevelop.androidremotecontrol.shizukuadmin.ApplicationUninstallResult
import com.mwodevelop.androidremotecontrol.shizukuadmin.PrivilegedAdminBackend
import com.mwodevelop.androidremotecontrol.shizukuadmin.PrivilegedAdminException
import com.mwodevelop.androidremotecontrol.shizukuadmin.PrivilegedAdminReadiness
import com.mwodevelop.androidremotecontrol.shizukuadmin.TopWindowInfo
import io.modelcontextprotocol.kotlin.sdk.types.TextContent
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.withContext
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test
import org.junit.jupiter.api.assertThrows

class GetTopWindowAdminHandlerTest {
    @Test
    fun `administrator bearer receives typed top window result`() =
        runTest {
            val backend = FakeBackend()
            val result = withClient(McpAuthClientClass.STATIC_BEARER) { handler(backend).execute() }
            val text = (result.content.single() as TextContent).text

            assertTrue(text.contains("\"package_name\":\"com.example.app\""))
            assertTrue(text.contains("\"display_id\":0"))
            assertEquals(1, backend.callCount)
        }

    @Test
    fun `oauth is denied before the backend is invoked`() =
        runTest {
            val backend = FakeBackend()

            assertThrows<McpToolException.PermissionDenied> {
                withClient(McpAuthClientClass.OAUTH) { handler(backend).execute() }
            }
            assertEquals(0, backend.callCount)
        }

    @Test
    fun `unavailable Shizuku returns stable recovery hint`() =
        runTest {
            val backend = FakeBackend(failure = PrivilegedAdminException.Unavailable())

            val error =
                assertThrows<McpToolException.ActionFailed> {
                    withClient(McpAuthClientClass.STATIC_BEARER) { handler(backend).execute() }
                }
            assertEquals(
                "Shizuku is unavailable. Start Shizuku and grant this application permission, then retry.",
                error.message,
            )
        }

    private fun handler(backend: PrivilegedAdminBackend) = GetTopWindowAdminHandler(backend, PrivilegedToolAuthorizer())

    private suspend fun <T> withClient(
        clientClass: McpAuthClientClass,
        block: suspend () -> T,
    ): T = withContext(McpAuthClientClassElement(clientClass)) { block() }

    private class FakeBackend(
        private val failure: PrivilegedAdminException? = null,
    ) : PrivilegedAdminBackend {
        var callCount = 0

        override fun readiness(): PrivilegedAdminReadiness = PrivilegedAdminReadiness.Ready

        override fun requestPermission() = Unit

        override suspend fun getTopWindow(): TopWindowInfo {
            callCount += 1
            failure?.let { throw it }
            return TopWindowInfo("com.example.app", "com.example.app.MainActivity", null, 0)
        }

        override suspend fun uninstallApplication(packageName: String): ApplicationUninstallResult = error("not used")
    }
}
