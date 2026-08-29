package com.danielealbano.androidremotecontrolmcp.security.remoteunlock

import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertThrows
import org.junit.jupiter.api.Test

class RemoteUnlockArmWindowPolicyTest {
    @Test
    fun `arm uses monotonic deadline and current boot count`() {
        val window = RemoteUnlockArmWindowPolicy.arm(RemoteUnlockClockSnapshot(42, 10_000), 900_000)

        assertEquals(42, window.bootCount)
        assertEquals(910_000, window.deadlineElapsedRealtimeMs)
        assertEquals(
            450_000,
            RemoteUnlockArmWindowPolicy.remainingMs(window, RemoteUnlockClockSnapshot(42, 460_000)),
        )
    }

    @Test
    fun `reboot mismatch expires the arm`() {
        val window = RemoteUnlockArmWindow(42, 910_000)

        assertEquals(0, RemoteUnlockArmWindowPolicy.remainingMs(window, RemoteUnlockClockSnapshot(43, 20_000)))
    }

    @Test
    fun `elapsed and missing clock states fail closed`() {
        val window = RemoteUnlockArmWindow(42, 910_000)

        assertEquals(0, RemoteUnlockArmWindowPolicy.remainingMs(window, RemoteUnlockClockSnapshot(42, 910_000)))
        assertEquals(0, RemoteUnlockArmWindowPolicy.remainingMs(window, null))
        assertEquals(0, RemoteUnlockArmWindowPolicy.remainingMs(window, RemoteUnlockClockSnapshot(-1, 10_000)))
    }

    @Test
    fun `invalid clock and overflow cannot create an arm`() {
        assertThrows(IllegalArgumentException::class.java) {
            RemoteUnlockArmWindowPolicy.arm(RemoteUnlockClockSnapshot(-1, 0), 900_000)
        }
        assertThrows(ArithmeticException::class.java) {
            RemoteUnlockArmWindowPolicy.arm(RemoteUnlockClockSnapshot(1, Long.MAX_VALUE), 1)
        }
    }
}
