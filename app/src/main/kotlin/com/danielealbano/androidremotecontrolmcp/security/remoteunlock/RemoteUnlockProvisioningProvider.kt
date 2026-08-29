package com.danielealbano.androidremotecontrolmcp.security.remoteunlock

import android.content.ContentProvider
import android.content.ContentValues
import android.database.Cursor
import android.net.Uri
import android.os.Bundle
import com.mwodevelop.androidremotecontrol.shizukuadmin.RemoteUnlockAdminContract
import dagger.hilt.EntryPoint
import dagger.hilt.InstallIn
import dagger.hilt.android.EntryPointAccessors
import dagger.hilt.components.SingletonComponent

/** DUMP-gated ADB-only provisioning boundary. It accepts ciphertext, never plaintext PIN data. */
class RemoteUnlockProvisioningProvider : ContentProvider() {
    override fun onCreate(): Boolean = true

    override fun call(
        method: String,
        arg: String?,
        extras: Bundle?,
    ): Bundle {
        val store =
            EntryPointAccessors
                .fromApplication(
                    requireNotNull(context).applicationContext,
                    ProvisioningEntryPoint::class.java,
                ).store()
        return when (method) {
            METHOD_GET_PUBLIC_KEY -> {
                store.provisioningKey().let { key ->
                    Bundle().apply {
                        putInt("key_version", key.version)
                        putString("public_key", key.publicKeyBase64)
                    }
                }
            }

            METHOD_PROVISION -> {
                val values = requireNotNull(extras) { "Provisioning extras are required" }
                store.provision(
                    keyVersion = values.getString("key_version")?.toIntOrNull() ?: error("Missing key version"),
                    ciphertextBase64 = requireNotNull(values.getString("ciphertext")) { "Missing ciphertext" },
                )
                statusBundle(store.status())
            }

            METHOD_SET_POLICY -> {
                val values = requireNotNull(extras) { "Policy extras are required" }
                val enabled = values.getString("enabled")?.toBooleanStrictOrNull() ?: error("Missing enabled flag")
                store.setPolicy(enabled, values.getString("client_id"))
                statusBundle(store.status())
            }

            RemoteUnlockAdminContract.METHOD_ARM -> {
                store.arm()
                statusBundle(store.status())
            }

            RemoteUnlockAdminContract.METHOD_DISARM -> {
                store.disarm()
                statusBundle(store.status())
            }

            METHOD_CLEAR -> {
                store.clear()
                statusBundle(store.status())
            }

            RemoteUnlockAdminContract.METHOD_STATUS -> {
                statusBundle(store.status())
            }

            else -> {
                error("Unsupported remote-unlock provisioning method")
            }
        }
    }

    private fun statusBundle(status: RemoteUnlockStatus) =
        Bundle().apply {
            putBoolean(RemoteUnlockAdminContract.KEY_CONFIGURED, status.configured)
            putBoolean(RemoteUnlockAdminContract.KEY_ENABLED, status.enabled)
            putBoolean(RemoteUnlockAdminContract.KEY_ARMED, status.armed)
            putBoolean(RemoteUnlockAdminContract.KEY_REARM_REQUIRED, status.rearmRequired)
            putLong(RemoteUnlockAdminContract.KEY_REMAINING_MS, status.remainingArmMs)
            putString("authorized_client_id", status.authorizedClientId)
        }

    override fun query(
        uri: Uri,
        projection: Array<out String>?,
        selection: String?,
        selectionArgs: Array<out String>?,
        sortOrder: String?,
    ): Cursor? = null

    override fun getType(uri: Uri): String? = null

    override fun insert(
        uri: Uri,
        values: ContentValues?,
    ): Uri? = null

    override fun delete(
        uri: Uri,
        selection: String?,
        selectionArgs: Array<out String>?,
    ): Int = 0

    override fun update(
        uri: Uri,
        values: ContentValues?,
        selection: String?,
        selectionArgs: Array<out String>?,
    ): Int = 0

    @EntryPoint
    @InstallIn(SingletonComponent::class)
    interface ProvisioningEntryPoint {
        fun store(): RemoteUnlockCredentialStore
    }

    companion object {
        const val METHOD_GET_PUBLIC_KEY = "get_public_key"
        const val METHOD_PROVISION = "provision"
        const val METHOD_SET_POLICY = "set_policy"
        const val METHOD_CLEAR = "clear"
    }
}
