package com.mwodevelop.androidremotecontrolmcp.recovery

import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.net.HttpURLConnection
import java.net.Proxy
import java.net.URL

internal const val ORIGIN_STARTUP_GRACE_MS = 20_000L
internal const val ORIGIN_PROBE_INTERVAL_MS = 10_000L
internal const val ORIGIN_PROBE_TIMEOUT_MS = 2_000
internal const val ORIGIN_FAILURE_THRESHOLD = 3
private const val MAX_TCP_PORT = 65_535

internal enum class OriginProbeResult {
    HEALTHY,
    TIMEOUT,
    CONNECTION,
    HTTP,
    INVALID_PORT,
}

internal fun interface OriginHealthProbe {
    suspend fun probe(port: Int): OriginProbeResult
}

/** A fixed loopback-only health probe. It never follows redirects or uses a configured system proxy. */
internal class LoopbackOriginHealthProbe(
    private val dispatcher: CoroutineDispatcher = Dispatchers.IO,
) : OriginHealthProbe {
    override suspend fun probe(port: Int): OriginProbeResult =
        withContext(dispatcher) {
            if (port !in 1..MAX_TCP_PORT) return@withContext OriginProbeResult.INVALID_PORT
            val connection =
                try {
                    URL("http://127.0.0.1:$port/health").openConnection(Proxy.NO_PROXY) as HttpURLConnection
                } catch (_: IllegalArgumentException) {
                    return@withContext OriginProbeResult.INVALID_PORT
                }
            try {
                connection.requestMethod = "GET"
                connection.connectTimeout = ORIGIN_PROBE_TIMEOUT_MS
                connection.readTimeout = ORIGIN_PROBE_TIMEOUT_MS
                connection.instanceFollowRedirects = false
                connection.useCaches = false
                if (connection.responseCode == HttpURLConnection.HTTP_OK) {
                    OriginProbeResult.HEALTHY
                } else {
                    OriginProbeResult.HTTP
                }
            } catch (_: java.net.SocketTimeoutException) {
                OriginProbeResult.TIMEOUT
            } catch (_: java.io.IOException) {
                OriginProbeResult.CONNECTION
            } finally {
                connection.disconnect()
            }
        }
}

/** Pure state machine; scheduling and transport are deliberately outside it. */
internal class OriginRecoveryPolicy(
    private val failureThreshold: Int = ORIGIN_FAILURE_THRESHOLD,
) {
    private var connected = false
    private var consecutiveFailures = 0
    private var recoveryEmitted = false

    fun onConnected() {
        if (!connected) consecutiveFailures = 0
        connected = true
    }

    fun onDisconnected() {
        connected = false
        consecutiveFailures = 0
        recoveryEmitted = false
    }

    fun onProbe(result: OriginProbeResult): Boolean {
        var required = false
        if (connected && !recoveryEmitted) {
            if (result == OriginProbeResult.HEALTHY) {
                consecutiveFailures = 0
            } else {
                consecutiveFailures += 1
                if (consecutiveFailures >= failureThreshold) {
                    recoveryEmitted = true
                    required = true
                }
            }
        }
        return required
    }
}

internal data class OriginRecoveryTiming(
    val startupGraceMs: Long = ORIGIN_STARTUP_GRACE_MS,
    val probeIntervalMs: Long = ORIGIN_PROBE_INTERVAL_MS,
)

/**
 * Best-effort foreground-process supervision. Android Doze may delay the coroutine; it does not
 * weaken the consecutive-failure rule and never turns this into an alarm/wakelock loop.
 */
internal class OriginRecoverySupervisor(
    private val scope: CoroutineScope,
    private val probe: OriginHealthProbe,
    private val onHealthy: () -> Unit,
    private val onFailure: (OriginProbeResult) -> Unit,
    private val onRecoveryRequired: () -> Unit,
    private val timing: OriginRecoveryTiming = OriginRecoveryTiming(),
) {
    private var job: Job? = null
    private var port: Int? = null
    private val policy = OriginRecoveryPolicy()

    @Synchronized
    fun connected(originPort: Int) {
        if (job?.isActive == true && port == originPort) return
        disconnect()
        port = originPort
        policy.onConnected()
        job =
            scope.launch {
                delay(timing.startupGraceMs)
                while (isActive) {
                    val result = probe.probe(originPort)
                    if (!isActive) return@launch
                    if (result == OriginProbeResult.HEALTHY) {
                        onHealthy()
                    } else {
                        onFailure(result)
                    }
                    if (policy.onProbe(result)) {
                        onRecoveryRequired()
                        return@launch
                    }
                    delay(timing.probeIntervalMs)
                }
            }
    }

    @Synchronized
    fun disconnect() {
        job?.cancel()
        job = null
        port = null
        policy.onDisconnected()
    }
}
