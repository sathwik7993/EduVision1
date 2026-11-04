package com.eduvision.app

import android.net.Uri
import androidx.activity.ComponentActivity
import androidx.compose.ui.test.hasText
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.performClick
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.eduvision.app.ui.EduTheme
import com.eduvision.app.ui.ScanViewModel
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File

/**
 * Leaving the set-up and review screens returns to the home screen and stays
 * there. 0.4.0 closed the review screen twice (black window) and reopened
 * the set-up screen after the phone's back button.
 */
@RunWith(AndroidJUnit4::class)
class NavigationUiTest {
    @get:Rule val compose = createAndroidComposeRule<ComponentActivity>()

    private fun waitForText(text: String, ms: Long = 90_000) =
        compose.waitUntil(ms) { compose.onAllNodes(hasText(text, substring = true)).fetchSemanticsNodes().isNotEmpty() }

    /** The home screen is shown, and still shown a moment later. */
    private fun assertHomeStays() {
        waitForText(HOME, 10_000)
        Thread.sleep(1500)
        compose.waitForIdle()
        compose.onNodeWithText(HOME).assertIsDisplayed()
    }

    @Test
    fun leavingSetupAndReviewReturnsHome() {
        val instr = InstrumentationRegistry.getInstrumentation()
        val app = instr.targetContext.applicationContext as EduApp
        app.templates.all().forEach { app.templates.delete(it.id) }
        val photo = File(app.cacheDir, "nav_sheet.png")
        instr.context.assets.open("bench/sheet_clean.png").use { i -> photo.outputStream().use { i.copyTo(it) } }
        val scan = ScanViewModel(app)
        compose.setContent { EduTheme { AppNav(app, scan, signedIn = true) } }
        waitForText(HOME, 10_000)

        // A new layout, then the phone's back button on the set-up screen.
        compose.runOnUiThread { scan.process(Uri.fromFile(photo), newLayout = true) }
        waitForText("Save and read")
        compose.runOnUiThread { compose.activity.onBackPressedDispatcher.onBackPressed() }
        assertHomeStays()

        // A scan with the saved layout, then "Discard" on the review screen.
        compose.runOnUiThread { scan.process(Uri.fromFile(photo)) }
        waitForText("Check before saving")
        compose.onNodeWithContentDescription("Discard").performClick()
        assertHomeStays()

        app.templates.all().forEach { app.templates.delete(it.id) }
    }

    companion object {
        const val HOME = "Scan an exam sheet"
    }
}
