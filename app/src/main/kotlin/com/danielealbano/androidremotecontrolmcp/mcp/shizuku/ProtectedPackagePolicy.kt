package com.danielealbano.androidremotecontrolmcp.mcp.shizuku

import android.app.admin.DevicePolicyManager
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import dagger.hilt.android.qualifiers.ApplicationContext
import javax.inject.Inject
import javax.inject.Singleton

/** Resolves packages which privileged destructive operations must never target. */
fun interface ProtectedPackagePolicy {
    fun protectionReason(packageName: String): String?
}

@Singleton
class AndroidProtectedPackagePolicy
    @Inject
    constructor(
        @ApplicationContext private val context: Context,
    ) : ProtectedPackagePolicy {
        override fun protectionReason(packageName: String): String? =
            staticProtectionReason(packageName)
                ?: "the active launcher is protected".takeIf { packageName == resolveDefaultLauncher() }
                ?: "an active device administrator is protected".takeIf {
                    packageName in resolveActiveDeviceAdministrators()
                }

        @Suppress("DEPRECATION")
        private fun resolveDefaultLauncher(): String? =
            runCatching {
                val homeIntent = Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_HOME)
                context.packageManager
                    .resolveActivity(homeIntent, PackageManager.MATCH_DEFAULT_ONLY)
                    ?.activityInfo
                    ?.packageName
            }.getOrNull()

        private fun resolveActiveDeviceAdministrators(): Set<String> =
            runCatching {
                context
                    .getSystemService(DevicePolicyManager::class.java)
                    ?.activeAdmins
                    .orEmpty()
                    .mapTo(mutableSetOf()) { it.packageName }
            }.getOrDefault(emptySet())

        private fun staticProtectionReason(packageName: String): String? =
            when {
                packageName.startsWith(REMOTE_CONTROL_PACKAGE_PREFIX) -> "the MCP server application is protected"
                packageName == SHIZUKU_PACKAGE -> "Shizuku is protected"
                packageName == QUSTODIO_PACKAGE -> "Qustodio is protected"
                packageName in CRITICAL_ANDROID_PACKAGES -> "a critical Android component is protected"
                else -> null
            }

        private companion object {
            const val REMOTE_CONTROL_PACKAGE_PREFIX = "com.danielealbano.androidremotecontrolmcp"
            const val SHIZUKU_PACKAGE = "moe.shizuku.privileged.api"
            const val QUSTODIO_PACKAGE = "com.qustodio.qustodioapp"
            val CRITICAL_ANDROID_PACKAGES =
                setOf(
                    "com.android.settings",
                    "com.android.systemui",
                    "com.android.packageinstaller",
                    "com.google.android.packageinstaller",
                    "com.samsung.android.packageinstaller",
                    "com.sec.android.app.launcher",
                )
        }
    }
