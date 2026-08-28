package com.mwodevelop.androidremotecontrol.shizukuadmin

import android.content.ComponentName
import android.content.Context
import android.content.ServiceConnection
import android.os.IBinder
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout
import rikka.shizuku.Shizuku
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException

internal fun interface PrivilegedDigitInputClient {
    suspend fun injectDigits(digits: ByteArray): Boolean
}

internal class ShizukuUserServiceDigitInputClient(
    context: Context,
) : PrivilegedDigitInputClient {
    private val applicationContext = context.applicationContext
    private val userServiceArgs =
        Shizuku
            .UserServiceArgs(
                ComponentName(applicationContext.packageName, RemoteInputUserService::class.java.name),
            ).daemon(false)
            .tag(USER_SERVICE_TAG)
            .version(USER_SERVICE_VERSION)
            .processNameSuffix(USER_SERVICE_PROCESS_SUFFIX)

    override suspend fun injectDigits(digits: ByteArray): Boolean =
        withTimeout(BIND_AND_CALL_TIMEOUT_MS) {
            require(Shizuku.getUid() == SHELL_UID) { "Remote input requires shell-mode Shizuku" }
            val bound = bind()
            try {
                withContext(Dispatchers.IO) {
                    val binderCopy = digits.copyOf()
                    try {
                        bound.service.injectDigits(binderCopy)
                    } finally {
                        binderCopy.fill(0)
                    }
                }
            } finally {
                runCatching { Shizuku.unbindUserService(userServiceArgs, bound.connection, true) }
            }
        }

    private suspend fun bind(): BoundUserService =
        suspendCancellableCoroutine { continuation ->
            val completed = AtomicBoolean(false)
            lateinit var connection: ServiceConnection
            connection =
                object : ServiceConnection {
                    override fun onServiceConnected(
                        name: ComponentName?,
                        service: IBinder?,
                    ) {
                        if (!completed.compareAndSet(false, true)) return
                        val remote = service?.let(IRemoteInputUserService.Stub::asInterface)
                        if (remote == null) {
                            continuation.resumeWithException(
                                IllegalStateException("Remote input service returned no binder"),
                            )
                        } else {
                            continuation.resume(BoundUserService(remote, this))
                        }
                    }

                    override fun onServiceDisconnected(name: ComponentName?) {
                        if (completed.compareAndSet(false, true)) {
                            continuation.resumeWithException(IllegalStateException("Remote input service disconnected"))
                        }
                    }
                }
            continuation.invokeOnCancellation {
                if (completed.compareAndSet(false, true)) {
                    runCatching { Shizuku.unbindUserService(userServiceArgs, connection, true) }
                }
            }
            runCatching { Shizuku.bindUserService(userServiceArgs, connection) }
                .onFailure { error ->
                    if (completed.compareAndSet(false, true)) continuation.resumeWithException(error)
                }
        }

    private data class BoundUserService(
        val service: IRemoteInputUserService,
        val connection: ServiceConnection,
    )

    private companion object {
        const val SHELL_UID = 2000
        const val USER_SERVICE_VERSION = 1
        const val USER_SERVICE_TAG = "arcp_remote_unlock_input_v1"
        const val USER_SERVICE_PROCESS_SUFFIX = "remote_unlock_input"
        const val BIND_AND_CALL_TIMEOUT_MS = 10_000L
    }
}
