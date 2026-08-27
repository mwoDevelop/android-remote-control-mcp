package com.mwodevelop.androidremotecontrol.shizukuadmin

import android.content.Context
import android.content.pm.PackageManager
import rikka.shizuku.Shizuku

internal const val SHIZUKU_PACKAGE = "moe.shizuku.privileged.api"

internal interface ShizukuStateProbe {
    fun isInstalled(): Boolean

    fun isBinderReachable(): Boolean

    fun hasPermission(): Boolean

    fun requestPermission()
}

internal class AndroidShizukuStateProbe(
    private val context: Context,
) : ShizukuStateProbe {
    override fun isInstalled(): Boolean = shizukuPackageInfo().isSuccess

    private fun shizukuPackageInfo() =
        runCatching {
            context.packageManager.getPackageInfo(SHIZUKU_PACKAGE, 0)
        }

    override fun isBinderReachable(): Boolean = runCatching { Shizuku.pingBinder() }.getOrDefault(false)

    override fun hasPermission(): Boolean =
        runCatching { Shizuku.checkSelfPermission() == PackageManager.PERMISSION_GRANTED }.getOrDefault(false)

    override fun requestPermission() {
        Shizuku.requestPermission(SHIZUKU_PERMISSION_REQUEST_CODE)
    }
}

internal data class CommandResult(
    val exitCode: Int,
    val stdout: String,
    val stderr: String,
    val stdoutTruncated: Boolean,
    val stderrTruncated: Boolean,
)

internal fun interface PrivilegedCommandExecutor {
    suspend fun execute(
        command: String,
        args: List<String>,
        limits: CommandLimits,
    ): CommandResult
}

internal data class CommandLimits(
    val timeoutMs: Long,
    val maxStdoutBytes: Int,
    val maxStderrBytes: Int,
)

internal class ShizukuPrivilegedAdminBackend(
    private val stateProbe: ShizukuStateProbe,
    private val commandExecutor: PrivilegedCommandExecutor,
) : PrivilegedAdminBackend {
    override fun readiness(): PrivilegedAdminReadiness =
        try {
            when {
                !stateProbe.isInstalled() -> PrivilegedAdminReadiness.ShizukuNotInstalled
                !stateProbe.isBinderReachable() -> PrivilegedAdminReadiness.ShizukuServiceStopped
                !stateProbe.hasPermission() -> PrivilegedAdminReadiness.PermissionRequired
                else -> PrivilegedAdminReadiness.Ready
            }
        } catch (_: SecurityException) {
            PrivilegedAdminReadiness.InternalError
        }

    override fun requestPermission() {
        when (readiness()) {
            PrivilegedAdminReadiness.Ready -> {
                return
            }

            PrivilegedAdminReadiness.PermissionRequired -> {
                runCatching { stateProbe.requestPermission() }
                    .getOrElse { throw PrivilegedAdminException.ExecutionFailed() }
            }

            else -> {
                throw PrivilegedAdminException.Unavailable()
            }
        }
    }

    override suspend fun getTopWindow(): TopWindowInfo {
        requireReady()
        val result = executeTopWindowCommand()
        validateTopWindowResult(result)
        return TopWindowParser.parse(result.stdout)
    }

    override suspend fun uninstallApplication(packageName: String): ApplicationUninstallResult {
        require(PACKAGE_NAME.matches(packageName)) { "Invalid Android package name" }
        requireReady()
        val result =
            executePackageManagerCommand(
                listOf("uninstall", "--user", ANDROID_USER_ID.toString(), packageName),
            )
        validateUninstallResult(result)
        return ApplicationUninstallResult(packageName = packageName, androidUserId = ANDROID_USER_ID)
    }

    private fun requireReady() {
        when (readiness()) {
            PrivilegedAdminReadiness.Ready -> Unit
            PrivilegedAdminReadiness.PermissionRequired -> throw PrivilegedAdminException.PermissionDenied()
            else -> throw PrivilegedAdminException.Unavailable()
        }
    }

    private suspend fun executeTopWindowCommand(): CommandResult =
        try {
            commandExecutor.execute("dumpsys", listOf("window"), TOP_WINDOW_LIMITS)
        } catch (e: PrivilegedAdminException) {
            throw e
        } catch (_: Exception) {
            throw PrivilegedAdminException.ExecutionFailed()
        }

    private suspend fun executePackageManagerCommand(args: List<String>): CommandResult =
        try {
            commandExecutor.execute("pm", args, PACKAGE_OPERATION_LIMITS)
        } catch (e: PrivilegedAdminException) {
            throw e
        } catch (_: Exception) {
            throw PrivilegedAdminException.ExecutionFailed()
        }

    private fun validateTopWindowResult(result: CommandResult) {
        if (result.stdoutTruncated || result.stderrTruncated) {
            throw PrivilegedAdminException.OutputTruncated()
        }
        if (result.exitCode != 0) {
            throw PrivilegedAdminException.CommandFailed(result.exitCode)
        }
    }

    private fun validateUninstallResult(result: CommandResult) {
        rejectTruncatedResult(result)
        rejectNonZeroResult(result)
        if (result.stdout.lineSequence().none { it.trim() == PACKAGE_MANAGER_SUCCESS }) {
            throw PrivilegedAdminException.OperationRejected()
        }
    }

    private fun rejectTruncatedResult(result: CommandResult) {
        if (result.stdoutTruncated || result.stderrTruncated) {
            throw PrivilegedAdminException.OutputTruncated()
        }
    }

    private fun rejectNonZeroResult(result: CommandResult) {
        if (result.exitCode != 0) {
            throw PrivilegedAdminException.CommandFailed(result.exitCode)
        }
    }

    private companion object {
        val TOP_WINDOW_LIMITS =
            CommandLimits(
                timeoutMs = 10_000L,
                maxStdoutBytes = 512 * 1024,
                maxStderrBytes = 64 * 1024,
            )
        val PACKAGE_OPERATION_LIMITS =
            CommandLimits(
                timeoutMs = 30_000L,
                maxStdoutBytes = 64 * 1024,
                maxStderrBytes = 64 * 1024,
            )
        const val ANDROID_USER_ID = 0
        const val PACKAGE_MANAGER_SUCCESS = "Success"
        val PACKAGE_NAME = Regex("^[A-Za-z][A-Za-z0-9_]*(?:\\.[A-Za-z][A-Za-z0-9_]*)+$")
    }
}

private const val SHIZUKU_PERMISSION_REQUEST_CODE = 0x5348

/**
 * Parser derived from droid-mcp GetTopWindowTool at commit
 * 6bb968ea551d9de28e41185412391802f0b3bfc6 (Apache-2.0); adapted to application-owned DTOs.
 */
internal object TopWindowParser {
    fun parse(stdout: String): TopWindowInfo {
        val lines = stdout.lineSequence().map(String::trim).toList()
        val currentFocus = lines.firstNotNullOfOrNull(::parseCurrentFocus)
        val focusedApp = lines.firstNotNullOfOrNull(::parseFocusedApp)
        val selectedActivity = currentFocus?.activity ?: focusedApp
        val displayId = lines.firstNotNullOfOrNull(::parseDisplayId)
        return TopWindowInfo(
            packageName = selectedActivity?.packageName,
            activity = selectedActivity?.activity,
            windowClass = currentFocus?.windowClass,
            displayId = displayId,
        )
    }

    private fun parseCurrentFocus(line: String): CurrentFocus? {
        val token = CURRENT_FOCUS.find(line)?.groupValues?.get(1) ?: return null
        val activity = parseActivity(token)
        return CurrentFocus(activity = activity, windowClass = token.takeIf { activity == null })
    }

    private fun parseFocusedApp(line: String): ActivityIdentity? =
        FOCUSED_APP
            .find(line)
            ?.groupValues
            ?.get(1)
            ?.let(::parseActivity)

    private fun parseDisplayId(line: String): Int? =
        DISPLAY_ID
            .find(line)
            ?.groupValues
            ?.get(1)
            ?.toIntOrNull()

    private fun parseActivity(token: String): ActivityIdentity? {
        val slash = token.indexOf('/')
        if (slash <= 0) return null
        val packageName = token.substring(0, slash)
        val rawActivity = token.substring(slash + 1)
        val activity = if (rawActivity.startsWith('.')) "$packageName$rawActivity" else rawActivity
        return ActivityIdentity(packageName, activity)
    }

    private data class CurrentFocus(
        val activity: ActivityIdentity?,
        val windowClass: String?,
    )

    private data class ActivityIdentity(
        val packageName: String,
        val activity: String,
    )

    private val CURRENT_FOCUS = Regex("""mCurrentFocus=Window\{[^}]*\s+(\S+)\}""")
    private val FOCUSED_APP = Regex("""mFocusedApp=\S+\{[^}]*\s(\S+/\S+)""")
    private val DISPLAY_ID = Regex("""displayId=(\d+)""")
}
