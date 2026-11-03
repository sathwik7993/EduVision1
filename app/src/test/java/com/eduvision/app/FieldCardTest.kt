package com.eduvision.app

import android.app.Application
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import com.eduvision.app.ui.EduTheme
import com.eduvision.app.ui.FieldCard
import com.eduvision.core.model.ExtractedField
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(application = Application::class, sdk = [35])
class FieldCardTest {
    @get:Rule val compose = createComposeRule()

    @Test fun doubtfulReadingShowsIssueAndSuggestion() {
        var changed: ExtractedField? = null
        val f = ExtractedField("23H51A6609", 0.97, issue = "Could also be 23H51A66D9", suggestion = "23H51A66D9")
        compose.setContent { EduTheme { FieldCard("Registration No", f, text = true) { changed = it } } }
        compose.onNodeWithText("Could also be 23H51A66D9").assertIsDisplayed()
        compose.onNodeWithText("Use 23H51A66D9").performClick()
        assertEquals("23H51A66D9", changed!!.value)
        assertTrue(changed!!.edited)
    }

    @Test fun matchesTheSheetConfirmsValue() {
        var changed: ExtractedField? = null
        val f = ExtractedField("40", 0.86)
        compose.setContent { EduTheme { FieldCard("Part-A total", f) { changed = it } } }
        compose.onNodeWithText("86% sure").assertIsDisplayed()
        compose.onNodeWithText("Matches the sheet").performClick()
        assertEquals("40", changed!!.value)
        assertTrue(changed!!.edited)
    }
}
