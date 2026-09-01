package com.mwodevelop.androidremotecontrolmcp.compat

import com.danielealbano.androidremotecontrolmcp.mcp.RequestBaseUrlElement
import com.danielealbano.androidremotecontrolmcp.mcp.auth.McpAuthClientClass
import com.danielealbano.androidremotecontrolmcp.mcp.auth.McpAuthClientClassAttribute
import com.danielealbano.androidremotecontrolmcp.mcp.auth.McpAuthClientClassElement
import com.danielealbano.androidremotecontrolmcp.mcp.auth.McpOAuthClientIdAttribute
import com.danielealbano.androidremotecontrolmcp.mcp.effectiveBaseUrl
import io.ktor.server.application.ApplicationCall
import kotlin.coroutines.CoroutineContext

/** Common owner request context; transport generations provide only their dispatch-specific binding. */
internal fun ownerMcpRequestContext(
    call: ApplicationCall,
    publicUrlOverride: String,
): CoroutineContext {
    val clientClass =
        call.attributes.getOrNull(McpAuthClientClassAttribute) ?: McpAuthClientClass.UNKNOWN
    val oauthClientId = call.attributes.getOrNull(McpOAuthClientIdAttribute)
    return RequestBaseUrlElement(effectiveBaseUrl(call, publicUrlOverride)) +
        McpAuthClientClassElement(clientClass, oauthClientId)
}
