package com.danielealbano.androidremotecontrolmcp.debug

import android.app.KeyguardManager
import android.os.Bundle
import android.view.WindowManager
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.Button
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import androidx.lifecycle.lifecycleScope
import com.danielealbano.androidremotecontrolmcp.ui.theme.AndroidRemoteControlMcpTheme
import com.mwodevelop.androidremotecontrol.shizukuadmin.PrivilegedAdminBackend
import com.mwodevelop.androidremotecontrol.shizukuadmin.PrivilegedAdminBackendFactory
import com.mwodevelop.androidremotecontrol.shizukuadmin.PrivilegedAdminReadiness
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

/** Debug-only local harness for the blocking secure-keyguard feasibility gate. */
class RemoteUnlockFeasibilityActivity : ComponentActivity() {
    private val digits = ByteArray(MAX_DIGITS)
    private var digitCount by mutableIntStateOf(0)
    private var status by mutableStateOf("Wpisz PIN lokalnie. Wartość nie jest zapisywana ani wysyłana przez MCP.")
    private var running by mutableStateOf(false)
    private lateinit var backend: PrivilegedAdminBackend

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
        backend = PrivilegedAdminBackendFactory.create(applicationContext)
        setContent {
            AndroidRemoteControlMcpTheme {
                FeasibilityScreen()
            }
        }
    }

    override fun onDestroy() {
        digits.fill(0)
        digitCount = 0
        super.onDestroy()
    }

    @Composable
    private fun FeasibilityScreen() {
        Column(
            modifier =
                Modifier
                    .fillMaxSize()
                    .padding(24.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.Center,
        ) {
            Text("ARCP — lokalny test odblokowania", style = MaterialTheme.typography.headlineSmall)
            Spacer(Modifier.height(16.dp))
            Text("Stan Shizuku: ${backend.readiness()}")
            Spacer(Modifier.height(12.dp))
            Text("•".repeat(digitCount), style = MaterialTheme.typography.headlineMedium)
            Spacer(Modifier.height(12.dp))
            DigitPad(enabled = !running, onDigit = ::appendDigit)
            Spacer(Modifier.height(8.dp))
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                OutlinedButton(onClick = ::removeLastDigit, enabled = !running && digitCount > 0) {
                    Text("Usuń cyfrę")
                }
                OutlinedButton(onClick = ::requestShizukuPermission, enabled = !running) {
                    Text("Poproś o Shizuku")
                }
            }
            Spacer(Modifier.height(12.dp))
            Button(
                onClick = ::startFeasibilityAttempt,
                enabled = !running && digitCount in MIN_DIGITS..MAX_DIGITS,
            ) {
                Text("Uruchom za 10 sekund")
            }
            Spacer(Modifier.height(16.dp))
            Text(status)
        }
    }

    @Composable
    private fun DigitPad(
        enabled: Boolean,
        onDigit: (Int) -> Unit,
    ) {
        listOf(listOf(1, 2, 3), listOf(4, 5, 6), listOf(7, 8, 9), listOf(0)).forEach { row ->
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.spacedBy(8.dp, Alignment.CenterHorizontally),
            ) {
                row.forEach { digit ->
                    OutlinedButton(onClick = { onDigit(digit) }, enabled = enabled) {
                        Text(digit.toString())
                    }
                }
            }
        }
    }

    private fun appendDigit(digit: Int) {
        if (running || digit !in 0..9 || digitCount >= MAX_DIGITS) return
        digits[digitCount] = digit.toByte()
        digitCount += 1
    }

    private fun removeLastDigit() {
        if (running || digitCount == 0) return
        digitCount -= 1
        digits[digitCount] = 0
    }

    private fun requestShizukuPermission() {
        status =
            runCatching {
                backend.requestPermission()
                "Jeśli pojawił się dialog Shizuku, zatwierdź go i wróć do testu."
            }.getOrElse { "Shizuku nie jest gotowe; uruchom usługę i spróbuj ponownie." }
    }

    private fun startFeasibilityAttempt() {
        if (backend.readiness() != PrivilegedAdminReadiness.Ready) {
            status = "Shizuku nie jest gotowe. Uruchom je i nadaj aplikacji debug uprawnienie."
            return
        }
        val attempt = digits.copyOfRange(0, digitCount)
        digits.fill(0)
        digitCount = 0
        running = true
        status = "Test uzbrojony. Zablokuj ekran przyciskiem zasilania; próba nastąpi za 10 sekund."
        lifecycleScope.launch {
            try {
                delay(ATTEMPT_DELAY_MS)
                val injected = backend.injectUnlockDigitsForLocalFeasibilityTest(attempt)
                delay(KEYGUARD_SETTLE_MS)
                val keyguardManager = getSystemService(KeyguardManager::class.java)
                status =
                    if (injected && !keyguardManager.isDeviceLocked) {
                        "PASS: urządzenie zostało odblokowane przez typowany UserService Shizuku."
                    } else {
                        "FAIL: urządzenie pozostało zablokowane; nie kontynuuj do wersji produkcyjnej."
                    }
            } catch (_: Exception) {
                status = "FAIL: UserService Shizuku nie wykonał bezpiecznej próby."
            } finally {
                attempt.fill(0)
                running = false
            }
        }
    }

    private companion object {
        const val MIN_DIGITS = 4
        const val MAX_DIGITS = 16
        const val ATTEMPT_DELAY_MS = 10_000L
        const val KEYGUARD_SETTLE_MS = 1_500L
    }
}
