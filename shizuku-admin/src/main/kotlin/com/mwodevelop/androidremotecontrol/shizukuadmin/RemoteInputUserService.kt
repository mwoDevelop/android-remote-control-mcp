package com.mwodevelop.androidremotecontrol.shizukuadmin

import android.app.Instrumentation
import android.content.Context
import android.content.res.Resources
import android.os.SystemClock
import android.view.InputDevice
import android.view.InputEvent
import android.view.KeyEvent
import android.view.MotionEvent
import java.lang.reflect.Method
import kotlin.system.exitProcess

/** Sends a fixed wake, PIN-surface gesture, decimal-digit and Enter sequence without starting a child process. */
internal fun interface DigitSequenceInjector {
    fun inject(digits: ByteArray): Boolean
}

internal fun interface KeyEventSender {
    fun sendKeyDownUp(keyCode: Int)
}

/** Presents the secure credential surface using one fixed upward gesture; no caller controls the gesture. */
internal fun interface PinSurfacePresenter {
    fun present()
}

/**
 * Injects fixed motion events through Android's input service from the shell-UID UserService.
 *
 * The method is hidden from ordinary applications, but Shizuku UserService deliberately runs outside the app process
 * without its hidden-API restrictions. Keeping this adapter inside the narrow service avoids a generic input or shell
 * interface and is required because Instrumentation.sendPointerSync targets only the instrumented application's window.
 */
internal class ShellInputManagerMotionEventSender : (MotionEvent) -> Unit {
    private val inputManagerClass: Class<*> by lazy { Class.forName(INPUT_MANAGER_CLASS_NAME) }
    private val inputManager: Any by lazy {
        inputManagerClass.getDeclaredMethod(GET_INSTANCE_METHOD).invoke(null)
    }
    private val injectInputEvent: Method by lazy {
        inputManagerClass.getDeclaredMethod(
            INJECT_INPUT_EVENT_METHOD,
            InputEvent::class.java,
            Int::class.javaPrimitiveType,
        )
    }

    override fun invoke(event: MotionEvent) {
        val accepted = injectInputEvent.invoke(inputManager, event, INJECT_INPUT_EVENT_MODE_WAIT_FOR_FINISH) as? Boolean
        check(accepted == true) { "Android input service rejected the fixed PIN-surface gesture" }
    }

    private companion object {
        const val INPUT_MANAGER_CLASS_NAME = "android.hardware.input.InputManager"
        const val GET_INSTANCE_METHOD = "getInstance"
        const val INJECT_INPUT_EVENT_METHOD = "injectInputEvent"
        const val INJECT_INPUT_EVENT_MODE_WAIT_FOR_FINISH = 2
    }
}

internal class InstrumentationPinSurfacePresenter(
    private val pointerEventSender: (MotionEvent) -> Unit =
        ShellInputManagerMotionEventSender(),
    private val displaySize: () -> Pair<Int, Int> = {
        Resources.getSystem().displayMetrics.let { it.widthPixels to it.heightPixels }
    },
    private val sleep: (Long) -> Unit = SystemClock::sleep,
) : PinSurfacePresenter {
    override fun present() {
        val (width, height) = displaySize()
        require(width > 0 && height > 0) { "Display metrics are unavailable" }
        val x = width / 2f
        val startY = height * SWIPE_START_FRACTION
        val endY = height * SWIPE_END_FRACTION
        val downTime = SystemClock.uptimeMillis()
        send(MotionEvent.ACTION_DOWN, x, startY, downTime, downTime)
        repeat(SWIPE_MOVE_STEPS) { index ->
            sleep(SWIPE_STEP_MS)
            val progress = (index + 1f) / SWIPE_MOVE_STEPS
            val y = startY + ((endY - startY) * progress)
            send(MotionEvent.ACTION_MOVE, x, y, downTime, SystemClock.uptimeMillis())
        }
        send(MotionEvent.ACTION_UP, x, endY, downTime, SystemClock.uptimeMillis())
    }

    private fun send(
        action: Int,
        x: Float,
        y: Float,
        downTime: Long,
        eventTime: Long,
    ) {
        val event = MotionEvent.obtain(downTime, eventTime, action, x, y, 0)
        try {
            event.source = InputDevice.SOURCE_TOUCHSCREEN
            pointerEventSender(event)
        } finally {
            event.recycle()
        }
    }

    private companion object {
        const val SWIPE_START_FRACTION = 0.82f
        const val SWIPE_END_FRACTION = 0.28f
        const val SWIPE_MOVE_STEPS = 8
        const val SWIPE_STEP_MS = 25L
    }
}

internal class InstrumentationDigitSequenceInjector(
    private val keyEventSender: KeyEventSender =
        KeyEventSender { keyCode -> Instrumentation().sendKeyDownUpSync(keyCode) },
    private val pinSurfacePresenter: PinSurfacePresenter = InstrumentationPinSurfacePresenter(),
    private val pauseAfterWake: () -> Unit = { SystemClock.sleep(WAKE_SETTLE_MS) },
    private val pauseAfterPinSurface: () -> Unit = { SystemClock.sleep(PIN_SURFACE_SETTLE_MS) },
) : DigitSequenceInjector {
    override fun inject(digits: ByteArray): Boolean {
        validateDigits(digits)
        keyEventSender.sendKeyDownUp(KeyEvent.KEYCODE_WAKEUP)
        pauseAfterWake()
        pinSurfacePresenter.present()
        pauseAfterPinSurface()
        digits.forEach { digit ->
            keyEventSender.sendKeyDownUp(KeyEvent.KEYCODE_0 + digit.toInt())
        }
        keyEventSender.sendKeyDownUp(KeyEvent.KEYCODE_ENTER)
        return true
    }

    private companion object {
        const val WAKE_SETTLE_MS = 700L
        const val PIN_SURFACE_SETTLE_MS = 700L
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
