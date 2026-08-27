package com.mwodevelop.androidremotecontrol.shizukuadmin

import android.content.Context

/** Current readiness of the optional Shizuku administration boundary. */
sealed interface PrivilegedAdminReadiness {
    data object Ready : PrivilegedAdminReadiness

    data object ShizukuNotInstalled : PrivilegedAdminReadiness

    data object ShizukuServiceStopped : PrivilegedAdminReadiness

    data object PermissionRequired : PrivilegedAdminReadiness

    data object InternalError : PrivilegedAdminReadiness
}

/** Structured foreground-window result returned by the first read-only privileged operation. */
data class TopWindowInfo(
    val packageName: String?,
    val activity: String?,
    val windowClass: String?,
    val displayId: Int?,
)

/** Successful removal of an installed package from the selected Android user. */
data class ApplicationUninstallResult(
    val packageName: String,
    val androidUserId: Int,
)

/** Stable failures exposed by the module to its host application. */
sealed class PrivilegedAdminException(
    message: String,
) : Exception(message) {
    class Unavailable : PrivilegedAdminException("Shizuku administration is not ready")

    class PermissionDenied : PrivilegedAdminException("Shizuku permission is not granted")

    class CommandFailed(
        val exitCode: Int,
    ) : PrivilegedAdminException("Privileged command failed with exit code $exitCode")

    class OutputTruncated : PrivilegedAdminException("Privileged command output exceeded its safety limit")

    class ExecutionFailed : PrivilegedAdminException("Privileged command execution failed")

    class OperationRejected : PrivilegedAdminException("Privileged operation was rejected by Android")
}

/** Application-owned privileged API. No droid-mcp or Shizuku types cross this boundary. */
interface PrivilegedAdminBackend {
    fun readiness(): PrivilegedAdminReadiness

    /** Requests the standard Shizuku permission dialog; it never grants permission silently. */
    fun requestPermission()

    suspend fun getTopWindow(): TopWindowInfo

    /** Removes [packageName] for Android user 0; a system-partition APK is not deleted. */
    suspend fun uninstallApplication(packageName: String): ApplicationUninstallResult
}

/** Creates the production backend while keeping implementation types private to this module. */
object PrivilegedAdminBackendFactory {
    fun create(context: Context): PrivilegedAdminBackend =
        ShizukuPrivilegedAdminBackend(
            stateProbe = AndroidShizukuStateProbe(context.applicationContext),
            commandExecutor = ShizukuProcessCommandExecutor(),
        )
}
