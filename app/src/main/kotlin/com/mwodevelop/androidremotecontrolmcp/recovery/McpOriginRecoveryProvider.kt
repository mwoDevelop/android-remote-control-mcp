package com.mwodevelop.androidremotecontrolmcp.recovery

import android.content.ContentProvider
import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.database.Cursor
import android.net.Uri
import android.os.Bundle
import android.util.Log
import com.danielealbano.androidremotecontrolmcp.data.model.ServerLogEntry
import com.danielealbano.androidremotecontrolmcp.data.model.ServerStatus
import com.danielealbano.androidremotecontrolmcp.data.repository.ServerLogRepository
import com.danielealbano.androidremotecontrolmcp.data.repository.SettingsRepository
import com.danielealbano.androidremotecontrolmcp.services.mcp.McpServerService
import dagger.hilt.EntryPoint
import dagger.hilt.InstallIn
import dagger.hilt.android.EntryPointAccessors
import dagger.hilt.components.SingletonComponent
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.launch

private const val TAG = "MCP:OriginRecovery"
internal const val RECOVERY_CONTROL_METHOD_STATUS = "status"
internal const val RECOVERY_CONTROL_METHOD_RECOVER = "recover"

@EntryPoint
@InstallIn(SingletonComponent::class)
internal interface OriginRecoveryDependencies {
    fun settingsRepository(): SettingsRepository

    fun serverLogRepository(): ServerLogRepository
}

/**
 * Fork-owned process initializer and narrow host control boundary. Android's DUMP permission keeps
 * calls restricted to adb/shell while the controller remains isolated from upstream components.
 */
internal class McpOriginRecoveryProvider : ContentProvider() {
    private lateinit var controller: McpOriginRecoveryController

    override fun onCreate(): Boolean {
        val appContext = context?.applicationContext ?: return false
        val dependencies =
            EntryPointAccessors.fromApplication(
                appContext,
                OriginRecoveryDependencies::class.java,
            )
        controller = McpOriginRecoveryController(appContext, dependencies)
        controller.start()
        return true
    }

    override fun call(
        method: String,
        arg: String?,
        extras: Bundle?,
    ): Bundle =
        when (method) {
            RECOVERY_CONTROL_METHOD_STATUS -> controller.status().toBundle()
            RECOVERY_CONTROL_METHOD_RECOVER -> controller.requestHostRecovery().toBundle()
            else -> RecoveryControlStatus(RecoveryControlDecision.UNSUPPORTED).toBundle()
        }

    override fun query(
        uri: Uri,
        projection: Array<out String>?,
        selection: String?,
        selectionArgs: Array<out String>?,
        sortOrder: String?,
    ): Cursor? = null

    override fun getType(uri: Uri): String? = null

    override fun insert(
        uri: Uri,
        values: ContentValues?,
    ): Uri? = null

    override fun delete(
        uri: Uri,
        selection: String?,
        selectionArgs: Array<out String>?,
    ): Int = 0

    override fun update(
        uri: Uri,
        values: ContentValues?,
        selection: String?,
        selectionArgs: Array<out String>?,
    ): Int = 0
}

internal enum class RecoveryControlDecision {
    ACCEPTED,
    INTENT_STOPPED,
    INTENT_UNKNOWN,
    NOT_RUNNING,
    DUPLICATE,
    BUDGET_EXHAUSTED,
    STOP_FAILED,
    UNSUPPORTED,
}

internal data class RecoveryControlStatus(
    val decision: RecoveryControlDecision,
    val intendedRunning: Boolean? = null,
    val serverRunning: Boolean = false,
    val generation: Long = 0L,
    val recoveryInProgress: Boolean = false,
    val budget: RecoveryBudgetSnapshot? = null,
)

private fun RecoveryControlStatus.toBundle(): Bundle =
    Bundle().apply {
        putInt("schema_version", 1)
        putString("decision", decision.name.lowercase())
        intendedRunning?.let { putBoolean("intended_running", it) }
        putBoolean("server_running", serverRunning)
        putLong("generation", generation)
        putBoolean("recovery_in_progress", recoveryInProgress)
        budget?.let {
            putLong("budget_window_started_at_ms", it.windowStartedAtMs)
            putInt("budget_restart_count", it.restartCount)
            putInt("budget_max_restarts", it.maxRestarts)
        }
    }

/** Only plain HTTP is supervised by the in-app loopback probe. */
internal fun supervisedOriginPort(
    server: ServerStatus,
    activeHttpsEnabled: Boolean?,
): Int? =
    (server as? ServerStatus.Running)
        ?.takeIf { activeHttpsEnabled == false }
        ?.port

internal interface ServiceRecoveryGateway {
    fun stop(): Boolean
}

private class AndroidServiceRecoveryGateway(
    private val context: Context,
) : ServiceRecoveryGateway {
    override fun stop(): Boolean = context.stopService(Intent(context, McpServerService::class.java))
}

internal interface RecoveryRuntimeGateway {
    fun beginGeneration(explicitStart: Boolean): Long

    fun invalidate()

    fun request(
        generation: Long,
        reason: RecoveryReason,
    ): RecoveryDecision

    fun markHealthy()

    fun markUnhealthy()

    fun budgetSnapshot(): RecoveryBudgetSnapshot

    fun schedule(
        settingsRepository: SettingsRepository,
        accepted: RecoveryDecision.Accepted,
    )
}

private class AndroidRecoveryRuntimeGateway(
    private val context: Context,
) : RecoveryRuntimeGateway {
    override fun beginGeneration(explicitStart: Boolean): Long = McpRecoveryRuntime.beginGeneration(context, explicitStart)

    override fun invalidate() = McpRecoveryRuntime.invalidate(context)

    override fun request(
        generation: Long,
        reason: RecoveryReason,
    ): RecoveryDecision = McpRecoveryRuntime.request(context, generation, reason)

    override fun markHealthy() = McpRecoveryRuntime.markHealthy(context)

    override fun markUnhealthy() = McpRecoveryRuntime.markUnhealthy(context)

    override fun budgetSnapshot(): RecoveryBudgetSnapshot = McpRecoveryRuntime.budgetSnapshot(context)

    override fun schedule(
        settingsRepository: SettingsRepository,
        accepted: RecoveryDecision.Accepted,
    ) = McpRecoveryRuntime.schedule(context, settingsRepository, accepted)
}

internal class McpOriginRecoveryController(
    private val context: Context,
    private val dependencies: OriginRecoveryDependencies,
    private val scope: CoroutineScope = CoroutineScope(SupervisorJob() + Dispatchers.IO),
    probe: OriginHealthProbe = LoopbackOriginHealthProbe(),
    private val serviceGateway: ServiceRecoveryGateway = AndroidServiceRecoveryGateway(context),
    private val runtime: RecoveryRuntimeGateway = AndroidRecoveryRuntimeGateway(context),
) {
    private var generation = 0L

    @Volatile private var pendingRecovery: RecoveryDecision.Accepted? = null

    @Volatile private var explicitStartPending = false

    @Volatile private var previousIntent: Boolean? = null

    @Volatile private var serverRunning = false

    private var activeHttpsEnabled: Boolean? = null
    private var sawRunning = false
    private val exitDiagnostics = ServiceExitDiagnostics(context)
    private val supervisor =
        OriginRecoverySupervisor(
            scope = scope,
            probe = probe,
            onHealthy = runtime::markHealthy,
            onFailure = { result ->
                Log.w(TAG, "Loopback MCP health probe failed: ${result.name.lowercase()}")
                runtime.markUnhealthy()
            },
            onRecoveryRequired = ::requestOriginRecovery,
        )

    fun start() {
        exitDiagnostics.previousUncleanGeneration()?.let {
            dependencies.serverLogRepository().log(ServerLogEntry.Type.SERVER, it)
        }
        observePersistedIntent()
        observeService()
    }

    private fun observePersistedIntent() {
        scope.launch {
            dependencies.settingsRepository().serverRunning.distinctUntilChanged().collect { running ->
                if (!running) {
                    pendingRecovery = null
                    supervisor.disconnect()
                    runtime.invalidate()
                } else if (previousIntent == false) {
                    explicitStartPending = true
                }
                previousIntent = running
            }
        }
    }

    private fun observeService() {
        scope.launch {
            McpServerService.serverStatus.collect(::handleState)
        }
    }

    private suspend fun handleState(server: ServerStatus) {
        val running = server as? ServerStatus.Running
        if (running != null && !serverRunning) {
            generation = runtime.beginGeneration(explicitStartPending)
            explicitStartPending = false
            sawRunning = true
            exitDiagnostics.recordRunning()
            activeHttpsEnabled =
                runCatching { dependencies.settingsRepository().getServerConfig().httpsEnabled }
                    .onFailure { Log.w(TAG, "Unable to snapshot active server configuration", it) }
                    .getOrNull()
        }

        val originPort = supervisedOriginPort(server, activeHttpsEnabled)
        if (originPort != null) {
            supervisor.connected(originPort)
        } else {
            supervisor.disconnect()
            runtime.markUnhealthy()
        }

        if (server is ServerStatus.Stopped) {
            if (sawRunning) exitDiagnostics.recordCleanStop()
            pendingRecovery?.let {
                runtime.schedule(dependencies.settingsRepository(), it)
                pendingRecovery = null
            }
            activeHttpsEnabled = null
        }
        serverRunning = running != null
    }

    @Synchronized
    fun status(): RecoveryControlStatus =
        RecoveryControlStatus(
            decision =
                when {
                    previousIntent == null -> RecoveryControlDecision.INTENT_UNKNOWN
                    previousIntent == false -> RecoveryControlDecision.INTENT_STOPPED
                    !serverRunning -> RecoveryControlDecision.NOT_RUNNING
                    pendingRecovery != null -> RecoveryControlDecision.DUPLICATE
                    else -> RecoveryControlDecision.ACCEPTED
                },
            intendedRunning = previousIntent,
            serverRunning = serverRunning,
            generation = generation,
            recoveryInProgress = pendingRecovery != null,
            budget = runtime.budgetSnapshot(),
        )

    @Synchronized
    fun requestHostRecovery(): RecoveryControlStatus = requestRecovery(RecoveryReason.ORIGIN)

    @Synchronized
    private fun requestOriginRecovery() {
        requestRecovery(RecoveryReason.ORIGIN)
    }

    private fun requestRecovery(reason: RecoveryReason): RecoveryControlStatus {
        val refusal =
            when {
                previousIntent == null -> RecoveryControlDecision.INTENT_UNKNOWN
                previousIntent == false -> RecoveryControlDecision.INTENT_STOPPED
                else -> null
            }
        if (refusal != null) return status().copy(decision = refusal)

        val decision = runtime.request(generation, reason)
        val controlDecision =
            when (decision) {
                is RecoveryDecision.Accepted -> {
                    pendingRecovery = decision
                    dependencies.serverLogRepository().log(
                        ServerLogEntry.Type.SERVER,
                        "MCP origin recovery requested; restarting service",
                    )
                    if (!serverRunning) {
                        runtime.schedule(dependencies.settingsRepository(), decision)
                        pendingRecovery = null
                        RecoveryControlDecision.ACCEPTED
                    } else if (!serviceGateway.stop()) {
                        pendingRecovery = null
                        supervisor.disconnect()
                        runtime.invalidate()
                        RecoveryControlDecision.STOP_FAILED
                    } else {
                        RecoveryControlDecision.ACCEPTED
                    }
                }

                RecoveryDecision.BudgetExhausted -> {
                    supervisor.disconnect()
                    dependencies.serverLogRepository().log(
                        ServerLogEntry.Type.SERVER,
                        "MCP origin recovery budget exhausted; manual start required",
                    )
                    RecoveryControlDecision.BUDGET_EXHAUSTED
                }

                RecoveryDecision.Duplicate -> {
                    Log.i(TAG, "Ignoring duplicate or stale origin recovery request")
                    RecoveryControlDecision.DUPLICATE
                }
            }
        return status().copy(decision = controlDecision)
    }
}
