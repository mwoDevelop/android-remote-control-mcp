package com.mwodevelop.androidremotecontrol.shizukuadmin

import android.app.Instrumentation
import android.content.Context
import android.os.SystemClock
import android.view.KeyEvent
import kotlin.system.exitProcess

/** Sends a fixed wake, decimal-digit and Enter sequence without starting a secret-bearing process. */
internal fun interface DigitSequenceInjector {
    fun inject(digits: ByteArray): Boolean
}

internal fun interface KeyEventSender {
    fun sendKeyDownUp(keyCode: Int)
}

internal class InstrumentationDigitSequenceInjector(
    private val keyEventSender: KeyEventSender =
        KeyEventSender { keyCode -> Instrumentation().sendKeyDownUpSync(keyCode) },
    private val pauseAfterWake: () -> Unit = { SystemClock.sleep(WAKE_SETTLE_MS) },
) : DigitSequenceInjector {
    override fun inject(digits: ByteArray): Boolean {
        validateDigits(digits)
        keyEventSender.sendKeyDownUp(KeyEvent.KEYCODE_WAKEUP)
        pauseAfterWake()
        digits.forEach { digit ->
            keyEventSender.sendKeyDownUp(KeyEvent.KEYCODE_0 + digit.toInt())
        }
        keyEventSender.sendKeyDownUp(KeyEvent.KEYCODE_ENTER)
        return true
    }

    private companion object {
        const val WAKE_SETTLE_MS = 350L
    }
}

/**
 * Non-daemon Shizuku UserService. It runs with the Shizuku shell UID and exposes no generic input primitive.
 *
 * The service intentionally retains no Context, credential or digit sequence between calls.
 */
class RemoteInputUserService internal constructor(
    private val injector: DigitSequenceInjector,
    private val terminateProcess: (Int) -> Unit,
) : IRemoteInputUserService.Stub() {
    constructor() : this(InstrumentationDigitSequenceInjector(), ::exitProcess)

    @Suppress("UNUSED_PARAMETER")
    constructor(context: Context) : this()

    override fun injectDigits(digits: ByteArray): Boolean =
        try {
            validateDigits(digits)
            injector.inject(digits)
        } finally {
            digits.fill(0)
        }

    override fun destroy() {
        terminateProcess(0)
    }
}

internal fun validateDigits(digits: ByteArray) {
    require(digits.size in MIN_PIN_DIGITS..MAX_PIN_DIGITS) { "Digit sequence length is outside the accepted range" }
    require(digits.all { it in MIN_DECIMAL_DIGIT..MAX_DECIMAL_DIGIT }) {
        "Digit sequence contains a non-decimal value"
    }
}

internal const val MIN_PIN_DIGITS = 4
internal const val MAX_PIN_DIGITS = 16
private const val MIN_DECIMAL_DIGIT = 0
private const val MAX_DECIMAL_DIGIT = 9
