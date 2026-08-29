package com.danielealbano.androidremotecontrolmcp.security.remoteunlock

import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Assertions.assertNull
import org.junit.jupiter.api.Assertions.assertThrows
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test

class RemoteUnlockAttemptPolicyTest {
    @Test
    fun `one-shot authorization is consumed atomically`() {
        val snapshot = RemoteUnlockClockSnapshot(7, 10_000)
        val armed =
            RemoteUnlockAttemptPolicyState(
                armWindow = RemoteUnlockArmWindowPolicy.arm(snapshot, 900_000),
            )

        val consumed = requireNotNull(RemoteUnlockAttemptPolicy.authorize(armed, snapshot))

        assertFalse(RemoteUnlockAttemptPolicy.status(consumed, snapshot).authorized)
        assertNull(RemoteUnlockAttemptPolicy.authorize(consumed, snapshot))
    }

    @Test
    fun `trusted authorization survives success and enforces attempt spacing`() {
        val initial = trustedState(bootCount = 7)
        val first =
            requireNotNull(
                RemoteUnlockAttemptPolicy.authorize(initial, RemoteUnlockClockSnapshot(7, 10_000)),
            )
        val successful = RemoteUnlockAttemptPolicy.recordSuccess(first)

        assertNull(
            RemoteUnlockAttemptPolicy.authorize(successful, RemoteUnlockClockSnapshot(7, 39_999)),
        )
        assertTrue(
            RemoteUnlockAttemptPolicy.status(successful, RemoteUnlockClockSnapshot(7, 39_999)).cooldownRemainingMs > 0,
        )
        assertTrue(
            RemoteUnlockAttemptPolicy.authorize(successful, RemoteUnlockClockSnapshot(7, 40_000)) != null,
        )
    }

    @Test
    fun `three trusted failures block until ten-minute window expires`() {
        var state = trustedState(bootCount = 7)
        val attemptTimes = listOf(10_000L, 40_000L, 70_000L)
        attemptTimes.forEach { now ->
            state =
                requireNotNull(
                    RemoteUnlockAttemptPolicy.authorize(state, RemoteUnlockClockSnapshot(7, now)),
                )
            state = RemoteUnlockAttemptPolicy.recordFailure(state, RemoteUnlockClockSnapshot(7, now + 1))
        }

        val blocked = RemoteUnlockAttemptPolicy.status(state, RemoteUnlockClockSnapshot(7, 100_000))
        assertFalse(blocked.authorized)
        assertEquals(510_001, blocked.cooldownRemainingMs)
        assertNull(RemoteUnlockAttemptPolicy.authorize(state, RemoteUnlockClockSnapshot(7, 100_000)))
        assertTrue(
            RemoteUnlockAttemptPolicy.authorize(state, RemoteUnlockClockSnapshot(7, 610_001)) != null,
        )
    }

    @Test
    fun `trusted success clears failure count but preserves spacing`() {
        val attempted =
            requireNotNull(
                RemoteUnlockAttemptPolicy.authorize(trustedState(3), RemoteUnlockClockSnapshot(3, 50_000)),
            )
        val failed = RemoteUnlockAttemptPolicy.recordFailure(attempted, RemoteUnlockClockSnapshot(3, 50_001))
        val successful = RemoteUnlockAttemptPolicy.recordSuccess(failed)

        assertEquals(0, successful.trustedWindow.failureCount)
        assertEquals(0, successful.trustedWindow.failureWindowStartElapsedRealtimeMs)
        assertNull(RemoteUnlockAttemptPolicy.authorize(successful, RemoteUnlockClockSnapshot(3, 79_999)))
    }

    @Test
    fun `trusted mode survives reboot but resets boot-bound limiter`() {
        val oldBoot =
            trustedState(bootCount = 3).copy(
                trustedWindow =
                    RemoteUnlockTrustedAttemptWindow(
                        bootCount = 3,
                        lastAttemptElapsedRealtimeMs = 90_000,
                        failureWindowStartElapsedRealtimeMs = 30_000,
                        failureCount = 3,
                    ),
            )

        val authorized =
            requireNotNull(
                RemoteUnlockAttemptPolicy.authorize(oldBoot, RemoteUnlockClockSnapshot(4, 1_000)),
            )

        assertEquals(RemoteUnlockMode.TRUSTED, authorized.mode)
        assertEquals(4, authorized.trustedWindow.bootCount)
        assertEquals(0, authorized.trustedWindow.failureCount)
    }

    @Test
    fun `missing clock fails closed and stored mode parser rejects unknown values`() {
        val state = trustedState(7)

        assertFalse(RemoteUnlockAttemptPolicy.status(state, null).authorized)
        assertNull(RemoteUnlockAttemptPolicy.authorize(state, null))
        assertThrows(IllegalArgumentException::class.java) {
            RemoteUnlockMode.fromStoredValue("always_on")
        }
    }

    @Test
    fun `version two state migrates to one-shot while malformed version three fails closed`() {
        assertEquals(RemoteUnlockMode.ONE_SHOT, RemoteUnlockMode.fromStoredState(2, null))
        assertEquals(RemoteUnlockMode.ONE_SHOT, RemoteUnlockMode.fromStoredState(2, "trusted"))
        assertEquals(RemoteUnlockMode.TRUSTED, RemoteUnlockMode.fromStoredState(3, "trusted"))
        assertThrows(IllegalArgumentException::class.java) {
            RemoteUnlockMode.fromStoredState(3, "always_on")
        }
        assertThrows(IllegalArgumentException::class.java) {
            RemoteUnlockMode.fromStoredState(3, null)
        }
    }

    private fun trustedState(bootCount: Int) =
        RemoteUnlockAttemptPolicyState(
            mode = RemoteUnlockMode.TRUSTED,
            trustedWindow = RemoteUnlockTrustedAttemptWindow(bootCount = bootCount),
        )
}
