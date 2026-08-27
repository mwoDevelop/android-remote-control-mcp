package com.mwodevelop.androidremotecontrol.shizukuadmin

import kotlinx.coroutines.test.runTest
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertInstanceOf
import org.junit.jupiter.api.Test

class ShizukuPrivilegedAdminBackendTest {
    @Test
    fun `readiness distinguishes install service permission and ready states`() {
        assertEquals(
            PrivilegedAdminReadiness.ShizukuNotInstalled,
            backend(probe(installed = false)).readiness(),
        )
        assertEquals(
            PrivilegedAdminReadiness.ShizukuServiceStopped,
            backend(probe(binder = false)).readiness(),
        )
        assertEquals(
            PrivilegedAdminReadiness.PermissionRequired,
            backend(probe(permission = false)).readiness(),
        )
        assertEquals(PrivilegedAdminReadiness.Ready, backend(probe()).readiness())
    }

    @Test
    fun `permission request invokes Shizuku prompt only when permission is required`() {
        var requests = 0
        val missingPermission = probe(permission = false, onRequestPermission = { requests += 1 })

        backend(missingPermission).requestPermission()

        assertEquals(1, requests)
        backend(probe(permission = true, onRequestPermission = { requests += 1 })).requestPermission()
        assertEquals(1, requests)
    }

    @Test
    fun `get top window parses current focus`() =
        runTest {
            val output =
                """
                mCurrentFocus=Window{abc12345 u0 com.example.app/com.example.app.MainActivity}
                displayId=0
                """.trimIndent()
            val result = backend(probe(), executor(stdout = output)).getTopWindow()

            assertEquals("com.example.app", result.packageName)
            assertEquals("com.example.app.MainActivity", result.activity)
            assertEquals(0, result.displayId)
        }

    @Test
    fun `get top window falls back to focused app for a system window`() =
        runTest {
            val output =
                """
                mCurrentFocus=Window{abc12345 u0 NavigationBar0}
                mFocusedApp=ActivityRecord{deadbeef u0 com.example.app/.MainActivity t42}
                displayId=0
                """.trimIndent()
            val result = backend(probe(), executor(stdout = output)).getTopWindow()

            assertEquals("com.example.app", result.packageName)
            assertEquals("com.example.app.MainActivity", result.activity)
            assertEquals("NavigationBar0", result.windowClass)
        }

    @Test
    fun `unready backend rejects without executing a command`() =
        runTest {
            var executed = false
            val target =
                backend(
                    probe(binder = false),
                    PrivilegedCommandExecutor { _, _, _ ->
                        executed = true
                        commandResult()
                    },
                )

            val error = runCatching { target.getTopWindow() }.exceptionOrNull()
            assertInstanceOf(PrivilegedAdminException.Unavailable::class.java, error)
            assertEquals(false, executed)
        }

    @Test
    fun `truncated output is rejected`() =
        runTest {
            val target = backend(probe(), executor(stdoutTruncated = true))

            val error = runCatching { target.getTopWindow() }.exceptionOrNull()
            assertInstanceOf(PrivilegedAdminException.OutputTruncated::class.java, error)
        }

    @Test
    fun `non-zero command exit is rejected`() =
        runTest {
            val target = backend(probe(), executor(exitCode = 7))

            val error =
                assertInstanceOf(
                    PrivilegedAdminException.CommandFailed::class.java,
                    runCatching { target.getTopWindow() }.exceptionOrNull(),
                )
            assertEquals(7, error.exitCode)
        }

    @Test
    fun `uninstall removes a validated package for Android user zero`() =
        runTest {
            var capturedCommand = ""
            var capturedArgs = emptyList<String>()
            val target =
                backend(
                    probe(),
                    PrivilegedCommandExecutor { command, args, limits ->
                        capturedCommand = command
                        capturedArgs = args
                        assertEquals(30_000L, limits.timeoutMs)
                        commandResult(stdout = "Success\n")
                    },
                )

            val result = target.uninstallApplication("com.example.removable")

            assertEquals("pm", capturedCommand)
            assertEquals(listOf("uninstall", "--user", "0", "com.example.removable"), capturedArgs)
            assertEquals(ApplicationUninstallResult("com.example.removable", 0), result)
        }

    @Test
    fun `uninstall rejects malformed package without executing a command`() =
        runTest {
            var executed = false
            val target =
                backend(
                    probe(),
                    PrivilegedCommandExecutor { _, _, _ ->
                        executed = true
                        commandResult(stdout = "Success")
                    },
                )

            val error = runCatching { target.uninstallApplication("com.example;reboot") }.exceptionOrNull()

            assertInstanceOf(IllegalArgumentException::class.java, error)
            assertEquals(false, executed)
        }

    @Test
    fun `uninstall rejects package manager failure text even with zero exit`() =
        runTest {
            val target =
                backend(
                    probe(),
                    PrivilegedCommandExecutor { _, _, _ -> commandResult(stdout = "Failure [not installed]") },
                )

            val error = runCatching { target.uninstallApplication("com.example.removable") }.exceptionOrNull()

            assertInstanceOf(PrivilegedAdminException.OperationRejected::class.java, error)
        }

    private fun backend(
        probe: ShizukuStateProbe,
        executor: PrivilegedCommandExecutor = executor(),
    ) = ShizukuPrivilegedAdminBackend(probe, executor)

    private fun probe(
        installed: Boolean = true,
        binder: Boolean = true,
        permission: Boolean = true,
        onRequestPermission: () -> Unit = {},
    ): ShizukuStateProbe =
        object : ShizukuStateProbe {
            override fun isInstalled() = installed

            override fun isBinderReachable() = binder

            override fun hasPermission() = permission

            override fun requestPermission() = onRequestPermission()
        }

    private fun executor(
        exitCode: Int = 0,
        stdout: String = "",
        stdoutTruncated: Boolean = false,
    ) = PrivilegedCommandExecutor { command, args, limits ->
        assertEquals("dumpsys", command)
        assertEquals(listOf("window"), args)
        assertEquals(10_000L, limits.timeoutMs)
        commandResult(exitCode, stdout, stdoutTruncated)
    }

    private fun commandResult(
        exitCode: Int = 0,
        stdout: String = "",
        stdoutTruncated: Boolean = false,
    ) = CommandResult(
        exitCode = exitCode,
        stdout = stdout,
        stderr = "",
        stdoutTruncated = stdoutTruncated,
        stderrTruncated = false,
    )
}
