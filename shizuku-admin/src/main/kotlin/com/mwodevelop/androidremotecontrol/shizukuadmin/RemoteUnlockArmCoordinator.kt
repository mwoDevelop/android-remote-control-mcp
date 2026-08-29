package com.mwodevelop.androidremotecontrol.shizukuadmin

internal enum class LocalAuthenticationResult {
    SUCCESS,
    CANCELLED,
    ERROR,
}

internal interface LocalAdministratorAuthenticator {
    fun authenticate(callback: (LocalAuthenticationResult) -> Unit)

    fun cancel()
}

enum class RemoteUnlockAdminMessage {
    ARMED,
    AUTHENTICATION_CANCELLED,
    AUTHENTICATION_ERROR,
    ARM_FAILED,
}

internal interface RemoteUnlockArmCoordinatorListener {
    fun onBusyChanged(busy: Boolean)

    fun onMessage(message: RemoteUnlockAdminMessage)

    fun onRefreshRequested()
}

/** Ensures that one foreground click can produce at most one local arm operation. */
internal class RemoteUnlockArmCoordinator(
    private val authenticator: LocalAdministratorAuthenticator,
    private val gateway: RemoteUnlockAdminGateway,
    private val listener: RemoteUnlockArmCoordinatorListener,
) {
    private var resumed = false
    private var activeAttempt: Long? = null
    private var nextAttempt = 0L

    fun onResume() {
        resumed = true
    }

    fun onStop() {
        resumed = false
        if (activeAttempt != null) {
            activeAttempt = null
            ++nextAttempt
            authenticator.cancel()
            listener.onBusyChanged(false)
        }
    }

    fun requestArm() {
        if (!resumed || activeAttempt != null) return
        val attempt = ++nextAttempt
        activeAttempt = attempt
        listener.onBusyChanged(true)
        authenticator.authenticate { result -> handleResult(attempt, result) }
    }

    private fun handleResult(
        attempt: Long,
        result: LocalAuthenticationResult,
    ) {
        if (!resumed || activeAttempt != attempt) return
        activeAttempt = null
        listener.onBusyChanged(false)
        when (result) {
            LocalAuthenticationResult.SUCCESS -> {
                runCatching { gateway.arm() }
                    .onSuccess { listener.onMessage(RemoteUnlockAdminMessage.ARMED) }
                    .onFailure { listener.onMessage(RemoteUnlockAdminMessage.ARM_FAILED) }
                listener.onRefreshRequested()
            }

            LocalAuthenticationResult.CANCELLED -> {
                listener.onMessage(RemoteUnlockAdminMessage.AUTHENTICATION_CANCELLED)
            }

            LocalAuthenticationResult.ERROR -> {
                listener.onMessage(RemoteUnlockAdminMessage.AUTHENTICATION_ERROR)
            }
        }
    }
}
