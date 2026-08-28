package com.danielealbano.androidremotecontrolmcp.mcp

import com.danielealbano.androidremotecontrolmcp.mcp.auth.McpAuthClientClass
import com.danielealbano.androidremotecontrolmcp.mcp.auth.McpAuthClientClassAttribute
import com.danielealbano.androidremotecontrolmcp.mcp.auth.McpAuthClientClassElement
import com.danielealbano.androidremotecontrolmcp.mcp.auth.McpAuthPhase
import com.danielealbano.androidremotecontrolmcp.mcp.auth.McpOAuthClientIdAttribute
import io.ktor.server.application.Application
import io.ktor.server.application.call
import io.ktor.server.request.path
import io.ktor.util.pipeline.PipelinePhase
import io.modelcontextprotocol.kotlin.sdk.server.Server
import io.modelcontextprotocol.kotlin.sdk.server.mcpStatelessStreamableHttp
import kotlinx.coroutines.withContext

private val McpRequestContextPhase = PipelinePhase("McpRequestContext")

/**
 * Installs the MCP stateless Streamable HTTP transport at `/mcp`, together with a per-request
 * [RequestBaseUrlElement] scoped to the `/mcp` route so MCP tool handlers can build absolute
 * links (e.g. ephemeral file links).
 *
 * The request context is installed at the application level and filtered to `/mcp`. The SDK mounts
 * its own route node, so a sibling route-level interceptor would not reliably wrap the production
 * Netty handler. [McpRequestContextPhase] is explicitly inserted after [McpAuthPhase] and before
 * `Call`, so privileged handlers never observe a pre-authentication classification. Each stateless
 * POST is a fresh, never-initialized session, so the SDK dispatches tool-call handlers inline in
 * the request coroutine — which is why wrapping [proceed] in `withContext` reaches the handler.
 *
 * DNS-rebinding protection is disabled: requests arrive via a cloudflared/ngrok tunnel, so the
 * `Host` header is the tunnel hostname (not localhost) and the SDK's localhost-default validation
 * would reject all legitimate traffic. Bearer/OAuth authentication is the compensating control.
 *
 * Shared by [McpServer] and the integration tests so production and test wiring cannot drift.
 *
 * @param publicUrlOverride Pins the base URL host; empty means derive it from the request.
 * @param block Provider for the MCP [Server] instance to serve each request.
 */
fun Application.installMcpStatelessTransport(
    publicUrlOverride: String = "",
    block: () -> Server,
) {
    insertPhaseAfter(McpAuthPhase, McpRequestContextPhase)
    intercept(McpRequestContextPhase) {
        if (call.request.path() == "/mcp") {
            val authClientClass =
                call.attributes.getOrNull(McpAuthClientClassAttribute) ?: McpAuthClientClass.UNKNOWN
            val oauthClientId = call.attributes.getOrNull(McpOAuthClientIdAttribute)
            withContext(
                RequestBaseUrlElement(effectiveBaseUrl(call, publicUrlOverride)) +
                    McpAuthClientClassElement(authClientClass, oauthClientId),
            ) {
                proceed()
            }
        } else {
            proceed()
        }
    }
    mcpStatelessStreamableHttp(
        path = "/mcp",
        enableDnsRebindingProtection = false,
    ) {
        block()
    }
}
