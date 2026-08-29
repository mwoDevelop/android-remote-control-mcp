@file:Suppress("MatchingDeclarationName")

package com.danielealbano.androidremotecontrolmcp.mcp.shizuku

import com.danielealbano.androidremotecontrolmcp.mcp.McpToolException
import com.danielealbano.androidremotecontrolmcp.mcp.tools.LoggedToolRegistrar
import com.danielealbano.androidremotecontrolmcp.mcp.tools.McpToolUtils
import com.danielealbano.androidremotecontrolmcp.security.remoteunlock.RemoteUnlockController
import com.danielealbano.androidremotecontrolmcp.security.remoteunlock.RemoteUnlockCredentialStore
import com.danielealbano.androidremotecontrolmcp.security.remoteunlock.RemoteUnlockOperation
import com.mwodevelop.androidremotecontrol.shizukuadmin.ApplicationUninstallResult
import com.mwodevelop.androidremotecontrol.shizukuadmin.PrivilegedAdminBackend
import com.mwodevelop.androidremotecontrol.shizukuadmin.PrivilegedAdminException
import com.mwodevelop.androidremotecontrol.shizukuadmin.TopWindowInfo
import io.modelcontextprotocol.kotlin.sdk.types.CallToolResult
import io.modelcontextprotocol.kotlin.sdk.types.ToolSchema
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import kotlinx.serialization.json.putJsonObject
import javax.inject.Inject

/** Read-only first vertical slice of the application-owned Shizuku administration surface. */
class GetTopWindowAdminHandler
    @Inject
    constructor(
        private val backend: PrivilegedAdminBackend,
        private val authorizer: PrivilegedToolAuthorizer,
    ) {
        suspend fun execute(): CallToolResult {
            authorizer.requireAdministratorBearer()
            val result = executeBackend()
            return McpToolUtils.textResult(result.toJson().toString())
        }

        fun register(
            registrar: LoggedToolRegistrar,
            toolNamePrefix: String,
        ) {
            registrar.addPrivilegedTool(
                toolName = TOOL_NAME,
                name = "$toolNamePrefix$TOOL_NAME",
                description =
                    "Returns the current foreground package and activity through Shizuku. " +
                        "Requires the primary administrator bearer credential; OAuth clients are denied.",
                inputSchema = ToolSchema(properties = buildJsonObject {}, required = emptyList()),
            ) { _ -> execute() }
        }

        private suspend fun executeBackend(): TopWindowInfo =
            try {
                backend.getTopWindow()
            } catch (e: PrivilegedAdminException.PermissionDenied) {
                throw McpToolException.PermissionDenied(SHIZUKU_RECOVERY_HINT, e)
            } catch (e: PrivilegedAdminException.Unavailable) {
                throw McpToolException.ActionFailed(SHIZUKU_RECOVERY_HINT, e)
            } catch (e: PrivilegedAdminException.CommandFailed) {
                throw McpToolException.ActionFailed("Shizuku top-window query failed", e)
            } catch (e: PrivilegedAdminException.OutputTruncated) {
                throw McpToolException.ActionFailed("Shizuku top-window response exceeded its safety limit", e)
            } catch (e: PrivilegedAdminException.ExecutionFailed) {
                throw McpToolException.ActionFailed("Shizuku top-window query could not be completed", e)
            }

        companion object {
            const val TOOL_NAME = "admin_get_top_window"
        }
    }

/** Requests the ordinary user-visible Shizuku permission dialog. */
class RequestShizukuPermissionAdminHandler
    @Inject
    constructor(
        private val backend: PrivilegedAdminBackend,
        private val authorizer: PrivilegedToolAuthorizer,
    ) {
        suspend fun execute(): CallToolResult {
            authorizer.requireAdministratorBearer()
            try {
                backend.requestPermission()
            } catch (e: PrivilegedAdminException.Unavailable) {
                throw McpToolException.ActionFailed(SHIZUKU_RECOVERY_HINT, e)
            } catch (e: PrivilegedAdminException.ExecutionFailed) {
                throw McpToolException.ActionFailed("The Shizuku permission prompt could not be requested", e)
            }
            return McpToolUtils.textResult(
                "Shizuku permission is already granted or its standard permission dialog was requested.",
            )
        }

        fun register(
            registrar: LoggedToolRegistrar,
            toolNamePrefix: String,
        ) {
            registrar.addPrivilegedTool(
                toolName = TOOL_NAME,
                name = "$toolNamePrefix$TOOL_NAME",
                description =
                    "Requests the standard visible Shizuku permission dialog for this application. " +
                        "It does not grant permission automatically and requires the primary administrator bearer.",
                inputSchema = ToolSchema(properties = buildJsonObject {}, required = emptyList()),
            ) { _ -> execute() }
        }

        companion object {
            const val TOOL_NAME = "admin_request_shizuku_permission"
        }
    }

/** Destructive, explicitly typed package removal; no arbitrary command reaches Shizuku. */
class UninstallApplicationAdminHandler
    @Inject
    constructor(
        private val backend: PrivilegedAdminBackend,
        private val authorizer: PrivilegedToolAuthorizer,
        private val protectedPackagePolicy: ProtectedPackagePolicy,
    ) {
        suspend fun execute(arguments: JsonObject?): CallToolResult {
            authorizer.requireAdministratorBearer()
            val packageName = McpToolUtils.requireString(arguments, "package_id")
            if (!PACKAGE_NAME.matches(packageName)) {
                throw McpToolException.InvalidParams("Parameter 'package_id' must be a valid Android package name")
            }
            protectedPackagePolicy.protectionReason(packageName)?.let { reason ->
                throw McpToolException.PermissionDenied("Refusing to uninstall '$packageName': $reason")
            }
            return McpToolUtils.textResult(executeBackend(packageName).toJson().toString())
        }

        fun register(
            registrar: LoggedToolRegistrar,
            toolNamePrefix: String,
        ) {
            registrar.addPrivilegedTool(
                toolName = TOOL_NAME,
                name = "$toolNamePrefix$TOOL_NAME",
                description =
                    "Uninstalls one validated application for Android user 0 through Shizuku. " +
                        "For a preinstalled system application this removes it only for that user, not from the " +
                        "system partition. Critical packages, Shizuku, Qustodio, the MCP app, active device " +
                        "administrators and the launcher are denied. Requires the primary administrator bearer; " +
                        "OAuth clients are denied.",
                inputSchema =
                    ToolSchema(
                        properties =
                            buildJsonObject {
                                putJsonObject("package_id") {
                                    put("type", "string")
                                    put("description", "Exact Android package name to remove for user 0")
                                }
                            },
                        required = listOf("package_id"),
                    ),
            ) { request -> execute(request.arguments) }
        }

        private suspend fun executeBackend(packageName: String): ApplicationUninstallResult =
            try {
                backend.uninstallApplication(packageName)
            } catch (e: PrivilegedAdminException.PermissionDenied) {
                throw McpToolException.PermissionDenied(SHIZUKU_RECOVERY_HINT, e)
            } catch (e: PrivilegedAdminException.Unavailable) {
                throw McpToolException.ActionFailed(SHIZUKU_RECOVERY_HINT, e)
            } catch (e: PrivilegedAdminException.CommandFailed) {
                throw McpToolException.ActionFailed("Android rejected uninstalling '$packageName'", e)
            } catch (e: PrivilegedAdminException.OperationRejected) {
                throw McpToolException.ActionFailed("Android rejected uninstalling '$packageName'", e)
            } catch (e: PrivilegedAdminException.OutputTruncated) {
                throw McpToolException.ActionFailed("The uninstall response exceeded its safety limit", e)
            } catch (e: PrivilegedAdminException.ExecutionFailed) {
                throw McpToolException.ActionFailed("Uninstalling '$packageName' could not be completed", e)
            }

        companion object {
            const val TOOL_NAME = "admin_uninstall_app"
            private val PACKAGE_NAME = Regex("^[A-Za-z][A-Za-z0-9_]*(?:\\.[A-Za-z][A-Za-z0-9_]*)+$")
        }
    }

/** Zero-argument policy-controlled remote unlock. Credential material never crosses the MCP boundary. */
class UnlockDeviceAdminHandler(
    private val controller: RemoteUnlockOperation,
    private val credentialStore: RemoteUnlockCredentialStore,
    private val authorizer: PrivilegedToolAuthorizer,
) {
    suspend fun execute(): CallToolResult {
        authorizer.requireRemoteUnlock(credentialStore.status().authorizedClientId)
        return McpToolUtils.textResult(
            buildJsonObject { put("status", controller.unlock().wireValue) }.toString(),
        )
    }

    fun register(
        registrar: LoggedToolRegistrar,
        toolNamePrefix: String,
    ) {
        registrar.addPrivilegedTool(
            toolName = TOOL_NAME,
            name = "$toolNamePrefix$TOOL_NAME",
            description =
                "Unlocks this device using a locally provisioned credential. Takes no PIN or other input; " +
                    "the credential never leaves the device. Requires a locally authorized one-shot or trusted policy.",
            inputSchema = ToolSchema(properties = buildJsonObject {}, required = emptyList()),
        ) { _ -> execute() }
    }

    companion object {
        const val TOOL_NAME = "admin_unlock_device"
    }
}

private fun TopWindowInfo.toJson() =
    buildJsonObject {
        packageName?.let { put("package_name", it) }
        activity?.let { put("activity", it) }
        windowClass?.let { put("window_class", it) }
        displayId?.let { put("display_id", it) }
    }

private fun ApplicationUninstallResult.toJson() =
    buildJsonObject {
        put("package_id", packageName)
        put("android_user_id", androidUserId)
        put("removed_for_user", true)
        put("system_partition_modified", false)
    }

private const val SHIZUKU_RECOVERY_HINT =
    "Shizuku is unavailable. Start Shizuku and grant this application permission, then retry."

/** Closed production surface. Adding a privileged tool requires an explicit security review and regression update. */
internal val SHIZUKU_ADMIN_TOOL_NAMES =
    setOf(
        GetTopWindowAdminHandler.TOOL_NAME,
        RequestShizukuPermissionAdminHandler.TOOL_NAME,
        UninstallApplicationAdminHandler.TOOL_NAME,
        UnlockDeviceAdminHandler.TOOL_NAME,
    )

/** One conflict-minimizing seam used by the existing MCP server. */
fun registerShizukuAdminTools(
    registrar: LoggedToolRegistrar,
    backend: PrivilegedAdminBackend,
    authorizer: PrivilegedToolAuthorizer,
    protectedPackagePolicy: ProtectedPackagePolicy,
    remoteUnlockController: RemoteUnlockOperation,
    remoteUnlockCredentialStore: RemoteUnlockCredentialStore,
    toolNamePrefix: String,
    enabledTools: Set<String>,
) {
    if (GetTopWindowAdminHandler.TOOL_NAME in enabledTools) {
        GetTopWindowAdminHandler(backend, authorizer).register(registrar, toolNamePrefix)
    }
    if (RequestShizukuPermissionAdminHandler.TOOL_NAME in enabledTools) {
        RequestShizukuPermissionAdminHandler(backend, authorizer).register(registrar, toolNamePrefix)
    }
    if (UninstallApplicationAdminHandler.TOOL_NAME in enabledTools) {
        UninstallApplicationAdminHandler(backend, authorizer, protectedPackagePolicy).register(
            registrar,
            toolNamePrefix,
        )
    }
    if (UnlockDeviceAdminHandler.TOOL_NAME in enabledTools) {
        UnlockDeviceAdminHandler(remoteUnlockController, remoteUnlockCredentialStore, authorizer).register(
            registrar,
            toolNamePrefix,
        )
    }
}
