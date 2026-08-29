package com.mwodevelop.androidremotecontrol.shizukuadmin

import android.content.Context
import android.view.Gravity
import android.view.ViewGroup
import android.widget.Button
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView

internal class RemoteUnlockAdminView(
    context: Context,
) : ScrollView(context) {
    private val statusText: TextView
    private val shizukuText: TextView
    private val messageText: TextView
    private val armButton: Button
    private val disarmButton: Button
    private val refreshButton: Button

    init {
        val content =
            LinearLayout(context).apply {
                orientation = LinearLayout.VERTICAL
                gravity = Gravity.CENTER_HORIZONTAL
                setPadding(dp(CONTENT_HORIZONTAL_DP), dp(CONTENT_TOP_DP), dp(CONTENT_HORIZONTAL_DP), dp(CONTENT_TOP_DP))
            }
        content.addView(textView(R.string.remote_unlock_admin_title, TITLE_SP))
        content.addView(
            textView(R.string.remote_unlock_admin_description, DESCRIPTION_SP, DESCRIPTION_MARGIN_DP),
        )
        statusText = textView(R.string.remote_unlock_admin_loading, STATUS_SP, STATUS_MARGIN_DP)
        shizukuText = textView(R.string.remote_unlock_admin_loading, DESCRIPTION_SP, DESCRIPTION_MARGIN_DP)
        messageText = textView(null, MESSAGE_SP, MESSAGE_MARGIN_DP)
        armButton = button(R.string.remote_unlock_admin_arm)
        disarmButton = button(R.string.remote_unlock_admin_disarm)
        refreshButton = button(R.string.remote_unlock_admin_refresh)
        content.addView(statusText)
        content.addView(shizukuText)
        content.addView(messageText)
        content.addView(armButton, buttonLayoutParams(PRIMARY_BUTTON_MARGIN_DP))
        content.addView(disarmButton, buttonLayoutParams(BUTTON_MARGIN_DP))
        content.addView(refreshButton, buttonLayoutParams(BUTTON_MARGIN_DP))
        addView(content)
    }

    fun setActionListeners(
        onArm: () -> Unit,
        onDisarm: () -> Unit,
        onRefresh: () -> Unit,
    ) {
        armButton.setOnClickListener { onArm() }
        disarmButton.setOnClickListener { onDisarm() }
        refreshButton.setOnClickListener { onRefresh() }
    }

    fun render(
        state: RemoteUnlockAdminViewState,
        busy: Boolean,
    ) {
        statusText.text =
            when (state.state) {
                RemoteUnlockAdminState.NOT_CONFIGURED -> {
                    context.getString(R.string.remote_unlock_admin_not_configured)
                }

                RemoteUnlockAdminState.DISABLED -> {
                    context.getString(R.string.remote_unlock_admin_disabled)
                }

                RemoteUnlockAdminState.REARM_REQUIRED -> {
                    context.getString(R.string.remote_unlock_admin_rearm_required)
                }

                RemoteUnlockAdminState.ARMED -> {
                    context.getString(R.string.remote_unlock_admin_armed, state.remainingSeconds)
                }

                RemoteUnlockAdminState.READY -> {
                    context.getString(R.string.remote_unlock_admin_ready)
                }
            }
        shizukuText.setText(
            if (state.shizukuReady) {
                R.string.remote_unlock_admin_shizuku_ready
            } else {
                R.string.remote_unlock_admin_shizuku_unavailable
            },
        )
        armButton.isEnabled = state.canArm && !busy
        disarmButton.isEnabled = state.canDisarm && !busy
        refreshButton.isEnabled = !busy
    }

    fun renderUnavailable() {
        statusText.setText(R.string.remote_unlock_admin_status_error)
        shizukuText.text = ""
        armButton.isEnabled = false
        disarmButton.isEnabled = false
    }

    fun showMessage(message: RemoteUnlockAdminMessage) {
        messageText.setText(
            when (message) {
                RemoteUnlockAdminMessage.ARMED -> {
                    R.string.remote_unlock_admin_message_armed
                }

                RemoteUnlockAdminMessage.AUTHENTICATION_CANCELLED -> {
                    R.string.remote_unlock_admin_message_auth_cancelled
                }

                RemoteUnlockAdminMessage.AUTHENTICATION_ERROR -> {
                    R.string.remote_unlock_admin_message_auth_error
                }

                RemoteUnlockAdminMessage.ARM_FAILED -> {
                    R.string.remote_unlock_admin_message_arm_failed
                }
            },
        )
    }

    fun showDisarmResult(success: Boolean) {
        messageText.setText(
            if (success) {
                R.string.remote_unlock_admin_message_disarmed
            } else {
                R.string.remote_unlock_admin_message_disarm_failed
            },
        )
    }

    private fun textView(
        textRes: Int?,
        sizeSp: Float,
        topMarginDp: Int = 0,
    ) = TextView(context).apply {
        textRes?.let(::setText)
        textSize = sizeSp
        gravity = Gravity.CENTER_HORIZONTAL
        layoutParams =
            LinearLayout
                .LayoutParams(
                    ViewGroup.LayoutParams.MATCH_PARENT,
                    ViewGroup.LayoutParams.WRAP_CONTENT,
                ).apply { topMargin = dp(topMarginDp) }
    }

    private fun button(textRes: Int) = Button(context).apply { setText(textRes) }

    private fun buttonLayoutParams(topMarginDp: Int) =
        LinearLayout
            .LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.WRAP_CONTENT,
            ).apply { topMargin = dp(topMarginDp) }

    private fun dp(value: Int) = (value * resources.displayMetrics.density).toInt()

    private companion object {
        const val CONTENT_HORIZONTAL_DP = 24
        const val CONTENT_TOP_DP = 32
        const val DESCRIPTION_MARGIN_DP = 12
        const val STATUS_MARGIN_DP = 28
        const val MESSAGE_MARGIN_DP = 16
        const val PRIMARY_BUTTON_MARGIN_DP = 24
        const val BUTTON_MARGIN_DP = 8
        const val TITLE_SP = 26f
        const val STATUS_SP = 18f
        const val DESCRIPTION_SP = 16f
        const val MESSAGE_SP = 15f
    }
}
