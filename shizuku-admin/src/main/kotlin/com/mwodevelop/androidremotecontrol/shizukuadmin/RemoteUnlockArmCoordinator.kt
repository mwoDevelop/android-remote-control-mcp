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
    TRUSTED_ENABLED,
    AUTHENTICATION_CANCELLED,
    AUTHENTICATION_ERROR,
    ARM_FAILED,
    TRUSTED_ENABLE_FAILED,
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
    private var activeAttempt: ActiveAttempt? = null
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
        request(AuthenticatedAction.ARM_ONE_SHOT)
    }

    fun requestEnableTrusted() {
        request(AuthenticatedAction.ENABLE_TRUSTED)
    }

    private fun request(action: AuthenticatedAction) {
        if (!resumed || activeAttempt != null) return
        val attempt = ++nextAttempt
        activeAttempt = ActiveAttempt(attempt, action)
        listener.onBusyChanged(true)
        authenticator.authenticate { result -> handleResult(attempt, action, result) }
    }

    private fun handleResult(
        attempt: Long,
        action: AuthenticatedAction,
        result: LocalAuthenticationResult,
    ) {
        if (!resumed || activeAttempt != ActiveAttempt(attempt, action)) return
        activeAttempt = null
        listener.onBusyChanged(false)
        when (result) {
            LocalAuthenticationResult.SUCCESS -> {
                when (action) {
                    AuthenticatedAction.ARM_ONE_SHOT -> {
                        runCatching { gateway.arm() }
                            .onSuccess { listener.onMessage(RemoteUnlockAdminMessage.ARMED) }
                            .onFailure { listener.onMessage(RemoteUnlockAdminMessage.ARM_FAILED) }
                    }

                    AuthenticatedAction.ENABLE_TRUSTED -> {
                        runCatching { gateway.enableTrusted() }
                            .onSuccess { listener.onMessage(RemoteUnlockAdminMessage.TRUSTED_ENABLED) }
                            .onFailure { listener.onMessage(RemoteUnlockAdminMessage.TRUSTED_ENABLE_FAILED) }
                    }
                }
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

    private enum class AuthenticatedAction {
        ARM_ONE_SHOT,
        ENABLE_TRUSTED,
    }

    private data class ActiveAttempt(
        val id: Long,
        val action: AuthenticatedAction,
    )
}
