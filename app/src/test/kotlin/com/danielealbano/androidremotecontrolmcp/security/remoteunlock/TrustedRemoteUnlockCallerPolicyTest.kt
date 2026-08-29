package com.danielealbano.androidremotecontrolmcp.security.remoteunlock

import org.junit.jupiter.api.Assertions.assertDoesNotThrow
import org.junit.jupiter.api.Assertions.assertThrows
import org.junit.jupiter.api.Test

class TrustedRemoteUnlockCallerPolicyTest {
    @Test
    fun `application uid may enable trusted unlock`() {
        assertDoesNotThrow {
            TrustedRemoteUnlockCallerPolicy.requireApplicationCaller(
                callingUid = 10_123,
                applicationUid = 10_123,
            )
        }
    }

    @Test
    fun `external uid cannot enable trusted unlock`() {
        assertThrows(SecurityException::class.java) {
            TrustedRemoteUnlockCallerPolicy.requireApplicationCaller(
                callingUid = 2_000,
                applicationUid = 10_123,
            )
        }
    }
}
