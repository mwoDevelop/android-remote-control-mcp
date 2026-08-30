package com.danielealbano.androidremotecontrolmcp.security.remoteunlock

import android.app.KeyguardManager
import android.content.Context
import com.mwodevelop.androidremotecontrol.shizukuadmin.ApplicationUninstallResult
import com.mwodevelop.androidremotecontrol.shizukuadmin.PrivilegedAdminBackend
import com.mwodevelop.androidremotecontrol.shizukuadmin.PrivilegedAdminReadiness
import com.mwodevelop.androidremotecontrol.shizukuadmin.TopWindowInfo
import io.mockk.every
import io.mockk.mockk
import kotlinx.coroutines.test.runTest
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test

class RemoteUnlockControllerTest {
    @Test
    fun `unavailable backend does not consume authorization`() =
        runTest {
            val store = FakeStore()
            val backend = FakeBackend(readiness = PrivilegedAdminReadiness.ShizukuServiceStopped)
            val controller = controller(store, backend, lockedStates = listOf(true))

            assertEquals(RemoteUnlockOutcome.UNAVAILABLE, controller.unlock())
            assertEquals(0, store.beginAttemptCalls)
        }

    @Test
    fun `already unlocked device does not consume authorization`() =
        runTest {
            val store = FakeStore()
            val controller = controller(store, FakeBackend(), lockedStates = listOf(false))

            assertEquals(RemoteUnlockOutcome.ALREADY_UNLOCKED, controller.unlock())
            assertEquals(0, store.beginAttemptCalls)
        }

    @Test
    fun `policy rejection returns bounded temporary block before decryption`() =
        runTest {
            val store = FakeStore(beginAttemptResult = false)
            val backend = FakeBackend()
            val controller = controller(store, backend, lockedStates = listOf(true))

            assertEquals(RemoteUnlockOutcome.TEMPORARILY_BLOCKED, controller.unlock())
            assertEquals(1, store.beginAttemptCalls)
            assertEquals(0, store.decryptCalls)
            assertEquals(0, backend.injectCalls)
        }

    @Test
    fun `successful injection records success and unlocks`() =
        runTest {
            val store = FakeStore()
            val backend = FakeBackend(injectionResult = true)
            val controller = controller(store, backend, lockedStates = listOf(true, false))

            assertEquals(RemoteUnlockOutcome.UNLOCKED, controller.unlock())
            assertEquals(listOf(true), store.recordedResults)
            assertEquals(1, backend.injectCalls)
            assertTrue(backend.receivedDigits.all { it in 0..9 })
        }

    @Test
    fun `failed injection records failure without a second authorization`() =
        runTest {
            val store = FakeStore()
            val backend = FakeBackend(injectionResult = false)
            val controller = controller(store, backend, lockedStates = listOf(true, true))

            assertEquals(RemoteUnlockOutcome.UNLOCK_FAILED_REARM_REQUIRED, controller.unlock())
            assertEquals(1, store.beginAttemptCalls)
            assertEquals(listOf(false), store.recordedResults)
        }

    private fun controller(
        store: FakeStore,
        backend: FakeBackend,
        lockedStates: List<Boolean>,
    ): RemoteUnlockController {
        val keyguard = mockk<KeyguardManager>()
        val states = lockedStates.iterator()
        every { keyguard.isDeviceLocked } answers { states.next() }
        val context = mockk<Context>()
        every { context.getSystemService(KeyguardManager::class.java) } returns keyguard
        return RemoteUnlockController(context, store, backend)
    }

    private class FakeStore(
        private val beginAttemptResult: Boolean = true,
    ) : RemoteUnlockCredentialStore {
        var beginAttemptCalls = 0
        var decryptCalls = 0
        val recordedResults = mutableListOf<Boolean>()

        override fun provisioningKey(): RemoteUnlockProvisioningKey = error("not used")

        override fun status() =
            RemoteUnlockStatus(
                configured = true,
                enabled = true,
                authorizedClientId = null,
                remainingArmMs = 0,
                rearmRequired = false,
                mode = RemoteUnlockMode.TRUSTED,
            )

        override fun provision(
            keyVersion: Int,
            ciphertextBase64: String,
        ) = error("not used")

        override fun setPolicy(
            enabled: Boolean,
            authorizedClientId: String?,
        ) = error("not used")

        override fun arm() = error("not used")

        override fun enableTrusted() = error("not used")

        override fun disableTrusted() = error("not used")

        override fun beginAttempt(): Boolean {
            beginAttemptCalls += 1
            return beginAttemptResult
        }

        override fun disarm() = error("not used")

        override fun recordAttemptResult(success: Boolean) {
            recordedResults += success
        }

        override fun clear() = error("not used")

        override suspend fun <T> withDecryptedDigits(block: suspend (ByteArray) -> T): T {
            decryptCalls += 1
            return block(byteArrayOf(1, 2, 3, 4))
        }
    }

    private class FakeBackend(
        private val readiness: PrivilegedAdminReadiness = PrivilegedAdminReadiness.Ready,
        private val injectionResult: Boolean = true,
    ) : PrivilegedAdminBackend {
        var injectCalls = 0
        var receivedDigits = byteArrayOf()

        override fun readiness(): PrivilegedAdminReadiness = readiness

        override fun requestPermission() = error("not used")

        override suspend fun getTopWindow(): TopWindowInfo = error("not used")

        override suspend fun uninstallApplication(packageName: String): ApplicationUninstallResult = error("not used")

        override suspend fun sleepDevice() = error("not used")

        override suspend fun injectUnlockDigitsForLocalFeasibilityTest(digits: ByteArray): Boolean {
            injectCalls += 1
            receivedDigits = digits.copyOf()
            return injectionResult
        }
    }
}
