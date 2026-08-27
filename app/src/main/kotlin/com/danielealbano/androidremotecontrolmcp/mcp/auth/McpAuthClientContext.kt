package com.danielealbano.androidremotecontrolmcp.mcp.auth

import io.ktor.util.AttributeKey
import kotlin.coroutines.AbstractCoroutineContextElement
import kotlin.coroutines.CoroutineContext
import kotlin.coroutines.coroutineContext

/** Non-secret classification of the authentication path used by the current MCP request. */
enum class McpAuthClientClass {
    STATIC_BEARER,
    OAUTH,
    OPEN,
    EXCLUDED,
    UNKNOWN,
}

/** Ktor-call attribute written by [McpAuthPlugin] after authentication succeeds. */
internal val McpAuthClientClassAttribute = AttributeKey<McpAuthClientClass>("McpAuthClientClass")

/** Coroutine-context element carrying the authenticated client class into MCP tool handlers. */
class McpAuthClientClassElement(
    val clientClass: McpAuthClientClass,
) : AbstractCoroutineContextElement(Key) {
    companion object Key : CoroutineContext.Key<McpAuthClientClassElement>
}

/** Returns the current request's authentication class, or [McpAuthClientClass.UNKNOWN] outside a request. */
suspend fun currentMcpAuthClientClass(): McpAuthClientClass =
    coroutineContext[McpAuthClientClassElement]?.clientClass ?: McpAuthClientClass.UNKNOWN
