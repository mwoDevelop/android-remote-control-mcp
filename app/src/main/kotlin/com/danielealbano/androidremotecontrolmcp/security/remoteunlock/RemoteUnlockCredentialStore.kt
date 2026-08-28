package com.danielealbano.androidremotecontrolmcp.security.remoteunlock

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.AtomicFile
import android.util.Base64
import dagger.hilt.android.qualifiers.ApplicationContext
import org.json.JSONObject
import java.io.File
import java.security.KeyPairGenerator
import java.security.KeyStore
import java.security.spec.MGF1ParameterSpec
import javax.crypto.Cipher
import javax.crypto.spec.OAEPParameterSpec
import javax.crypto.spec.PSource
import javax.inject.Inject
import javax.inject.Singleton

data class RemoteUnlockStatus(
    val configured: Boolean,
    val enabled: Boolean,
    val authorizedClientId: String?,
    val armedUntilMs: Long,
    val rearmRequired: Boolean,
) {
    fun isArmed(nowMs: Long): Boolean = configured && enabled && !rearmRequired && armedUntilMs > nowMs
}

data class RemoteUnlockProvisioningKey(
    val version: Int,
    val publicKeyBase64: String,
)

interface RemoteUnlockCredentialStore {
    fun provisioningKey(): RemoteUnlockProvisioningKey

    fun status(): RemoteUnlockStatus

    fun provision(
        keyVersion: Int,
        ciphertextBase64: String,
    )

    fun setPolicy(
        enabled: Boolean,
        authorizedClientId: String?,
    )

    fun arm(nowMs: Long = System.currentTimeMillis())

    fun consumeArm(nowMs: Long = System.currentTimeMillis()): Boolean

    fun recordFailure()

    fun clear()

    suspend fun <T> withDecryptedDigits(block: suspend (ByteArray) -> T): T
}

@Singleton
@Suppress("TooManyFunctions")
class AndroidRemoteUnlockCredentialStore
    @Inject
    constructor(
        @ApplicationContext context: Context,
    ) : RemoteUnlockCredentialStore {
        private val stateFile = AtomicFile(File(context.filesDir, STATE_FILE_NAME))
        private val lock = Any()

        override fun provisioningKey(): RemoteUnlockProvisioningKey =
            synchronized(lock) {
                val keyPair = getOrCreateKeyPair()
                RemoteUnlockProvisioningKey(
                    version = KEY_VERSION,
                    publicKeyBase64 = Base64.encodeToString(keyPair.public.encoded, Base64.NO_WRAP),
                )
            }

        override fun status(): RemoteUnlockStatus = synchronized(lock) { readState().toStatus() }

        override fun provision(
            keyVersion: Int,
            ciphertextBase64: String,
        ) = synchronized(lock) {
            require(keyVersion == KEY_VERSION) { "Unsupported remote-unlock key version" }
            val ciphertext = Base64.decode(ciphertextBase64, Base64.NO_WRAP)
            require(ciphertext.size in MIN_CIPHERTEXT_BYTES..MAX_CIPHERTEXT_BYTES) {
                "Invalid remote-unlock ciphertext size"
            }
            validateCiphertext(ciphertext)
            writeState(
                StoredState(
                    ciphertextBase64 = Base64.encodeToString(ciphertext, Base64.NO_WRAP),
                    enabled = false,
                    authorizedClientId = null,
                    armedUntilMs = 0L,
                    rearmRequired = false,
                ),
            )
            ciphertext.fill(0)
        }

        override fun setPolicy(
            enabled: Boolean,
            authorizedClientId: String?,
        ) = synchronized(lock) {
            val current = readState()
            check(current.ciphertextBase64.isNotEmpty()) { "Remote unlock is not configured" }
            val normalizedClient = authorizedClientId?.takeIf { it.matches(OAUTH_CLIENT_ID) }
            if (enabled) requireNotNull(normalizedClient) { "A valid OAuth client ID is required" }
            writeState(
                current.copy(
                    enabled = enabled,
                    authorizedClientId = normalizedClient,
                    armedUntilMs = 0L,
                ),
            )
        }

        override fun arm(nowMs: Long) =
            synchronized(lock) {
                val current = readState()
                check(current.ciphertextBase64.isNotEmpty() && current.enabled && current.authorizedClientId != null) {
                    "Remote unlock is not configured and enabled"
                }
                writeState(current.copy(armedUntilMs = nowMs + ARM_LIFETIME_MS, rearmRequired = false))
            }

        override fun consumeArm(nowMs: Long): Boolean =
            synchronized(lock) {
                val current = readState()
                if (!current.toStatus().isArmed(nowMs)) return@synchronized false
                writeState(current.copy(armedUntilMs = 0L))
                true
            }

        override fun recordFailure() =
            synchronized(lock) {
                val current = readState()
                if (current.ciphertextBase64.isNotEmpty()) {
                    writeState(current.copy(armedUntilMs = 0L, rearmRequired = true))
                }
            }

        override fun clear() = synchronized(lock) { stateFile.delete() }

        override suspend fun <T> withDecryptedDigits(block: suspend (ByteArray) -> T): T {
            val plaintext =
                synchronized(lock) {
                    val state = readState()
                    check(state.ciphertextBase64.isNotEmpty()) { "Remote unlock is not configured" }
                    val ciphertext = Base64.decode(state.ciphertextBase64, Base64.NO_WRAP)
                    decrypt(ciphertext).also { ciphertext.fill(0) }
                }
            try {
                require(
                    plaintext.size in MIN_PIN_DIGITS..MAX_PIN_DIGITS &&
                        plaintext.all { it in ASCII_ZERO..ASCII_NINE },
                ) {
                    "Stored remote-unlock credential is invalid"
                }
                plaintext.indices.forEach { plaintext[it] = (plaintext[it] - ASCII_ZERO).toByte() }
                return block(plaintext)
            } finally {
                plaintext.fill(0)
            }
        }

        private fun validateCiphertext(ciphertext: ByteArray) {
            val plaintext = decrypt(ciphertext)
            try {
                require(
                    plaintext.size in MIN_PIN_DIGITS..MAX_PIN_DIGITS &&
                        plaintext.all { it in ASCII_ZERO..ASCII_NINE },
                ) {
                    "Provisioned remote-unlock credential must contain only bounded decimal digits"
                }
            } finally {
                plaintext.fill(0)
            }
        }

        private fun decrypt(ciphertext: ByteArray): ByteArray {
            val privateKey = getOrCreateKeyPair().private
            return Cipher.getInstance(CIPHER_TRANSFORMATION).run {
                init(Cipher.DECRYPT_MODE, privateKey, OAEP_PARAMETERS)
                doFinal(ciphertext)
            }
        }

        private fun getOrCreateKeyPair(): java.security.KeyPair {
            val keyStore = KeyStore.getInstance(ANDROID_KEYSTORE).apply { load(null) }
            val existing = keyStore.getEntry(KEY_ALIAS, null) as? KeyStore.PrivateKeyEntry
            if (existing != null) return java.security.KeyPair(existing.certificate.publicKey, existing.privateKey)
            return KeyPairGenerator.getInstance(KeyProperties.KEY_ALGORITHM_RSA, ANDROID_KEYSTORE).run {
                initialize(
                    KeyGenParameterSpec
                        .Builder(KEY_ALIAS, KeyProperties.PURPOSE_DECRYPT)
                        .setKeySize(RSA_KEY_SIZE)
                        .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_RSA_OAEP)
                        .setDigests(KeyProperties.DIGEST_SHA256, KeyProperties.DIGEST_SHA1)
                        .setUserAuthenticationRequired(false)
                        .build(),
                )
                generateKeyPair()
            }
        }

        private fun readState(): StoredState {
            if (!stateFile.baseFile.exists()) return StoredState()
            return runCatching {
                stateFile.openRead().bufferedReader().use { reader ->
                    StoredState.fromJson(JSONObject(reader.readText()))
                }
            }.getOrDefault(StoredState(rearmRequired = true))
        }

        private fun writeState(state: StoredState) {
            val stream = stateFile.startWrite()
            try {
                stream.write(state.toJson().toString().toByteArray(Charsets.UTF_8))
                stream.flush()
                stateFile.finishWrite(stream)
            } catch (
                @Suppress("TooGenericExceptionCaught") error: Exception,
            ) {
                stateFile.failWrite(stream)
                throw error
            }
        }

        private data class StoredState(
            val ciphertextBase64: String = "",
            val enabled: Boolean = false,
            val authorizedClientId: String? = null,
            val armedUntilMs: Long = 0L,
            val rearmRequired: Boolean = false,
        ) {
            fun toStatus() =
                RemoteUnlockStatus(
                    configured = ciphertextBase64.isNotEmpty(),
                    enabled = enabled,
                    authorizedClientId = authorizedClientId,
                    armedUntilMs = armedUntilMs,
                    rearmRequired = rearmRequired,
                )

            fun toJson() =
                JSONObject()
                    .put("version", STATE_VERSION)
                    .put("ciphertext", ciphertextBase64)
                    .put("enabled", enabled)
                    .put("authorized_client_id", authorizedClientId)
                    .put("armed_until_ms", armedUntilMs)
                    .put("rearm_required", rearmRequired)

            companion object {
                fun fromJson(json: JSONObject) =
                    StoredState(
                        ciphertextBase64 = json.optString("ciphertext"),
                        enabled = json.optBoolean("enabled"),
                        authorizedClientId = json.optString("authorized_client_id").takeIf { it.isNotEmpty() },
                        armedUntilMs = json.optLong("armed_until_ms"),
                        rearmRequired = json.optBoolean("rearm_required"),
                    )
            }
        }

        private companion object {
            const val ANDROID_KEYSTORE = "AndroidKeyStore"
            const val KEY_ALIAS = "arcp_remote_unlock_rsa_v1"
            const val KEY_VERSION = 1
            const val STATE_VERSION = 1
            const val STATE_FILE_NAME = "remote_unlock_credential_v1.json"
            const val CIPHER_TRANSFORMATION = "RSA/ECB/OAEPWithSHA-256AndMGF1Padding"
            const val RSA_KEY_SIZE = 2048
            const val MIN_CIPHERTEXT_BYTES = 128
            const val MAX_CIPHERTEXT_BYTES = 512
            const val MIN_PIN_DIGITS = 4
            const val MAX_PIN_DIGITS = 16
            const val ASCII_ZERO = 48.toByte()
            const val ASCII_NINE = 57.toByte()
            const val ARM_LIFETIME_MS = 15 * 60 * 1000L
            val OAUTH_CLIENT_ID = Regex("^arc-[0-9a-fA-F-]{36}$")
            val OAEP_PARAMETERS =
                OAEPParameterSpec(
                    "SHA-256",
                    "MGF1",
                    MGF1ParameterSpec.SHA1,
                    PSource.PSpecified.DEFAULT,
                )
        }
    }
