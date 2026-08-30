package com.danielealbano.androidremotecontrolmcp.mcp.shizuku

import com.danielealbano.androidremotecontrolmcp.mcp.McpToolException
import com.danielealbano.androidremotecontrolmcp.mcp.auth.McpAuthClientClass
import com.danielealbano.androidremotecontrolmcp.mcp.auth.McpAuthClientClassElement
import com.mwodevelop.androidremotecontrol.shizukuadmin.ApplicationUninstallResult
import com.mwodevelop.androidremotecontrol.shizukuadmin.PrivilegedAdminBackend
import com.mwodevelop.androidremotecontrol.shizukuadmin.PrivilegedAdminReadiness
import com.mwodevelop.androidremotecontrol.shizukuadmin.TopWindowInfo
import io.modelcontextprotocol.kotlin.sdk.types.TextContent
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test
import org.junit.jupiter.api.assertThrows

class UninstallApplicationAdminHandlerTest {
    @Test
    fun `administrator bearer can uninstall an unprotected validated package`() =
        runTest {
            val backend = FakeBackend()
            val result =
                withClient(McpAuthClientClass.STATIC_BEARER) {
                    handler(backend).execute(arguments("com.example.removable"))
                }
            val text = (result.content.single() as TextContent).text

            assertTrue(text.contains("\"package_id\":\"com.example.removable\""))
            assertTrue(text.contains("\"system_partition_modified\":false"))
            assertEquals(listOf("com.example.removable"), backend.packages)
        }

    @Test
    fun `oauth is denied before policy and backend`() =
        runTest {
            val backend = FakeBackend()
            var policyCalls = 0
            val target =
                UninstallApplicationAdminHandler(
                    backend,
                    PrivilegedToolAuthorizer(),
                    ProtectedPackagePolicy {
                        policyCalls += 1
                        null
                    },
                )

            assertThrows<McpToolException.PermissionDenied> {
                withClient(McpAuthClientClass.OAUTH) { target.execute(arguments("com.example.removable")) }
            }
            assertEquals(0, policyCalls)
            assertTrue(backend.packages.isEmpty())
        }

    @Test
    fun `protected package is denied before backend`() =
        runTest {
            val backend = FakeBackend()
            val target = handler(backend, "Qustodio is protected")

            val error =
                assertThrows<McpToolException.PermissionDenied> {
                    withClient(McpAuthClientClass.STATIC_BEARER) {
                        target.execute(arguments("com.qustodio.qustodioapp"))
                    }
                }

            assertTrue(error.message.orEmpty().contains("Qustodio is protected"))
            assertTrue(backend.packages.isEmpty())
        }

    @Test
    fun `malformed package is rejected before policy and backend`() =
        runTest {
            val backend = FakeBackend()
            var policyCalls = 0
            val target =
                UninstallApplicationAdminHandler(
                    backend,
                    PrivilegedToolAuthorizer(),
                    ProtectedPackagePolicy {
                        policyCalls += 1
                        null
                    },
                )

            assertThrows<McpToolException.InvalidParams> {
                withClient(McpAuthClientClass.STATIC_BEARER) {
                    target.execute(arguments("com.example;reboot"))
                }
            }
            assertEquals(0, policyCalls)
            assertTrue(backend.packages.isEmpty())
        }

    private fun handler(
        backend: PrivilegedAdminBackend,
        reason: String? = null,
    ) = UninstallApplicationAdminHandler(
        backend,
        PrivilegedToolAuthorizer(),
        ProtectedPackagePolicy { reason },
    )

    private fun arguments(packageName: String) = buildJsonObject { put("package_id", packageName) }

    private suspend fun <T> withClient(
        clientClass: McpAuthClientClass,
        block: suspend () -> T,
    ): T = withContext(McpAuthClientClassElement(clientClass)) { block() }

    private class FakeBackend : PrivilegedAdminBackend {
        val packages = mutableListOf<String>()

        override fun readiness(): PrivilegedAdminReadiness = PrivilegedAdminReadiness.Ready

        override fun requestPermission() = Unit

        override suspend fun getTopWindow(): TopWindowInfo = error("not used")

        override suspend fun uninstallApplication(packageName: String): ApplicationUninstallResult {
            packages += packageName
            return ApplicationUninstallResult(packageName, 0)
        }

        override suspend fun sleepDevice() = error("not used")
    }
}
