package com.danielealbano.androidremotecontrolmcp.mcp.shizuku

import com.danielealbano.androidremotecontrolmcp.mcp.tools.LoggedToolRegistrar
import com.danielealbano.androidremotecontrolmcp.security.remoteunlock.RemoteUnlockCredentialStore
import com.danielealbano.androidremotecontrolmcp.security.remoteunlock.RemoteUnlockOutcome
import com.danielealbano.androidremotecontrolmcp.security.remoteunlock.RemoteUnlockProvisioningKey
import com.danielealbano.androidremotecontrolmcp.security.remoteunlock.RemoteUnlockStatus
import com.danielealbano.androidremotecontrolmcp.testutil.RecordingServerLogRepository
import com.mwodevelop.androidremotecontrol.shizukuadmin.ApplicationUninstallResult
import com.mwodevelop.androidremotecontrol.shizukuadmin.PrivilegedAdminBackend
import com.mwodevelop.androidremotecontrol.shizukuadmin.PrivilegedAdminReadiness
import com.mwodevelop.androidremotecontrol.shizukuadmin.TopWindowInfo
import io.modelcontextprotocol.kotlin.sdk.server.Server
import io.modelcontextprotocol.kotlin.sdk.server.ServerOptions
import io.modelcontextprotocol.kotlin.sdk.types.Implementation
import io.modelcontextprotocol.kotlin.sdk.types.ServerCapabilities
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Test

class ShizukuAdminToolsRegistrationTest {
    @Test
    fun `production privileged surface contains exactly the three reviewed tools`() {
        val server = server()

        register(server, SHIZUKU_ADMIN_TOOL_NAMES)

        assertEquals(SHIZUKU_ADMIN_TOOL_NAMES, server.tools.keys)
        assertFalse(server.tools.keys.any { it.contains("shell") || it.contains("settings") || it.contains("clear") })
    }

    @Test
    fun `per-tool policy removes each reviewed privileged tool`() {
        SHIZUKU_ADMIN_TOOL_NAMES.forEach { disabled ->
            val server = server()

            register(server, SHIZUKU_ADMIN_TOOL_NAMES - disabled)

            assertEquals(SHIZUKU_ADMIN_TOOL_NAMES - disabled, server.tools.keys)
        }
    }

    private fun register(
        server: Server,
        enabledTools: Set<String>,
    ) {
        registerShizukuAdminTools(
            LoggedToolRegistrar(server, RecordingServerLogRepository()),
            FakeBackend,
            PrivilegedToolAuthorizer(),
            ProtectedPackagePolicy { null },
            { RemoteUnlockOutcome.UNAVAILABLE },
            FakeCredentialStore,
            toolNamePrefix = "",
            enabledTools = enabledTools,
        )
    }

    private fun server() =
        Server(
            serverInfo = Implementation(name = "test", version = "test"),
            options =
                ServerOptions(
                    capabilities = ServerCapabilities(tools = ServerCapabilities.Tools(listChanged = false)),
                ),
        )

    private object FakeBackend : PrivilegedAdminBackend {
        override fun readiness(): PrivilegedAdminReadiness = PrivilegedAdminReadiness.Ready

        override fun requestPermission() = Unit

        override suspend fun getTopWindow(): TopWindowInfo = TopWindowInfo(null, null, null, null)

        override suspend fun uninstallApplication(packageName: String): ApplicationUninstallResult =
            ApplicationUninstallResult(packageName, 0)
    }

    private object FakeCredentialStore : RemoteUnlockCredentialStore {
        override fun provisioningKey() = RemoteUnlockProvisioningKey(1, "test")

        override fun status() = RemoteUnlockStatus(false, false, null, 0, false)

        override fun provision(
            keyVersion: Int,
            ciphertextBase64: String,
        ) = Unit

        override fun setPolicy(
            enabled: Boolean,
            authorizedClientId: String?,
        ) = Unit

        override fun arm() = Unit

        override fun consumeArm() = false

        override fun disarm() = Unit

        override fun recordFailure() = Unit

        override fun clear() = Unit

        override suspend fun <T> withDecryptedDigits(block: suspend (ByteArray) -> T): T = block(byteArrayOf())
    }
}
