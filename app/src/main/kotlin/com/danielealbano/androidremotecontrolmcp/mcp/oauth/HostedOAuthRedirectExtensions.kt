package com.danielealbano.androidremotecontrolmcp.mcp.oauth

/**
 * Exact hosted OAuth callbacks added by integrations outside the core policy.
 *
 * This is deliberately immutable and compile-time only. Hosted redirects are a security boundary: callers must add
 * one reviewed exact URI here rather than introduce host wildcards, runtime settings, or environment-driven values.
 */
internal object HostedOAuthRedirectExtensions {
    const val ANTIGRAVITY_REDIRECT_URI = "https://antigravity.google/oauth-callback"

    private val exactRedirectUris = setOf(ANTIGRAVITY_REDIRECT_URI)

    fun isAllowed(uri: String): Boolean = uri in exactRedirectUris
}
