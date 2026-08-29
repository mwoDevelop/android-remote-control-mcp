package com.danielealbano.androidremotecontrolmcp.security.remoteunlock

enum class RemoteUnlockMode(
    val wireValue: String,
) {
    ONE_SHOT("one_shot"),
    TRUSTED("trusted"),
    ;

    companion object {
        fun fromStoredValue(value: String): RemoteUnlockMode =
            entries.firstOrNull { it.wireValue == value }
                ?: throw IllegalArgumentException("Unsupported remote-unlock mode")

        fun fromStoredState(
            stateVersion: Int,
            storedValue: String?,
        ): RemoteUnlockMode =
            if (stateVersion >= REMOTE_UNLOCK_STATE_VERSION) {
                fromStoredValue(requireNotNull(storedValue) { "Missing remote-unlock mode" })
            } else {
                ONE_SHOT
            }
    }
}

internal const val REMOTE_UNLOCK_STATE_VERSION = 3

internal data class RemoteUnlockTrustedAttemptWindow(
    val bootCount: Int = INVALID_BOOT_COUNT,
    val lastAttemptElapsedRealtimeMs: Long = 0L,
    val failureWindowStartElapsedRealtimeMs: Long = 0L,
    val failureCount: Int = 0,
) {
    companion object {
        const val INVALID_BOOT_COUNT = -1
    }
}

internal data class RemoteUnlockAttemptPolicyState(
    val mode: RemoteUnlockMode = RemoteUnlockMode.ONE_SHOT,
    val armWindow: RemoteUnlockArmWindow = RemoteUnlockArmWindow(),
    val rearmRequired: Boolean = false,
    val trustedWindow: RemoteUnlockTrustedAttemptWindow = RemoteUnlockTrustedAttemptWindow(),
)

internal data class RemoteUnlockAttemptPolicyStatus(
    val authorized: Boolean,
    val cooldownRemainingMs: Long,
)

/** Pure policy boundary; credential decryption and input injection remain outside this type. */
internal object RemoteUnlockAttemptPolicy {
    fun status(
        state: RemoteUnlockAttemptPolicyState,
        snapshot: RemoteUnlockClockSnapshot?,
    ): RemoteUnlockAttemptPolicyStatus =
        when (state.mode) {
            RemoteUnlockMode.ONE_SHOT -> {
                val remaining = RemoteUnlockArmWindowPolicy.remainingMs(state.armWindow, snapshot)
                RemoteUnlockAttemptPolicyStatus(
                    authorized = !state.rearmRequired && remaining > 0L,
                    cooldownRemainingMs = 0L,
                )
            }

            RemoteUnlockMode.TRUSTED -> {
                val cooldown = trustedCooldownRemainingMs(state.trustedWindow, snapshot)
                RemoteUnlockAttemptPolicyStatus(
                    authorized = snapshot != null && cooldown == 0L,
                    cooldownRemainingMs = cooldown,
                )
            }
        }

    /** Returns the atomically updated state, or null when the current policy rejects the attempt. */
    fun authorize(
        state: RemoteUnlockAttemptPolicyState,
        snapshot: RemoteUnlockClockSnapshot?,
    ): RemoteUnlockAttemptPolicyState? =
        when (state.mode) {
            RemoteUnlockMode.ONE_SHOT -> {
                if (!status(state, snapshot).authorized) {
                    null
                } else {
                    state.copy(armWindow = RemoteUnlockArmWindow())
                }
            }

            RemoteUnlockMode.TRUSTED -> {
                val validSnapshot = snapshot?.takeIf { it.bootCount >= 0 && it.elapsedRealtimeMs >= 0L } ?: return null
                val normalized = normalizeTrustedWindow(state.trustedWindow, validSnapshot)
                if (trustedCooldownRemainingMs(normalized, validSnapshot) > 0L) {
                    null
                } else {
                    state.copy(
                        rearmRequired = false,
                        trustedWindow = normalized.copy(lastAttemptElapsedRealtimeMs = validSnapshot.elapsedRealtimeMs),
                    )
                }
            }
        }

    fun recordSuccess(state: RemoteUnlockAttemptPolicyState): RemoteUnlockAttemptPolicyState =
        when (state.mode) {
            RemoteUnlockMode.ONE_SHOT -> {
                state
            }

            RemoteUnlockMode.TRUSTED -> {
                state.copy(
                    rearmRequired = false,
                    trustedWindow =
                        state.trustedWindow.copy(
                            failureWindowStartElapsedRealtimeMs = 0L,
                            failureCount = 0,
                        ),
                )
            }
        }

    fun recordFailure(
        state: RemoteUnlockAttemptPolicyState,
        snapshot: RemoteUnlockClockSnapshot?,
    ): RemoteUnlockAttemptPolicyState =
        when (state.mode) {
            RemoteUnlockMode.ONE_SHOT -> {
                state.copy(
                    armWindow = RemoteUnlockArmWindow(),
                    rearmRequired = true,
                )
            }

            RemoteUnlockMode.TRUSTED -> {
                val effectiveSnapshot =
                    snapshot?.takeIf { it.bootCount >= 0 && it.elapsedRealtimeMs >= 0L }
                        ?: RemoteUnlockClockSnapshot(
                            bootCount = state.trustedWindow.bootCount,
                            elapsedRealtimeMs = state.trustedWindow.lastAttemptElapsedRealtimeMs,
                        )
                val normalized = normalizeTrustedWindow(state.trustedWindow, effectiveSnapshot)
                val windowStart =
                    normalized.failureWindowStartElapsedRealtimeMs.takeIf { it > 0L }
                        ?: effectiveSnapshot.elapsedRealtimeMs
                state.copy(
                    rearmRequired = false,
                    trustedWindow =
                        normalized.copy(
                            failureWindowStartElapsedRealtimeMs = windowStart,
                            failureCount = (normalized.failureCount + 1).coerceAtMost(MAX_TRUSTED_FAILURES),
                        ),
                )
            }
        }

    private fun trustedCooldownRemainingMs(
        window: RemoteUnlockTrustedAttemptWindow,
        snapshot: RemoteUnlockClockSnapshot?,
    ): Long {
        val validSnapshot =
            snapshot?.takeIf { it.bootCount >= 0 && it.elapsedRealtimeMs >= 0L }
        if (validSnapshot == null) return TRUSTED_FAILURE_WINDOW_MS
        val normalized =
            if (window.bootCount == validSnapshot.bootCount) {
                normalizeTrustedWindow(window, validSnapshot)
            } else {
                RemoteUnlockTrustedAttemptWindow(bootCount = validSnapshot.bootCount)
            }
        val spacingRemaining =
            if (normalized.lastAttemptElapsedRealtimeMs > 0L) {
                (normalized.lastAttemptElapsedRealtimeMs + TRUSTED_ATTEMPT_SPACING_MS - validSnapshot.elapsedRealtimeMs)
                    .coerceAtLeast(0L)
            } else {
                0L
            }
        val failureRemaining =
            if (
                normalized.failureCount >= MAX_TRUSTED_FAILURES &&
                normalized.failureWindowStartElapsedRealtimeMs > 0L
            ) {
                (
                    normalized.failureWindowStartElapsedRealtimeMs + TRUSTED_FAILURE_WINDOW_MS -
                        validSnapshot.elapsedRealtimeMs
                ).coerceAtLeast(0L)
            } else {
                0L
            }
        return maxOf(spacingRemaining, failureRemaining)
    }

    private fun normalizeTrustedWindow(
        window: RemoteUnlockTrustedAttemptWindow,
        snapshot: RemoteUnlockClockSnapshot,
    ): RemoteUnlockTrustedAttemptWindow {
        if (window.bootCount != snapshot.bootCount) {
            return RemoteUnlockTrustedAttemptWindow(bootCount = snapshot.bootCount)
        }
        val failureWindowExpired =
            window.failureWindowStartElapsedRealtimeMs > 0L &&
                snapshot.elapsedRealtimeMs >= window.failureWindowStartElapsedRealtimeMs + TRUSTED_FAILURE_WINDOW_MS
        return if (failureWindowExpired) {
            window.copy(failureWindowStartElapsedRealtimeMs = 0L, failureCount = 0)
        } else {
            window
        }
    }

    const val TRUSTED_ATTEMPT_SPACING_MS = 30_000L
    const val TRUSTED_FAILURE_WINDOW_MS = 10 * 60 * 1_000L
    const val MAX_TRUSTED_FAILURES = 3
}
