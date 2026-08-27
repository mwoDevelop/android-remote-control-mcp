package com.danielealbano.androidremotecontrolmcp.integration

import com.danielealbano.androidremotecontrolmcp.mcp.auth.McpAuthClientClass
import com.danielealbano.androidremotecontrolmcp.mcp.auth.currentMcpAuthClientClass
import com.danielealbano.androidremotecontrolmcp.mcp.installMcpBasePlugins
import com.danielealbano.androidremotecontrolmcp.mcp.installMcpStatelessTransport
import com.danielealbano.androidremotecontrolmcp.mcp.tools.McpToolUtils
import io.ktor.client.plugins.sse.SSE
import io.ktor.client.request.header
import io.ktor.serialization.kotlinx.json.json
import io.ktor.server.testing.ApplicationTestBuilder
import io.ktor.server.testing.testApplication
import io.modelcontextprotocol.kotlin.sdk.client.Client
import io.modelcontextprotocol.kotlin.sdk.client.StreamableHttpClientTransport
import io.modelcontextprotocol.kotlin.sdk.server.Server
import io.modelcontextprotocol.kotlin.sdk.server.ServerOptions
import io.modelcontextprotocol.kotlin.sdk.types.Implementation
import io.modelcontextprotocol.kotlin.sdk.types.McpJson
import io.modelcontextprotocol.kotlin.sdk.types.ServerCapabilities
import io.modelcontextprotocol.kotlin.sdk.types.TextContent
import io.modelcontextprotocol.kotlin.sdk.types.ToolSchema
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.test.runTest
import kotlinx.serialization.json.buildJsonObject
import org.junit.jupiter.api.AfterEach
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.BeforeEach
import org.junit.jupiter.api.DisplayName
import org.junit.jupiter.api.Test

@DisplayName("Authenticated client context integration")
class AuthClientContextIntegrationTest {
    @BeforeEach
    fun setUp() {
        McpIntegrationTestHelper.mockAndroidLog()
    }

    @AfterEach
    fun tearDown() {
        McpIntegrationTestHelper.unmockAndroidLog()
    }

    @Test
    fun `MCP tool handler sees isolated bearer and OAuth client classes`() =
        runTest {
            val server = authProbeServer()
            testApplication {
                application {
                    installMcpBasePlugins {
                        bearerTokenEnabled = true
                        expectedToken = STATIC_TOKEN
                        oauthEnabled = true
                        validateOAuthToken = { token, _ -> token == OAUTH_TOKEN }
                    }
                    installMcpStatelessTransport { server }
                }

                val bearerClient = connectMcp(STATIC_TOKEN, "bearer-client")
                val oauthClient = connectMcp(OAUTH_TOKEN, "oauth-client")
                try {
                    coroutineScope {
                        val calls =
                            (0 until CONCURRENT_CALLS).flatMap {
                                listOf(
                                    async { probe(bearerClient) },
                                    async { probe(oauthClient) },
                                )
                            }
                        val results = calls.awaitAll()
                        assertEquals(
                            CONCURRENT_CALLS,
                            results.count { it == McpAuthClientClass.STATIC_BEARER.name },
                        )
                        assertEquals(
                            CONCURRENT_CALLS,
                            results.count { it == McpAuthClientClass.OAUTH.name },
                        )
                    }
                } finally {
                    bearerClient.close()
                    oauthClient.close()
                }
            }
        }

    private fun authProbeServer(): Server =
        Server(
            serverInfo = Implementation(name = "auth-context-test", version = "1"),
            options =
                ServerOptions(
                    capabilities = ServerCapabilities(tools = ServerCapabilities.Tools(listChanged = false)),
                ),
        ).apply {
            addTool(
                name = PROBE_TOOL,
                description = "Return the non-secret authentication class for this request",
                inputSchema = ToolSchema(properties = buildJsonObject {}, required = emptyList()),
            ) {
                McpToolUtils.textResult(currentMcpAuthClientClass().name)
            }
        }

    private suspend fun ApplicationTestBuilder.connectMcp(
        token: String,
        clientName: String,
    ): Client {
        val httpClient =
            createClient {
                install(io.ktor.client.plugins.contentnegotiation.ContentNegotiation) { json(McpJson) }
                install(SSE)
            }
        val transport =
            StreamableHttpClientTransport(
                client = httpClient,
                url = "/mcp",
                requestBuilder = { header("Authorization", "Bearer $token") },
            )
        return Client(clientInfo = Implementation(name = clientName, version = "1")).also {
            it.connect(transport)
        }
    }

    private suspend fun probe(client: Client): String {
        val result = client.callTool(name = PROBE_TOOL, arguments = emptyMap())
        return (result.content.single() as TextContent).text
    }

    private companion object {
        const val STATIC_TOKEN = "static-admin-token"
        const val OAUTH_TOKEN = "oauth-access-token"
        const val PROBE_TOOL = "auth_context_probe"
        const val CONCURRENT_CALLS = 10
    }
}
