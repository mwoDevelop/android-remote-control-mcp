package com.danielealbano.androidremotecontrolmcp.mcp.shizuku

import com.danielealbano.androidremotecontrolmcp.mcp.McpToolException
import com.danielealbano.androidremotecontrolmcp.mcp.auth.McpAuthClientClass
import com.danielealbano.androidremotecontrolmcp.mcp.auth.McpAuthClientClassElement
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withContext
import org.junit.jupiter.api.Assertions.assertDoesNotThrow
import org.junit.jupiter.api.Assertions.assertThrows
import org.junit.jupiter.api.Test

class PrivilegedToolAuthorizerTest {
    private val authorizer = PrivilegedToolAuthorizer()

    @Test
    fun `remote unlock accepts administrator bearer`() {
        assertDoesNotThrow {
            runBlocking {
                withContext(McpAuthClientClassElement(McpAuthClientClass.STATIC_BEARER)) {
                    authorizer.requireRemoteUnlock(null)
                }
            }
        }
    }

    @Test
    fun `remote unlock accepts only exact configured OAuth client`() {
        assertDoesNotThrow {
            runBlocking {
                withContext(McpAuthClientClassElement(McpAuthClientClass.OAUTH, CLIENT_A)) {
                    authorizer.requireRemoteUnlock(CLIENT_A)
                }
            }
        }
        assertThrows(McpToolException.PermissionDenied::class.java) {
            runBlocking {
                withContext(McpAuthClientClassElement(McpAuthClientClass.OAUTH, CLIENT_B)) {
                    authorizer.requireRemoteUnlock(CLIENT_A)
                }
            }
        }
    }

    private companion object {
        const val CLIENT_A = "arc-00000000-0000-0000-0000-000000000001"
        const val CLIENT_B = "arc-00000000-0000-0000-0000-000000000002"
    }
}
