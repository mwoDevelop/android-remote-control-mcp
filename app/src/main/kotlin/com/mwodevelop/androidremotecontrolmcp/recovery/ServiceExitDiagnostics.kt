package com.mwodevelop.androidremotecontrolmcp.recovery

import android.app.ActivityManager
import android.app.ApplicationExitInfo
import android.content.Context
import android.os.Build

/** Bounded post-mortem evidence; no process arguments, trace, URL or credential is retained. */
internal class ServiceExitDiagnostics(
    context: Context,
) {
    private val appContext = context.applicationContext
    private val preferences = appContext.getSharedPreferences("mwodevelop_mcp_lifecycle", Context.MODE_PRIVATE)

    fun previousUncleanGeneration(): String? {
        val previousClean = preferences.getBoolean(KEY_CLEAN, true)
        if (previousClean) return null
        val exit = latestExitCategory()
        return "Previous MCP service generation ended uncleanly${exit?.let { "; process exit=$it" }.orEmpty()}"
    }

    fun recordRunning() {
        preferences.edit().putBoolean(KEY_CLEAN, false).apply()
    }

    fun recordCleanStop() {
        preferences.edit().putBoolean(KEY_CLEAN, true).apply()
    }

    private fun latestExitCategory(): String? =
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) {
            null
        } else {
            appContext
                .getSystemService(ActivityManager::class.java)
                ?.getHistoricalProcessExitReasons(appContext.packageName, 0, 1)
                ?.firstOrNull()
                ?.let { "${reasonCategory(it.reason)}@${it.timestamp};importance=${it.importance}" }
        }

    @Suppress("CyclomaticComplexMethod")
    private fun reasonCategory(reason: Int): String =
        when (reason) {
            ApplicationExitInfo.REASON_EXIT_SELF -> "self"
            ApplicationExitInfo.REASON_SIGNALED -> "signal"
            ApplicationExitInfo.REASON_LOW_MEMORY -> "low_memory"
            ApplicationExitInfo.REASON_CRASH -> "crash"
            ApplicationExitInfo.REASON_CRASH_NATIVE -> "native_crash"
            ApplicationExitInfo.REASON_ANR -> "anr"
            ApplicationExitInfo.REASON_INITIALIZATION_FAILURE -> "initialization"
            ApplicationExitInfo.REASON_PERMISSION_CHANGE -> "permission_change"
            ApplicationExitInfo.REASON_EXCESSIVE_RESOURCE_USAGE -> "resource_usage"
            ApplicationExitInfo.REASON_USER_REQUESTED -> "user_requested"
            ApplicationExitInfo.REASON_USER_STOPPED -> "user_stopped"
            ApplicationExitInfo.REASON_DEPENDENCY_DIED -> "dependency"
            ApplicationExitInfo.REASON_OTHER -> "other"
            else -> "unknown"
        }

    private companion object {
        const val KEY_CLEAN = "previous_generation_clean"
    }
}
