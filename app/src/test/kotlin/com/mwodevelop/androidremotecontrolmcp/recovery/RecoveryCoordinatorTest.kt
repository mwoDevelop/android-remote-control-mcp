package com.mwodevelop.androidremotecontrolmcp.recovery

import com.danielealbano.androidremotecontrolmcp.data.repository.SettingsRepository
import io.mockk.every
import io.mockk.mockk
import kotlinx.coroutines.awaitCancellation
import kotlinx.coroutines.flow.flow
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Assertions.assertInstanceOf
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test

class RecoveryCoordinatorTest {
    private class MemoryState : RecoveryStateStore {
        override var windowStartedAtMs = 0L
        override var restartCount = 0
        override var healthySinceMs = 0L

        override fun clear() {
            windowStartedAtMs = 0L
            restartCount = 0
            healthySinceMs = 0L
        }
    }

    @Test
    fun `origin and tunnel share first reason arbitration`() {
        val coordinator = coordinator()
        val generation = coordinator.beginGeneration(explicitStart = true)

        assertInstanceOf(
            RecoveryDecision.Accepted::class.java,
            coordinator.request(generation, RecoveryReason.ORIGIN),
        )
        assertEquals(
            RecoveryDecision.Duplicate,
            coordinator.request(generation, RecoveryReason.TUNNEL),
        )
    }

    @Test
    fun `explicit stop invalidates stale callback and stale request`() {
        val coordinator = coordinator()
        val generation = coordinator.beginGeneration(explicitStart = true)
        coordinator.request(generation, RecoveryReason.ORIGIN)
        coordinator.invalidate()

        assertFalse(coordinator.isCurrent(generation))
        assertEquals(
            RecoveryDecision.Duplicate,
            coordinator.request(generation, RecoveryReason.ORIGIN),
        )
    }

    @Test
    fun `new explicit start during teardown invalidates old generation`() {
        val coordinator = coordinator()
        val oldGeneration = coordinator.beginGeneration(explicitStart = true)
        coordinator.request(oldGeneration, RecoveryReason.ORIGIN)

        val newGeneration = coordinator.beginGeneration(explicitStart = true)

        assertFalse(coordinator.isCurrent(oldGeneration))
        assertTrue(newGeneration > oldGeneration)
        assertInstanceOf(
            RecoveryDecision.Accepted::class.java,
            coordinator.request(newGeneration, RecoveryReason.TUNNEL),
        )
    }

    @Test
    fun `third automatic restart in ten minutes is rejected across generations`() {
        var now = 1_000L
        val coordinator = coordinator(nowMs = { now })
        repeat(2) {
            val generation = coordinator.beginGeneration(explicitStart = false)
            assertInstanceOf(
                RecoveryDecision.Accepted::class.java,
                coordinator.request(generation, RecoveryReason.ORIGIN),
            )
            now += 1_000
        }
        val thirdGeneration = coordinator.beginGeneration(explicitStart = false)

        assertEquals(
            RecoveryDecision.BudgetExhausted,
            coordinator.request(thirdGeneration, RecoveryReason.TUNNEL),
        )
    }

    @Test
    fun `explicit start resets exhausted budget`() {
        var now = 1_000L
        val coordinator = coordinator(nowMs = { now })
        repeat(2) {
            val generation = coordinator.beginGeneration(explicitStart = false)
            coordinator.request(generation, RecoveryReason.ORIGIN)
            now += 1_000
        }

        val explicitGeneration = coordinator.beginGeneration(explicitStart = true)

        assertInstanceOf(
            RecoveryDecision.Accepted::class.java,
            coordinator.request(explicitGeneration, RecoveryReason.ORIGIN),
        )
    }

    @Test
    fun `five healthy minutes reset recovery budget`() {
        var now = 1_000L
        val state = MemoryState()
        val breaker = RecoveryCircuitBreaker(state, nowMs = { now })
        assertTrue(breaker.tryAcquire())
        assertTrue(breaker.tryAcquire())
        assertFalse(breaker.tryAcquire())

        breaker.markHealthy()
        now += RECOVERY_STABLE_RESET_MS
        breaker.markHealthy()

        assertTrue(breaker.tryAcquire())
    }

    @Test
    fun `persisted intent timeout fails closed`() {
        val repository = mockk<SettingsRepository>()
        every { repository.serverRunning } returns flow { awaitCancellation() }

        assertFalse(readServerRunningOrFalse(repository, timeoutMs = 1))
    }

    private fun coordinator(nowMs: () -> Long = { 1_000L }): RecoveryCoordinator =
        RecoveryCoordinator(RecoveryCircuitBreaker(MemoryState(), nowMs = nowMs))
}
