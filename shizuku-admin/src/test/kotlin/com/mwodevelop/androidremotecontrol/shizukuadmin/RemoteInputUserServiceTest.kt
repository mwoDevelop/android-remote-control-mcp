package com.mwodevelop.androidremotecontrol.shizukuadmin

import android.view.KeyEvent
import org.junit.jupiter.api.Assertions.assertArrayEquals
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertThrows
import org.junit.jupiter.api.Test

class RemoteInputUserServiceTest {
    @Test
    fun `service accepts only bounded decimal digits and zeros binder buffer`() {
        var captured = byteArrayOf()
        val service =
            RemoteInputUserService(
                DigitSequenceInjector { digits ->
                    captured = digits.copyOf()
                    true
                },
                {},
            )
        val supplied = byteArrayOf(1, 2, 3, 4)

        assertEquals(true, service.injectDigits(supplied))

        assertArrayEquals(byteArrayOf(1, 2, 3, 4), captured)
        assertArrayEquals(byteArrayOf(0, 0, 0, 0), supplied)
    }

    @Test
    fun `service zeros binder buffer when injection fails`() {
        val service = RemoteInputUserService(DigitSequenceInjector { error("injection failed") }, {})
        val supplied = byteArrayOf(1, 2, 3, 4)

        assertThrows(IllegalStateException::class.java) { service.injectDigits(supplied) }

        assertArrayEquals(byteArrayOf(0, 0, 0, 0), supplied)
    }

    @Test
    fun `service rejects malformed sequences and still zeros them`() {
        val supplied = byteArrayOf(1, 2, 3, 42)
        val service = RemoteInputUserService(DigitSequenceInjector { true }, {})

        assertThrows(IllegalArgumentException::class.java) { service.injectDigits(supplied) }

        assertArrayEquals(byteArrayOf(0, 0, 0, 0), supplied)
    }

    @Test
    fun `instrumentation injector emits only fixed wake digits and enter`() {
        val events = mutableListOf<String>()
        val injector =
            InstrumentationDigitSequenceInjector(
                keyEventSender = KeyEventSender { events.add("key:$it") },
                pinSurfacePresenter = PinSurfacePresenter { events.add("pin-surface") },
                pauseAfterWake = {},
                pauseAfterPinSurface = {},
                pauseAfterDigit = { events.add("digit-pause") },
                pauseBeforeSubmit = { events.add("submit-pause") },
            )

        assertEquals(true, injector.inject(byteArrayOf(9, 0, 4, 1)))

        assertEquals(
            listOf(
                "key:${KeyEvent.KEYCODE_WAKEUP}",
                "pin-surface",
                "key:${KeyEvent.KEYCODE_9}",
                "digit-pause",
                "key:${KeyEvent.KEYCODE_0}",
                "digit-pause",
                "key:${KeyEvent.KEYCODE_4}",
                "digit-pause",
                "key:${KeyEvent.KEYCODE_1}",
                "digit-pause",
                "submit-pause",
                "key:${KeyEvent.KEYCODE_ENTER}",
            ),
            events,
        )
    }

    @Test
    fun `destroy delegates to injected process terminator`() {
        var exitCode: Int? = null
        val service = RemoteInputUserService(DigitSequenceInjector { true }) { exitCode = it }

        service.destroy()

        assertEquals(0, exitCode)
    }
}
