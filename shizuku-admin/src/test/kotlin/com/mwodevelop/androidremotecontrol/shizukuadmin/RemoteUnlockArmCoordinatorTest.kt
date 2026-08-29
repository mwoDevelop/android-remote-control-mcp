package com.mwodevelop.androidremotecontrol.shizukuadmin

import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test

class RemoteUnlockArmCoordinatorTest {
    @Test
    fun `one foreground success arms exactly once and refreshes`() {
        val fixture = Fixture()
        fixture.coordinator.onResume()

        fixture.coordinator.requestArm()
        fixture.authenticator.complete(LocalAuthenticationResult.SUCCESS)
        fixture.authenticator.repeatLast(LocalAuthenticationResult.SUCCESS)

        assertEquals(1, fixture.gateway.armCalls)
        assertEquals(listOf(RemoteUnlockAdminMessage.ARMED), fixture.listener.messages)
        assertEquals(1, fixture.listener.refreshes)
        assertFalse(fixture.listener.busy)
    }

    @Test
    fun `repeated click while authenticating is ignored`() {
        val fixture = Fixture()
        fixture.coordinator.onResume()

        fixture.coordinator.requestArm()
        fixture.coordinator.requestArm()

        assertEquals(1, fixture.authenticator.authenticateCalls)
        assertTrue(fixture.listener.busy)
    }

    @Test
    fun `background invalidates callback and cancels authentication`() {
        val fixture = Fixture()
        fixture.coordinator.onResume()
        fixture.coordinator.requestArm()

        fixture.coordinator.onStop()
        fixture.authenticator.complete(LocalAuthenticationResult.SUCCESS)

        assertEquals(1, fixture.authenticator.cancelCalls)
        assertEquals(0, fixture.gateway.armCalls)
        assertFalse(fixture.listener.busy)
    }

    @Test
    fun `cancellation and authentication error fail without arming`() {
        val cancelled = Fixture().also { it.coordinator.onResume() }
        cancelled.coordinator.requestArm()
        cancelled.authenticator.complete(LocalAuthenticationResult.CANCELLED)
        val error = Fixture().also { it.coordinator.onResume() }
        error.coordinator.requestArm()
        error.authenticator.complete(LocalAuthenticationResult.ERROR)

        assertEquals(listOf(RemoteUnlockAdminMessage.AUTHENTICATION_CANCELLED), cancelled.listener.messages)
        assertEquals(listOf(RemoteUnlockAdminMessage.AUTHENTICATION_ERROR), error.listener.messages)
        assertEquals(0, cancelled.gateway.armCalls + error.gateway.armCalls)
    }

    @Test
    fun `provider failure is reported and refreshes fail closed`() {
        val fixture = Fixture().also { it.gateway.failArm = true }
        fixture.coordinator.onResume()
        fixture.coordinator.requestArm()

        fixture.authenticator.complete(LocalAuthenticationResult.SUCCESS)

        assertEquals(1, fixture.gateway.armCalls)
        assertEquals(listOf(RemoteUnlockAdminMessage.ARM_FAILED), fixture.listener.messages)
        assertEquals(1, fixture.listener.refreshes)
    }

    @Test
    fun `trusted enable requires one foreground authentication and ignores duplicate callback`() {
        val fixture = Fixture()
        fixture.coordinator.onResume()

        fixture.coordinator.requestEnableTrusted()
        fixture.authenticator.complete(LocalAuthenticationResult.SUCCESS)
        fixture.authenticator.repeatLast(LocalAuthenticationResult.SUCCESS)

        assertEquals(1, fixture.gateway.enableTrustedCalls)
        assertEquals(listOf(RemoteUnlockAdminMessage.TRUSTED_ENABLED), fixture.listener.messages)
        assertEquals(1, fixture.listener.refreshes)
        assertFalse(fixture.listener.busy)
    }

    @Test
    fun `trusted provider failure is reported without arming one-shot`() {
        val fixture = Fixture().also { it.gateway.failTrusted = true }
        fixture.coordinator.onResume()

        fixture.coordinator.requestEnableTrusted()
        fixture.authenticator.complete(LocalAuthenticationResult.SUCCESS)

        assertEquals(1, fixture.gateway.enableTrustedCalls)
        assertEquals(0, fixture.gateway.armCalls)
        assertEquals(listOf(RemoteUnlockAdminMessage.TRUSTED_ENABLE_FAILED), fixture.listener.messages)
    }

    @Test
    fun `arm request while stopped is ignored`() {
        val fixture = Fixture()

        fixture.coordinator.requestArm()

        assertEquals(0, fixture.authenticator.authenticateCalls)
        assertEquals(0, fixture.gateway.armCalls)
    }

    private class Fixture {
        val authenticator = FakeAuthenticator()
        val gateway = FakeGateway()
        val listener = FakeListener()
        val coordinator = RemoteUnlockArmCoordinator(authenticator, gateway, listener)
    }

    private class FakeAuthenticator : LocalAdministratorAuthenticator {
        var authenticateCalls = 0
        var cancelCalls = 0
        private var callback: ((LocalAuthenticationResult) -> Unit)? = null
        private var lastCallback: ((LocalAuthenticationResult) -> Unit)? = null

        override fun authenticate(callback: (LocalAuthenticationResult) -> Unit) {
            ++authenticateCalls
            this.callback = callback
            lastCallback = callback
        }

        override fun cancel() {
            ++cancelCalls
        }

        fun complete(result: LocalAuthenticationResult) {
            callback?.invoke(result)
            callback = null
        }

        fun repeatLast(result: LocalAuthenticationResult) {
            lastCallback?.invoke(result)
        }
    }

    private class FakeGateway : RemoteUnlockAdminGateway {
        var armCalls = 0
        var failArm = false
        var enableTrustedCalls = 0
        var failTrusted = false

        override fun status() = RemoteUnlockAdminStatus(true, true, false, false, 0)

        override fun arm(): RemoteUnlockAdminStatus {
            ++armCalls
            if (failArm) error("provider failed")
            return RemoteUnlockAdminStatus(true, true, true, false, 900_000)
        }

        override fun disarm() = RemoteUnlockAdminStatus(true, true, false, false, 0)

        override fun enableTrusted(): RemoteUnlockAdminStatus {
            ++enableTrustedCalls
            if (failTrusted) error("provider failed")
            return RemoteUnlockAdminStatus(
                configured = true,
                enabled = true,
                armed = false,
                rearmRequired = false,
                remainingMs = 0,
                mode = RemoteUnlockAdminMode.TRUSTED,
                trustedActive = true,
            )
        }

        override fun disableTrusted() = RemoteUnlockAdminStatus(true, true, false, false, 0)
    }

    private class FakeListener : RemoteUnlockArmCoordinatorListener {
        var busy = false
        var refreshes = 0
        val messages = mutableListOf<RemoteUnlockAdminMessage>()

        override fun onBusyChanged(busy: Boolean) {
            this.busy = busy
        }

        override fun onMessage(message: RemoteUnlockAdminMessage) {
            messages.add(message)
        }

        override fun onRefreshRequested() {
            ++refreshes
        }
    }
}
