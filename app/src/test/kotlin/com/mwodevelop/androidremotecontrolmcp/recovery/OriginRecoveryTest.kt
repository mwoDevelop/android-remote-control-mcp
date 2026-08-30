package com.mwodevelop.androidremotecontrolmcp.recovery

import com.sun.net.httpserver.HttpServer
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test
import java.net.InetSocketAddress
import java.util.concurrent.atomic.AtomicInteger

class OriginRecoveryPolicyTest {
    @Test
    fun `three connected failures request one recovery`() {
        val policy = OriginRecoveryPolicy()
        policy.onConnected()

        assertFalse(policy.onProbe(OriginProbeResult.CONNECTION))
        assertFalse(policy.onProbe(OriginProbeResult.TIMEOUT))
        assertTrue(policy.onProbe(OriginProbeResult.HTTP))
        assertFalse(policy.onProbe(OriginProbeResult.HTTP))
    }

    @Test
    fun `healthy and disconnect reset consecutive failures`() {
        val policy = OriginRecoveryPolicy()
        policy.onConnected()
        assertFalse(policy.onProbe(OriginProbeResult.CONNECTION))
        assertFalse(policy.onProbe(OriginProbeResult.HEALTHY))
        assertFalse(policy.onProbe(OriginProbeResult.CONNECTION))
        policy.onDisconnected()
        assertFalse(policy.onProbe(OriginProbeResult.CONNECTION))
        policy.onConnected()
        assertFalse(policy.onProbe(OriginProbeResult.CONNECTION))
        assertFalse(policy.onProbe(OriginProbeResult.CONNECTION))
        assertTrue(policy.onProbe(OriginProbeResult.CONNECTION))
    }
}

class LoopbackOriginHealthProbeTest {
    @Test
    fun `accepts only loopback HTTP 200 and closes non-200 response`() =
        runTest {
            val server = HttpServer.create(InetSocketAddress("127.0.0.1", 0), 0)
            val calls = AtomicInteger()
            server.createContext("/health") { exchange ->
                val status = if (calls.getAndIncrement() == 0) 200 else 503
                exchange.sendResponseHeaders(status, -1)
                exchange.close()
            }
            server.start()
            try {
                assertEquals(
                    OriginProbeResult.HEALTHY,
                    LoopbackOriginHealthProbe().probe(server.address.port),
                )
                assertEquals(
                    OriginProbeResult.HTTP,
                    LoopbackOriginHealthProbe().probe(server.address.port),
                )
                assertEquals(OriginProbeResult.INVALID_PORT, LoopbackOriginHealthProbe().probe(0))
            } finally {
                server.stop(0)
            }
        }

    @Test
    fun `classifies refused loopback connection without leaking exception text`() =
        runTest {
            val socket = java.net.ServerSocket(0, 1, java.net.InetAddress.getByName("127.0.0.1"))
            val port = socket.localPort
            socket.close()

            assertEquals(OriginProbeResult.CONNECTION, LoopbackOriginHealthProbe().probe(port))
        }
}

@OptIn(ExperimentalCoroutinesApi::class)
class OriginRecoverySupervisorTest {
    @Test
    fun `uses grace and virtual time then stops after threshold`() =
        runTest {
            val dispatcher = StandardTestDispatcher(testScheduler)
            var probes = 0
            var recoveries = 0
            val supervisor =
                OriginRecoverySupervisor(
                    scope = this,
                    probe =
                        OriginHealthProbe {
                            probes += 1
                            OriginProbeResult.CONNECTION
                        },
                    onHealthy = {},
                    onFailure = {},
                    onRecoveryRequired = { recoveries += 1 },
                    timing = OriginRecoveryTiming(startupGraceMs = 20, probeIntervalMs = 10),
                )

            supervisor.connected(8080)
            advanceTimeBy(19)
            runCurrent()
            assertEquals(0, probes)
            advanceTimeBy(1)
            runCurrent()
            assertEquals(1, probes)
            advanceTimeBy(20)
            runCurrent()
            assertEquals(3, probes)
            assertEquals(1, recoveries)

            supervisor.disconnect()
            dispatcher.scheduler.advanceUntilIdle()
            assertEquals(3, probes)
        }

    @Test
    fun `late probe result after disconnect cannot recover`() =
        runTest {
            var recoveries = 0
            val supervisor =
                OriginRecoverySupervisor(
                    scope = this,
                    probe = OriginHealthProbe { OriginProbeResult.CONNECTION },
                    onHealthy = {},
                    onFailure = {},
                    onRecoveryRequired = { recoveries += 1 },
                    timing = OriginRecoveryTiming(startupGraceMs = 10, probeIntervalMs = 10),
                )

            supervisor.connected(8080)
            supervisor.disconnect()
            advanceTimeBy(100)
            runCurrent()

            assertEquals(0, recoveries)
        }
}
