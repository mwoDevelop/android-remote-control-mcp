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

class SleepDeviceAdminHandlerTest {
    @Test
    fun `administrator bearer requests fixed sleep action`() =
        runTest {
            val backend = FakeBackend()

            val result = withClient(McpAuthClientClass.STATIC_BEARER) { handler(backend).execute() }

            assertTrue((result.content.single() as TextContent).text.contains("\"status\":\"sleep_requested\""))
            assertEquals(1, backend.sleepCalls)
        }

    @Test
    fun `only exact locally authorized OAuth client may sleep device`() =
        runTest {
            val accepted = FakeBackend()
            val denied = FakeBackend()

            withClient(McpAuthClientClass.OAUTH, CLIENT_A) { handler(accepted).execute() }
            assertThrows<McpToolException.PermissionDenied> {
                withClient(McpAuthClientClass.OAUTH, CLIENT_B) { handler(denied).execute() }
            }

            assertEquals(1, accepted.sleepCalls)
            assertEquals(0, denied.sleepCalls)
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

    private fun handler(backend: PrivilegedAdminBackend) =
        SleepDeviceAdminHandler(
            backend = backend,
            authorizer = PrivilegedToolAuthorizer(),
            authorizedOAuthClientId = { CLIENT_A },
        )

    private suspend fun <T> withClient(
        clientClass: McpAuthClientClass,
        clientId: String? = null,
        block: suspend () -> T,
    ): T = withContext(McpAuthClientClassElement(clientClass, clientId)) { block() }

    private class FakeBackend(
        private val failure: PrivilegedAdminException? = null,
    ) : PrivilegedAdminBackend {
        var sleepCalls = 0

        override fun readiness(): PrivilegedAdminReadiness = PrivilegedAdminReadiness.Ready

        override fun requestPermission() = Unit

        override suspend fun getTopWindow(): TopWindowInfo = error("not used")

        override suspend fun uninstallApplication(packageName: String): ApplicationUninstallResult = error("not used")

        override suspend fun sleepDevice() {
            sleepCalls += 1
            failure?.let { throw it }
        }
    }

    private companion object {
        const val CLIENT_A = "arc-00000000-0000-0000-0000-000000000001"
        const val CLIENT_B = "arc-00000000-0000-0000-0000-000000000002"
    }
}
