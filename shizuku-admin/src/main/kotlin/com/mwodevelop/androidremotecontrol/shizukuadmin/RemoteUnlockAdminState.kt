package com.mwodevelop.androidremotecontrol.shizukuadmin

import kotlin.math.ceil

internal enum class RemoteUnlockAdminState {
    NOT_CONFIGURED,
    DISABLED,
    REARM_REQUIRED,
    ARMED,
    TRUSTED,
    TRUSTED_RATE_LIMITED,
    READY,
}

internal data class RemoteUnlockAdminViewState(
    val state: RemoteUnlockAdminState,
    val remainingSeconds: Long,
    val cooldownSeconds: Long,
    val shizukuReady: Boolean,
    val canArm: Boolean,
    val canDisarm: Boolean,
    val canEnableTrusted: Boolean,
    val canDisableTrusted: Boolean,
)

internal object RemoteUnlockAdminStateMapper {
    fun map(
        status: RemoteUnlockAdminStatus,
        shizukuReady: Boolean,
    ): RemoteUnlockAdminViewState {
        val state =
            when {
                !status.configured -> {
                    RemoteUnlockAdminState.NOT_CONFIGURED
                }

                !status.enabled -> {
                    RemoteUnlockAdminState.DISABLED
                }

                status.trustedActive && status.cooldownRemainingMs > 0L -> {
                    RemoteUnlockAdminState.TRUSTED_RATE_LIMITED
                }

                status.trustedActive -> {
                    RemoteUnlockAdminState.TRUSTED
                }

                status.rearmRequired -> {
                    RemoteUnlockAdminState.REARM_REQUIRED
                }

                status.armed -> {
                    RemoteUnlockAdminState.ARMED
                }

                else -> {
                    RemoteUnlockAdminState.READY
                }
            }
        return RemoteUnlockAdminViewState(
            state = state,
            remainingSeconds = ceil(status.remainingMs.coerceAtLeast(0L) / MILLIS_PER_SECOND).toLong(),
            cooldownSeconds =
                ceil(status.cooldownRemainingMs.coerceAtLeast(0L) / MILLIS_PER_SECOND).toLong(),
            shizukuReady = shizukuReady,
            canArm = status.configured && status.enabled && !status.armed && !status.trustedActive,
            canDisarm = status.armed,
            canEnableTrusted = status.configured && status.enabled && !status.trustedActive,
            canDisableTrusted = status.trustedActive,
        )
    }

    private const val MILLIS_PER_SECOND = 1_000.0
}
