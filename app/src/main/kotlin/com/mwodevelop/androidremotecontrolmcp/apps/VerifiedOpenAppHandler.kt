package com.mwodevelop.androidremotecontrolmcp.apps

import com.danielealbano.androidremotecontrolmcp.mcp.McpToolException
import com.danielealbano.androidremotecontrolmcp.mcp.tools.LoggedToolRegistrar
import com.danielealbano.androidremotecontrolmcp.mcp.tools.McpToolUtils
import com.danielealbano.androidremotecontrolmcp.services.apps.AppManager
import io.modelcontextprotocol.kotlin.sdk.types.CallToolResult
import io.modelcontextprotocol.kotlin.sdk.types.ToolSchema
import kotlinx.coroutines.CancellationException
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import kotlinx.serialization.json.putJsonObject

/** Fork-owned composition of the upstream launch operation and an unprivileged postcondition. */
class VerifiedOpenAppHandler(
    private val appManager: AppManager,
    private val verifier: AppActivationVerifier = AppActivationVerifier(),
) {
    suspend fun execute(arguments: JsonObject?): CallToolResult {
        val packageId = McpToolUtils.requireString(arguments, "package_id")
        if (packageId.isBlank()) {
            throw McpToolException.InvalidParams("Parameter 'package_id' must not be blank")
        }
        requireLaunchAccepted(packageId)
        return if (verifier.isForegroundConfirmed(packageId)) {
            McpToolUtils.textResult("foreground_confirmed: Application '$packageId' is visible in the foreground.")
        } else {
            McpToolUtils.textResult(
                "launch_requested_unconfirmed: Launch intent sent for '$packageId', but foreground activation " +
                    "was not confirmed within 3 seconds (or accessibility observation is unavailable). " +
                    "This does not prove that launch failed. Read the current screen before taking another action; " +
                    "do not automatically repeat open_app. Loading, a lock screen, an overlay or an Android/OEM " +
                    "background-start restriction may require attention. No restriction was bypassed.",
            )
        }
    }

    private suspend fun requireLaunchAccepted(packageId: String) {
        appManager.openApp(packageId).onFailure { error ->
            if (error is CancellationException) throw error
            throw McpToolException.ActionFailed("Failed to open application '$packageId': ${error.message}")
        }
    }

    fun register(
        registrar: LoggedToolRegistrar,
        toolNamePrefix: String,
    ) {
        registrar.addTool(
            toolName = "open_app",
            name = "${toolNamePrefix}open_app",
            description =
                "Requests launch of an installed application by package ID, then observes accessibility for up to " +
                    "3 seconds. Returns foreground_confirmed or launch_requested_unconfirmed. An unconfirmed " +
                    "result is not a launch failure: read the screen before retrying. " +
                    "Does not unlock or bypass restrictions.",
            inputSchema =
                ToolSchema(
                    properties =
                        buildJsonObject {
                            putJsonObject("package_id") {
                                put("type", "string")
                                put("description", "The application package name (e.g., 'com.example.app')")
                            }
                        },
                    required = listOf("package_id"),
                ),
        ) { request -> execute(request.arguments) }
    }
}
