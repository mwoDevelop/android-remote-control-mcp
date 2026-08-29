package com.mwodevelop.androidremotecontrol.shizukuadmin

import kotlin.math.ceil

internal enum class RemoteUnlockAdminState {
    NOT_CONFIGURED,
    DISABLED,
    REARM_REQUIRED,
    ARMED,
    READY,
}

internal data class RemoteUnlockAdminViewState(
    val state: RemoteUnlockAdminState,
    val remainingSeconds: Long,
    val shizukuReady: Boolean,
    val canArm: Boolean,
    val canDisarm: Boolean,
)

internal object RemoteUnlockAdminStateMapper {
    fun map(
        status: RemoteUnlockAdminStatus,
        shizukuReady: Boolean,
    ): RemoteUnlockAdminViewState {
        val state =
            when {
                !status.configured -> RemoteUnlockAdminState.NOT_CONFIGURED
                !status.enabled -> RemoteUnlockAdminState.DISABLED
                status.rearmRequired -> RemoteUnlockAdminState.REARM_REQUIRED
                status.armed -> RemoteUnlockAdminState.ARMED
                else -> RemoteUnlockAdminState.READY
            }
        return RemoteUnlockAdminViewState(
            state = state,
            remainingSeconds = ceil(status.remainingMs.coerceAtLeast(0L) / MILLIS_PER_SECOND).toLong(),
            shizukuReady = shizukuReady,
            canArm = status.configured && status.enabled && !status.armed,
            canDisarm = status.armed,
        )
    }

    private const val MILLIS_PER_SECOND = 1_000.0
}
