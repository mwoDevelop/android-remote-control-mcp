package com.mwodevelop.androidremotecontrolmcp.apps

import com.danielealbano.androidremotecontrolmcp.services.accessibility.AccessibilityServiceProvider
import com.danielealbano.androidremotecontrolmcp.services.accessibility.AccessibilityServiceProviderImpl
import kotlinx.coroutines.delay
import kotlinx.coroutines.withTimeoutOrNull

/** Read-only observation. Never grants privileges, dismisses overlays or retries an activity start. */
interface ForegroundAppObserver {
    fun isAvailable(): Boolean

    fun currentPackage(): String?
}

class AccessibilityForegroundAppObserver(
    private val provider: AccessibilityServiceProvider = AccessibilityServiceProviderImpl(),
) : ForegroundAppObserver {
    override fun isAvailable(): Boolean = provider.isReady()

    override fun currentPackage(): String? {
        provider.clearFrameworkNodeCache()
        // Read a fresh node instead of the last TYPE_WINDOW_STATE_CHANGED event, which can be stale.
        return provider.getRootNode()?.packageName?.toString()
    }
}

class AppActivationVerifier(
    private val observer: ForegroundAppObserver = AccessibilityForegroundAppObserver(),
) {
    suspend fun isForegroundConfirmed(packageId: String): Boolean {
        if (!observer.isAvailable()) return false
        return withTimeoutOrNull(CONFIRMATION_TIMEOUT_MS) {
            while (observer.isAvailable()) {
                if (observer.currentPackage() == packageId) return@withTimeoutOrNull true
                delay(POLL_INTERVAL_MS)
            }
            false
        } == true
    }

    companion object {
        const val CONFIRMATION_TIMEOUT_MS = 3_000L
        const val POLL_INTERVAL_MS = 150L
    }
}
