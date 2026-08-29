package com.mwodevelop.androidremotecontrol.shizukuadmin

import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test

class RemoteUnlockAdminStateMapperTest {
    @Test
    fun `armed state rounds remaining duration up and allows only disarm`() {
        val view =
            RemoteUnlockAdminStateMapper.map(
                RemoteUnlockAdminStatus(true, true, true, false, 1_001),
                shizukuReady = true,
            )

        assertEquals(RemoteUnlockAdminState.ARMED, view.state)
        assertEquals(2, view.remainingSeconds)
        assertFalse(view.canArm)
        assertTrue(view.canDisarm)
        assertTrue(view.shizukuReady)
    }

    @Test
    fun `configured enabled unarmed state permits arming`() {
        val view =
            RemoteUnlockAdminStateMapper.map(
                RemoteUnlockAdminStatus(true, true, false, false, 0),
                shizukuReady = false,
            )

        assertEquals(RemoteUnlockAdminState.READY, view.state)
        assertTrue(view.canArm)
        assertFalse(view.canDisarm)
    }

    @Test
    fun `trusted state permits only trusted disable`() {
        val view =
            RemoteUnlockAdminStateMapper.map(
                RemoteUnlockAdminStatus(
                    configured = true,
                    enabled = true,
                    armed = false,
                    rearmRequired = false,
                    remainingMs = 0,
                    mode = RemoteUnlockAdminMode.TRUSTED,
                    trustedActive = true,
                ),
                shizukuReady = true,
            )

        assertEquals(RemoteUnlockAdminState.TRUSTED, view.state)
        assertFalse(view.canArm)
        assertFalse(view.canEnableTrusted)
        assertTrue(view.canDisableTrusted)
    }

    @Test
    fun `trusted cooldown is rounded up and does not disable trusted policy`() {
        val view =
            RemoteUnlockAdminStateMapper.map(
                RemoteUnlockAdminStatus(
                    configured = true,
                    enabled = true,
                    armed = false,
                    rearmRequired = false,
                    remainingMs = 0,
                    mode = RemoteUnlockAdminMode.TRUSTED,
                    trustedActive = true,
                    cooldownRemainingMs = 1_001,
                ),
                shizukuReady = true,
            )

        assertEquals(RemoteUnlockAdminState.TRUSTED_RATE_LIMITED, view.state)
        assertEquals(2, view.cooldownSeconds)
        assertTrue(view.canDisableTrusted)
    }

    @Test
    fun `configuration failures take precedence over arm controls`() {
        val notConfigured =
            RemoteUnlockAdminStateMapper.map(RemoteUnlockAdminStatus(false, false, false, false, 0), false)
        val disabled = RemoteUnlockAdminStateMapper.map(RemoteUnlockAdminStatus(true, false, false, false, 0), false)
        val rearm = RemoteUnlockAdminStateMapper.map(RemoteUnlockAdminStatus(true, true, false, true, 0), true)

        assertEquals(RemoteUnlockAdminState.NOT_CONFIGURED, notConfigured.state)
        assertEquals(RemoteUnlockAdminState.DISABLED, disabled.state)
        assertEquals(RemoteUnlockAdminState.REARM_REQUIRED, rearm.state)
        assertFalse(notConfigured.canArm)
        assertFalse(disabled.canArm)
        assertTrue(rearm.canArm)
    }
}
