package com.mwodevelop.androidremotecontrol.shizukuadmin

import android.app.Activity
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.view.WindowManager
import rikka.shizuku.Shizuku

/** Local-only administrator surface delivered as an isolated fork extension. */
class RemoteUnlockAdminActivity :
    Activity(),
    RemoteUnlockArmCoordinatorListener {
    private lateinit var gateway: RemoteUnlockAdminGateway
    private lateinit var coordinator: RemoteUnlockArmCoordinator
    private lateinit var adminView: RemoteUnlockAdminView
    private var busy = false
    private val refreshHandler = Handler(Looper.getMainLooper())
    private val refreshRunnable = Runnable { refreshStatusAndSchedule() }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
        gateway = ContentResolverRemoteUnlockAdminGateway(contentResolver, packageName)
        coordinator =
            RemoteUnlockArmCoordinator(
                authenticator = PlatformLocalAdministratorAuthenticator(this),
                gateway = gateway,
                listener = this,
            )
        adminView = RemoteUnlockAdminView(this)
        adminView.setActionListeners(
            coordinator::requestArm,
            ::disarm,
            coordinator::requestEnableTrusted,
            ::disableTrusted,
            ::refreshStatus,
        )
        setContentView(adminView)
    }

    override fun onResume() {
        super.onResume()
        coordinator.onResume()
        refreshStatusAndSchedule()
    }

    override fun onStop() {
        refreshHandler.removeCallbacks(refreshRunnable)
        coordinator.onStop()
        super.onStop()
    }

    override fun onBusyChanged(busy: Boolean) {
        this.busy = busy
        refreshStatus()
    }

    override fun onMessage(message: RemoteUnlockAdminMessage) {
        adminView.showMessage(message)
    }

    override fun onRefreshRequested() {
        refreshStatus()
    }

    private fun refreshStatusAndSchedule() {
        refreshStatus()
        refreshHandler.removeCallbacks(refreshRunnable)
        refreshHandler.postDelayed(refreshRunnable, STATUS_REFRESH_MS)
    }

    private fun refreshStatus() {
        runCatching {
            val shizukuReady =
                Shizuku.pingBinder() &&
                    Shizuku.checkSelfPermission() == android.content.pm.PackageManager.PERMISSION_GRANTED
            RemoteUnlockAdminStateMapper.map(gateway.status(), shizukuReady)
        }.onSuccess { state ->
            adminView.render(state, busy)
        }.onFailure {
            adminView.renderUnavailable()
        }
    }

    private fun disarm() {
        val success = runCatching { gateway.disarm() }.isSuccess
        adminView.showDisarmResult(success)
        refreshStatus()
    }

    private fun disableTrusted() {
        val success = runCatching { gateway.disableTrusted() }.isSuccess
        adminView.showDisableTrustedResult(success)
        refreshStatus()
    }

    private companion object {
        const val STATUS_REFRESH_MS = 1_000L
    }
}
