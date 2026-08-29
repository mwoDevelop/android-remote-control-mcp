package com.danielealbano.androidremotecontrolmcp.security.remoteunlock

import android.app.KeyguardManager
import android.content.Context
import com.mwodevelop.androidremotecontrol.shizukuadmin.PrivilegedAdminBackend
import com.mwodevelop.androidremotecontrol.shizukuadmin.PrivilegedAdminReadiness
import dagger.hilt.android.qualifiers.ApplicationContext
import kotlinx.coroutines.delay
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import javax.inject.Inject
import javax.inject.Singleton

enum class RemoteUnlockOutcome(
    val wireValue: String,
) {
    UNLOCKED("unlocked"),
    ALREADY_UNLOCKED("already_unlocked"),
    DISABLED("disabled"),
    NOT_CONFIGURED("not_configured"),
    TEMPORARILY_BLOCKED("temporarily_blocked"),
    UNAVAILABLE("unavailable"),
    UNLOCK_FAILED_REARM_REQUIRED("unlock_failed_rearm_required"),
}

fun interface RemoteUnlockOperation {
    suspend fun unlock(): RemoteUnlockOutcome
}

@Singleton
class RemoteUnlockController
    @Inject
    constructor(
        @ApplicationContext context: Context,
        private val store: RemoteUnlockCredentialStore,
        private val backend: PrivilegedAdminBackend,
    ) : RemoteUnlockOperation {
        private val keyguardManager = context.getSystemService(KeyguardManager::class.java)
        private val mutex = Mutex()

        override suspend fun unlock(): RemoteUnlockOutcome =
            mutex.withLock {
                val status = store.status()
                if (!status.configured) return@withLock RemoteUnlockOutcome.NOT_CONFIGURED
                if (!status.enabled) return@withLock RemoteUnlockOutcome.DISABLED
                if (!status.armed) {
                    return@withLock RemoteUnlockOutcome.TEMPORARILY_BLOCKED
                }
                if (backend.readiness() != PrivilegedAdminReadiness.Ready) {
                    return@withLock RemoteUnlockOutcome.UNAVAILABLE
                }
                if (!keyguardManager.isDeviceLocked) return@withLock RemoteUnlockOutcome.ALREADY_UNLOCKED
                if (!store.consumeArm()) return@withLock RemoteUnlockOutcome.TEMPORARILY_BLOCKED

                val injected =
                    runCatching {
                        store.withDecryptedDigits { digits ->
                            backend.injectUnlockDigitsForLocalFeasibilityTest(digits)
                        }
                    }.getOrDefault(false)
                delay(KEYGUARD_SETTLE_MS)
                if (injected && !keyguardManager.isDeviceLocked) {
                    RemoteUnlockOutcome.UNLOCKED
                } else {
                    store.recordFailure()
                    RemoteUnlockOutcome.UNLOCK_FAILED_REARM_REQUIRED
                }
            }

        private companion object {
            const val KEYGUARD_SETTLE_MS = 1_500L
        }
    }
