package com.mwodevelop.androidremotecontrol.shizukuadmin

import android.content.ContentResolver
import android.net.Uri

/** Fixed, same-package control contract for the local remote-unlock administrator UI. */
object RemoteUnlockAdminContract {
    const val AUTHORITY_SUFFIX = ".remote-unlock"
    const val METHOD_STATUS = "status"
    const val METHOD_ARM = "arm"
    const val METHOD_DISARM = "disarm"
    const val KEY_CONFIGURED = "configured"
    const val KEY_ENABLED = "enabled"
    const val KEY_ARMED = "armed"
    const val KEY_REARM_REQUIRED = "rearm_required"
    const val KEY_REMAINING_MS = "remaining_ms"
}

data class RemoteUnlockAdminStatus(
    val configured: Boolean,
    val enabled: Boolean,
    val armed: Boolean,
    val rearmRequired: Boolean,
    val remainingMs: Long,
)

internal interface RemoteUnlockAdminGateway {
    fun status(): RemoteUnlockAdminStatus

    fun arm(): RemoteUnlockAdminStatus

    fun disarm(): RemoteUnlockAdminStatus
}

internal class ContentResolverRemoteUnlockAdminGateway(
    private val contentResolver: ContentResolver,
    packageName: String,
) : RemoteUnlockAdminGateway {
    private val uri = Uri.parse("content://$packageName${RemoteUnlockAdminContract.AUTHORITY_SUFFIX}")

    override fun status() = call(RemoteUnlockAdminContract.METHOD_STATUS)

    override fun arm() = call(RemoteUnlockAdminContract.METHOD_ARM)

    override fun disarm() = call(RemoteUnlockAdminContract.METHOD_DISARM)

    private fun call(method: String): RemoteUnlockAdminStatus {
        val result =
            requireNotNull(contentResolver.call(uri, method, null, null)) {
                "Remote unlock returned no status"
            }
        val remainingMs = result.getLong(RemoteUnlockAdminContract.KEY_REMAINING_MS).coerceAtLeast(0L)
        return RemoteUnlockAdminStatus(
            configured = result.getBoolean(RemoteUnlockAdminContract.KEY_CONFIGURED),
            enabled = result.getBoolean(RemoteUnlockAdminContract.KEY_ENABLED),
            armed = result.getBoolean(RemoteUnlockAdminContract.KEY_ARMED) && remainingMs > 0L,
            rearmRequired = result.getBoolean(RemoteUnlockAdminContract.KEY_REARM_REQUIRED),
            remainingMs = remainingMs,
        )
    }
}
