package com.mwodevelop.androidremotecontrol.shizukuadmin

import android.app.Activity
import android.hardware.biometrics.BiometricManager
import android.hardware.biometrics.BiometricPrompt
import android.os.CancellationSignal

internal class PlatformLocalAdministratorAuthenticator(
    private val activity: Activity,
) : LocalAdministratorAuthenticator {
    private var cancellationSignal: CancellationSignal? = null

    override fun authenticate(callback: (LocalAuthenticationResult) -> Unit) {
        cancel()
        val allowedAuthenticators =
            BiometricManager.Authenticators.BIOMETRIC_STRONG or
                BiometricManager.Authenticators.DEVICE_CREDENTIAL
        val biometricManager = activity.getSystemService(BiometricManager::class.java)
        if (biometricManager?.canAuthenticate(allowedAuthenticators) != BiometricManager.BIOMETRIC_SUCCESS) {
            callback(LocalAuthenticationResult.ERROR)
            return
        }
        val signal = CancellationSignal()
        cancellationSignal = signal
        runCatching {
            BiometricPrompt
                .Builder(activity)
                .setTitle(activity.getString(R.string.remote_unlock_admin_auth_title))
                .setSubtitle(activity.getString(R.string.remote_unlock_admin_auth_subtitle))
                .setAllowedAuthenticators(allowedAuthenticators)
                .build()
                .authenticate(
                    signal,
                    activity.mainExecutor,
                    object : BiometricPrompt.AuthenticationCallback() {
                        override fun onAuthenticationSucceeded(result: BiometricPrompt.AuthenticationResult?) {
                            cancellationSignal = null
                            callback(LocalAuthenticationResult.SUCCESS)
                        }

                        override fun onAuthenticationError(
                            errorCode: Int,
                            errString: CharSequence?,
                        ) {
                            cancellationSignal = null
                            val cancelled =
                                errorCode == BiometricPrompt.BIOMETRIC_ERROR_CANCELED ||
                                    errorCode == BiometricPrompt.BIOMETRIC_ERROR_USER_CANCELED
                            callback(
                                if (cancelled) {
                                    LocalAuthenticationResult.CANCELLED
                                } else {
                                    LocalAuthenticationResult.ERROR
                                },
                            )
                        }
                    },
                )
        }.onFailure {
            cancellationSignal = null
            callback(LocalAuthenticationResult.ERROR)
        }
    }

    override fun cancel() {
        cancellationSignal?.cancel()
        cancellationSignal = null
    }
}
