package com.mwodevelop.androidremotecontrolmcp.recovery

import android.content.ContentProvider
import android.content.ContentValues
import android.content.Context
import android.database.Cursor
import android.net.Uri
import android.util.Log
import com.danielealbano.androidremotecontrolmcp.data.model.ServerLogEntry
import com.danielealbano.androidremotecontrolmcp.data.model.ServerStatus
import com.danielealbano.androidremotecontrolmcp.data.model.TunnelStatus
import com.danielealbano.androidremotecontrolmcp.data.repository.ServerLogRepository
import com.danielealbano.androidremotecontrolmcp.data.repository.SettingsRepository
import com.danielealbano.androidremotecontrolmcp.services.mcp.McpServerService
import com.danielealbano.androidremotecontrolmcp.services.tunnel.TunnelManager
import dagger.hilt.EntryPoint
import dagger.hilt.InstallIn
import dagger.hilt.android.EntryPointAccessors
import dagger.hilt.components.SingletonComponent
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.launch

private const val TAG = "MCP:OriginRecovery"

@EntryPoint
@InstallIn(SingletonComponent::class)
internal interface OriginRecoveryDependencies {
    fun settingsRepository(): SettingsRepository

    fun serverLogRepository(): ServerLogRepository

    fun tunnelManager(): TunnelManager
}

/**
 * Non-exported, fork-owned process initializer. It is deliberately installed through the manifest
 * instead of modifying the upstream Application or MCP service classes.
 */
internal class McpOriginRecoveryProvider : ContentProvider() {
    override fun onCreate(): Boolean {
        val appContext = context?.applicationContext ?: return false
        val dependencies =
            EntryPointAccessors.fromApplication(
                appContext,
                OriginRecoveryDependencies::class.java,
            )
        McpOriginRecoveryController(appContext, dependencies).start()
        return true
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

internal class McpOriginRecoveryController(
    private val context: Context,
    private val dependencies: OriginRecoveryDependencies,
    private val scope: CoroutineScope = CoroutineScope(SupervisorJob() + Dispatchers.IO),
    probe: OriginHealthProbe = LoopbackOriginHealthProbe(),
) {
    private var generation = 0L

    @Volatile private var pendingRecovery: RecoveryDecision.Accepted? = null

    @Volatile private var explicitStartPending = false

    private var previousIntent: Boolean? = null
    private var previousRunning = false
    private var sawRunning = false
    private val exitDiagnostics = ServiceExitDiagnostics(context)
    private val supervisor =
        OriginRecoverySupervisor(
            scope = scope,
            probe = probe,
            onHealthy = { McpRecoveryRuntime.markHealthy(context) },
            onFailure = { result ->
                Log.w(TAG, "Loopback MCP health probe failed: ${result.name.lowercase()}")
                McpRecoveryRuntime.markUnhealthy(context)
            },
            onRecoveryRequired = ::requestOriginRecovery,
        )

    fun start() {
        exitDiagnostics.previousUncleanGeneration()?.let {
            dependencies.serverLogRepository().log(ServerLogEntry.Type.SERVER, it)
        }
        observePersistedIntent()
        observeServiceAndTunnel()
    }

    private fun observePersistedIntent() {
        scope.launch {
            dependencies.settingsRepository().serverRunning.distinctUntilChanged().collect { running ->
                if (!running) {
                    pendingRecovery = null
                    supervisor.disconnect()
                    McpRecoveryRuntime.invalidate(context)
                } else if (previousIntent == false) {
                    explicitStartPending = true
                }
                previousIntent = running
            }
        }
    }

    private fun observeServiceAndTunnel() {
        scope.launch {
            combine(
                McpServerService.serverStatus,
                dependencies.tunnelManager().tunnelStatus,
            ) { server, tunnel -> server to tunnel }
                .collect { (server, tunnel) -> handleState(server, tunnel) }
        }
    }

    private fun handleState(
        server: ServerStatus,
        tunnel: TunnelStatus,
    ) {
        val running = server as? ServerStatus.Running
        if (running != null && !previousRunning) {
            generation = McpRecoveryRuntime.beginGeneration(context, explicitStartPending)
            explicitStartPending = false
            sawRunning = true
            exitDiagnostics.recordRunning()
        }

        if (running != null && tunnel is TunnelStatus.Connected && !running.httpsEnabled) {
            supervisor.connected(running.port)
        } else {
            supervisor.disconnect()
            McpRecoveryRuntime.markUnhealthy(context)
        }

        if (server is ServerStatus.Stopped) {
            if (sawRunning) exitDiagnostics.recordCleanStop()
            pendingRecovery?.let {
                McpRecoveryRuntime.schedule(context, dependencies.settingsRepository(), it)
                pendingRecovery = null
            }
        }
        previousRunning = running != null
    }

    @Synchronized
    private fun requestOriginRecovery() {
        when (val decision = McpRecoveryRuntime.request(context, generation, RecoveryReason.ORIGIN)) {
            is RecoveryDecision.Accepted -> {
                pendingRecovery = decision
                dependencies.serverLogRepository().log(
                    ServerLogEntry.Type.SERVER,
                    "MCP origin recovery requested; restarting service",
                )
                context.stopService(android.content.Intent(context, McpServerService::class.java))
            }

            RecoveryDecision.BudgetExhausted -> {
                supervisor.disconnect()
                dependencies.serverLogRepository().log(
                    ServerLogEntry.Type.SERVER,
                    "MCP origin recovery budget exhausted; manual start required",
                )
            }

            RecoveryDecision.Duplicate -> {
                Log.i(TAG, "Ignoring duplicate or stale origin recovery request")
            }
        }
    }
}
