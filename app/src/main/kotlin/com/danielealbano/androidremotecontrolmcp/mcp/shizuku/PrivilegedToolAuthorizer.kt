package com.danielealbano.androidremotecontrolmcp.mcp.shizuku

import com.danielealbano.androidremotecontrolmcp.mcp.McpToolException
import com.danielealbano.androidremotecontrolmcp.mcp.auth.McpAuthClientClass
import com.danielealbano.androidremotecontrolmcp.mcp.auth.currentMcpAuthClientClass
import com.danielealbano.androidremotecontrolmcp.mcp.auth.currentMcpOAuthClientId
import javax.inject.Inject
import javax.inject.Singleton

/** Authorizes privileged calls from the already authenticated, request-scoped client class. */
@Singleton
class PrivilegedToolAuthorizer
    @Inject
    constructor() {
        suspend fun requireAdministratorBearer() {
            if (currentMcpAuthClientClass() != McpAuthClientClass.STATIC_BEARER) {
                throw McpToolException.PermissionDenied(
                    "Privileged tool access requires the configured administrator bearer credential",
                )
            }
        }

        suspend fun requireRemoteUnlock(authorizedOAuthClientId: String?) {
            val clientClass = currentMcpAuthClientClass()
            val allowed =
                clientClass == McpAuthClientClass.STATIC_BEARER ||
                    (
                        clientClass == McpAuthClientClass.OAUTH &&
                            authorizedOAuthClientId != null &&
                            currentMcpOAuthClientId() == authorizedOAuthClientId
                    )
            if (!allowed) {
                throw McpToolException.PermissionDenied(
                    "Remote unlock is not authorized for this exact authenticated client",
                )
            }
        }
    }
