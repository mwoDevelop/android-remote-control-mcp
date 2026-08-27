package com.mwodevelop.androidremotecontrol.shizukuadmin

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.TimeoutCancellationException
import kotlinx.coroutines.async
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.runInterruptible
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout
import rikka.shizuku.Shizuku
import java.io.ByteArrayOutputStream
import java.io.InputStream

internal data class BoundedBytes(
    val bytes: ByteArray,
    val truncated: Boolean,
)

internal fun interface ShizukuProcessFactory {
    fun start(
        command: String,
        args: List<String>,
    ): Process
}

/**
 * Process launch approach derived from droid-mcp ShizukuShellBackend at commit
 * 6bb968ea551d9de28e41185412391802f0b3bfc6 (Apache-2.0). Output handling, limits and cancellation
 * are application-owned and deliberately stricter than the referenced implementation.
 */
internal class ReflectiveShizukuProcessFactory : ShizukuProcessFactory {
    override fun start(
        command: String,
        args: List<String>,
    ): Process {
        validateCommand(command, args)
        val method = newProcessMethod ?: throw PrivilegedAdminException.ExecutionFailed()
        return runCatching {
            method.invoke(null, (listOf(command) + args).toTypedArray(), null, null) as Process
        }.getOrElse { throw PrivilegedAdminException.ExecutionFailed() }
    }

    private fun validateCommand(
        command: String,
        args: List<String>,
    ) {
        require(command.isNotBlank() && '\u0000' !in command) { "Invalid command" }
        require(args.none { '\u0000' in it }) { "Invalid command argument" }
    }

    private companion object {
        @Volatile
        private var cached: java.lang.reflect.Method? = null

        val newProcessMethod: java.lang.reflect.Method?
            get() =
                cached ?: runCatching {
                    Shizuku::class.java
                        .getDeclaredMethod(
                            "newProcess",
                            Array<String>::class.java,
                            Array<String>::class.java,
                            String::class.java,
                        ).apply { isAccessible = true }
                }.getOrNull().also { cached = it }
    }
}

internal class ShizukuProcessCommandExecutor(
    private val processFactory: ShizukuProcessFactory = ReflectiveShizukuProcessFactory(),
) : PrivilegedCommandExecutor {
    override suspend fun execute(
        command: String,
        args: List<String>,
        limits: CommandLimits,
    ): CommandResult =
        withContext(Dispatchers.IO) {
            validateLimits(limits)
            val process = processFactory.start(command, args)
            try {
                withTimeout(limits.timeoutMs) {
                    coroutineScope {
                        val stdout = async(Dispatchers.IO) { process.inputStream.readBounded(limits.maxStdoutBytes) }
                        val stderr = async(Dispatchers.IO) { process.errorStream.readBounded(limits.maxStderrBytes) }
                        val exitCode = runInterruptible(Dispatchers.IO) { process.waitFor() }
                        val stdoutResult = stdout.await()
                        val stderrResult = stderr.await()
                        CommandResult(
                            exitCode = exitCode,
                            stdout = stdoutResult.bytes.toString(Charsets.UTF_8),
                            stderr = stderrResult.bytes.toString(Charsets.UTF_8),
                            stdoutTruncated = stdoutResult.truncated,
                            stderrTruncated = stderrResult.truncated,
                        )
                    }
                }
            } catch (_: TimeoutCancellationException) {
                throw PrivilegedAdminException.ExecutionFailed()
            } finally {
                runCatching { process.inputStream.close() }
                runCatching { process.errorStream.close() }
                runCatching { process.outputStream.close() }
                if (process.isAlive) {
                    runCatching { process.destroyForcibly() }
                } else {
                    runCatching { process.destroy() }
                }
            }
        }

    private fun validateLimits(limits: CommandLimits) {
        require(limits.timeoutMs in 1..MAX_TIMEOUT_MS)
        require(limits.maxStdoutBytes in 1..MAX_RETAINED_BYTES)
        require(limits.maxStderrBytes in 1..MAX_RETAINED_BYTES)
    }

    private companion object {
        const val MAX_TIMEOUT_MS = 30_000L
        const val MAX_RETAINED_BYTES = 1024 * 1024
    }
}

internal suspend fun InputStream.readBounded(maxRetainedBytes: Int): BoundedBytes =
    runInterruptible(Dispatchers.IO) {
        require(maxRetainedBytes > 0)
        val retained = ByteArrayOutputStream(minOf(maxRetainedBytes, BUFFER_SIZE))
        val buffer = ByteArray(BUFFER_SIZE)
        var truncated = false
        while (true) {
            val count = read(buffer)
            if (count < 0) break
            val remaining = maxRetainedBytes - retained.size()
            if (remaining > 0) {
                retained.write(buffer, 0, minOf(count, remaining))
            }
            if (count > remaining) truncated = true
        }
        BoundedBytes(retained.toByteArray(), truncated)
    }

private const val BUFFER_SIZE = 8 * 1024
