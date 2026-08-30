package com.mwodevelop.androidremotecontrol.shizukuadmin

import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.DisplayName
import org.junit.jupiter.api.Test
import org.w3c.dom.Element
import java.io.File
import javax.xml.parsers.DocumentBuilderFactory

@DisplayName("Remote-unlock administrator manifest")
class RemoteUnlockAdminManifestTest {
    @Test
    fun `administrator launcher uses a dedicated task affinity`() {
        val document =
            DocumentBuilderFactory
                .newInstance()
                .apply { setFeature("http://apache.org/xml/features/disallow-doctype-decl", true) }
                .newDocumentBuilder()
                .parse(resolveManifest())

        val activities = document.getElementsByTagName("activity")
        val administrator =
            (0 until activities.length)
                .map { activities.item(it) as Element }
                .single { it.getAttribute("android:name") == ".RemoteUnlockAdminActivity" }

        assertEquals(
            "\${applicationId}.remote_unlock_admin",
            administrator.getAttribute("android:taskAffinity"),
            "The administrator launcher must not share the main application's task on OEM launchers",
        )
    }

    private fun resolveManifest(): File =
        listOf(
            File("src/main/AndroidManifest.xml"),
            File("shizuku-admin/src/main/AndroidManifest.xml"),
        ).firstOrNull { it.isFile }
            ?: error("shizuku-admin manifest not found (cwd=${File(".").absolutePath})")
}
