package com.danielealbano.androidremotecontrolmcp.mcp.shizuku

import com.danielealbano.androidremotecontrolmcp.mcp.McpToolException
import com.danielealbano.androidremotecontrolmcp.mcp.auth.McpAuthClientClass
import com.danielealbano.androidremotecontrolmcp.mcp.auth.currentMcpAuthClientClass
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
    }
