package com.mwodevelop.androidremotecontrolmcp.recovery

import android.app.ForegroundServiceStartNotAllowedException
import android.content.Context
import android.content.Intent
import android.content.SharedPreferences
import android.os.Handler
import android.os.Looper
import android.util.Log
import com.danielealbano.androidremotecontrolmcp.data.repository.SettingsRepository
import com.danielealbano.androidremotecontrolmcp.services.mcp.McpServerService
import kotlinx.coroutines.TimeoutCancellationException
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import java.io.IOException

internal const val RECOVERY_RESTART_DELAY_MS = 1_000L
internal const val RECOVERY_WINDOW_MS = 10 * 60_000L
internal const val RECOVERY_STABLE_RESET_MS = 5 * 60_000L
internal const val RECOVERY_MAX_RESTARTS = 2
private const val INTENT_READ_TIMEOUT_MS = 2_000L
private const val RECOVERY_PREFS = "mwodevelop_mcp_recovery"
private const val TAG = "MCP:Recovery"

internal enum class RecoveryReason {
    ORIGIN,
    TUNNEL,
}

internal sealed interface RecoveryDecision {
    data class Accepted(
        val generation: Long,
        val reason: RecoveryReason,
    ) : RecoveryDecision

    data object Duplicate : RecoveryDecision

    data object BudgetExhausted : RecoveryDecision
}

internal interface RecoveryStateStore {
    var windowStartedAtMs: Long
    var restartCount: Int
    var healthySinceMs: Long

    fun clear()
}

internal class SharedPreferencesRecoveryStateStore(
    private val preferences: SharedPreferences,
) : RecoveryStateStore {
    override var windowStartedAtMs: Long
        get() = preferences.getLong("window_started_at_ms", 0L)
        set(value) = preferences.edit().putLong("window_started_at_ms", value).apply()

    override var restartCount: Int
        get() = preferences.getInt("restart_count", 0)
        set(value) = preferences.edit().putInt("restart_count", value).apply()

    override var healthySinceMs: Long
        get() = preferences.getLong("healthy_since_ms", 0L)
        set(value) = preferences.edit().putLong("healthy_since_ms", value).apply()

    override fun clear() {
        preferences.edit().clear().apply()
    }
}

/** Shared rolling-window breaker used by both the origin and tunnel recovery paths. */
internal class RecoveryCircuitBreaker(
    private val state: RecoveryStateStore,
    private val nowMs: () -> Long = System::currentTimeMillis,
    private val maxRestarts: Int = RECOVERY_MAX_RESTARTS,
    private val windowMs: Long = RECOVERY_WINDOW_MS,
    private val stableResetMs: Long = RECOVERY_STABLE_RESET_MS,
) {
    @Synchronized
    fun resetForExplicitStart() = state.clear()

    @Synchronized
    fun markUnhealthy() {
        state.healthySinceMs = 0L
    }

    @Synchronized
    fun markHealthy() {
        val now = nowMs()
        val healthySince = state.healthySinceMs
        if (healthySince == 0L) {
            state.healthySinceMs = now
        } else if (now - healthySince >= stableResetMs) {
            state.clear()
            state.healthySinceMs = now
        }
    }

    @Synchronized
    fun tryAcquire(): Boolean {
        val now = nowMs()
        val windowStart = state.windowStartedAtMs
        if (windowStart == 0L || now < windowStart || now - windowStart >= windowMs) {
            state.windowStartedAtMs = now
            state.restartCount = 0
        }
        if (state.restartCount >= maxRestarts) return false
        state.restartCount += 1
        state.healthySinceMs = 0L
        return true
    }
}

/**
 * Pure, synchronized arbitration core. The first failure reason wins for a generation; all delayed
 * work must recheck [isCurrent] before it can restart anything.
 */
internal class RecoveryCoordinator(
    private val circuitBreaker: RecoveryCircuitBreaker,
) {
    private var generation = 0L
    private var pending = false

    @Synchronized
    fun beginGeneration(explicitStart: Boolean): Long {
        generation += 1
        pending = false
        if (explicitStart) circuitBreaker.resetForExplicitStart()
        return generation
    }

    @Synchronized
    fun invalidate(): Long {
        generation += 1
        pending = false
        circuitBreaker.markUnhealthy()
        return generation
    }

    @Synchronized
    fun request(
        generationToken: Long,
        reason: RecoveryReason,
    ): RecoveryDecision =
        when {
            generationToken != generation || pending -> {
                RecoveryDecision.Duplicate
            }

            !circuitBreaker.tryAcquire() -> {
                RecoveryDecision.BudgetExhausted
            }

            else -> {
                pending = true
                RecoveryDecision.Accepted(generationToken, reason)
            }
        }

    @Synchronized
    fun isCurrent(generationToken: Long): Boolean = generationToken == generation && pending

    fun markHealthy() = circuitBreaker.markHealthy()

    fun markUnhealthy() = circuitBreaker.markUnhealthy()
}

/** Process-wide Android adapter; delayed restart survives destruction of a Service instance. */
internal object McpRecoveryRuntime {
    private val handler = Handler(Looper.getMainLooper())
    private var coordinator: RecoveryCoordinator? = null
    private var scheduledRestart: Runnable? = null

    @Synchronized
    fun beginGeneration(
        context: Context,
        explicitStart: Boolean,
    ): Long {
        cancelScheduledLocked()
        return coordinator(context).beginGeneration(explicitStart)
    }

    @Synchronized
    fun invalidate(context: Context) {
        cancelScheduledLocked()
        coordinator(context).invalidate()
    }

    @Synchronized
    fun request(
        context: Context,
        generation: Long,
        reason: RecoveryReason,
    ): RecoveryDecision = coordinator(context).request(generation, reason)

    @Synchronized
    fun markHealthy(context: Context) = coordinator(context).markHealthy()

    @Synchronized
    fun markUnhealthy(context: Context) = coordinator(context).markUnhealthy()

    @Synchronized
    fun schedule(
        context: Context,
        settingsRepository: SettingsRepository,
        accepted: RecoveryDecision.Accepted,
    ) {
        cancelScheduledLocked()
        if (coordinator?.isCurrent(accepted.generation) != true) return
        val appContext = context.applicationContext
        val task =
            Runnable {
                synchronized(this) {
                    scheduledRestart = null
                    if (coordinator?.isCurrent(accepted.generation) != true) return@Runnable
                }
                if (!readServerRunningOrFalse(settingsRepository)) {
                    Log.i(TAG, "Skipping stale recovery restart; persisted intent is stopped")
                    return@Runnable
                }
                synchronized(this) {
                    if (coordinator?.isCurrent(accepted.generation) != true) return@Runnable
                }
                try {
                    appContext.startForegroundService(
                        Intent(appContext, McpServerService::class.java).apply {
                            action = McpServerService.ACTION_RECOVER_TUNNEL
                        },
                    )
                } catch (e: ForegroundServiceStartNotAllowedException) {
                    Log.w(TAG, "Recovery restart refused by Android foreground-service policy", e)
                }
            }
        scheduledRestart = task
        handler.postDelayed(task, RECOVERY_RESTART_DELAY_MS)
    }

    private fun coordinator(context: Context): RecoveryCoordinator =
        coordinator
            ?: RecoveryCoordinator(
                RecoveryCircuitBreaker(
                    SharedPreferencesRecoveryStateStore(
                        context.applicationContext.getSharedPreferences(RECOVERY_PREFS, Context.MODE_PRIVATE),
                    ),
                ),
            ).also { coordinator = it }

    private fun cancelScheduledLocked() {
        scheduledRestart?.let(handler::removeCallbacks)
        scheduledRestart = null
    }
}

internal fun readServerRunningOrFalse(
    settingsRepository: SettingsRepository,
    timeoutMs: Long = INTENT_READ_TIMEOUT_MS,
): Boolean =
    try {
        runBlocking { withTimeout(timeoutMs) { settingsRepository.serverRunning.first() } }
    } catch (e: TimeoutCancellationException) {
        Log.w(TAG, "Timed out reading persisted server_running; recovery fails closed", e)
        false
    } catch (e: IOException) {
        Log.w(TAG, "Failed reading persisted server_running; recovery fails closed", e)
        false
    }
