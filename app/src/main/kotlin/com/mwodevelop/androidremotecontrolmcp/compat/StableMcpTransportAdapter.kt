package com.mwodevelop.androidremotecontrolmcp.compat

import io.ktor.server.application.Application
import io.ktor.server.application.ApplicationCallPipeline
import io.ktor.server.application.call
import io.ktor.server.request.path
import io.ktor.util.pipeline.PipelinePhase
import kotlinx.coroutines.withContext

/**
 * Ktor 3.4 / MCP SDK 0.8 binding for the owner request context.
 *
 * The phase is installed after the upstream Plugins phase. Authentication writes its verified
 * classification in Plugins; this adapter then carries it through the legacy session transport.
 */
internal fun Application.installStableMcpRequestContext(publicUrlOverride: String) {
    val ownerContextPhase = PipelinePhase("OwnerMcpRequestContext")
    insertPhaseAfter(ApplicationCallPipeline.Plugins, ownerContextPhase)
    intercept(ownerContextPhase) {
        if (call.request.path() == "/mcp") {
            withContext(ownerMcpRequestContext(call, publicUrlOverride)) { proceed() }
        } else {
            proceed()
        }
    }
}
