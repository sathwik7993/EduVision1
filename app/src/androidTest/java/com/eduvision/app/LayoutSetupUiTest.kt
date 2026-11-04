package com.eduvision.app

import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.test.click
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performTextInput
import androidx.compose.ui.test.performTouchInput
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.eduvision.app.ui.EduTheme
import com.eduvision.app.ui.TemplateEditorScreen
import com.eduvision.core.model.FieldKind
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File

/**
 * The teacher's setup of a new paper layout, on a device: a sample sheet
 * (synthetic layout B) becomes a layout with suggested fields, the teacher
 * taps the "Internal" box, names it, and saves.
 */
@RunWith(AndroidJUnit4::class)
class LayoutSetupUiTest {
    @get:Rule val compose = createComposeRule()

    @Test
    fun tapABoxNameItSave() {
        val instr = InstrumentationRegistry.getInstrumentation()
        val app = instr.targetContext.applicationContext as EduApp
        val photo = File(app.cacheDir, "b_sheet_clean.png")
        instr.context.assets.open("bench/b_sheet_clean.png").use { i -> photo.outputStream().use { i.copyTo(it) } }
        val t = runBlocking { app.scanner.templateFromPhoto(photo, "Greenfield test") }
        assertTrue(t.fields.map { it.kind }.containsAll(listOf(FieldKind.REGISTRATION, FieldKind.PART_A, FieldKind.PART_B)))

        var saved = false
        compose.setContent { EduTheme { TemplateEditorScreen(app, t.id, setup = true, onBack = {}, onSaved = { saved = true }) } }
        // Inside the "Internal" marks box: x 740/1240, y 1325/1754 of the page.
        compose.onNodeWithContentDescription("Sample sheet").performTouchInput {
            click(Offset(width * 740f / 1240f, height * 1325f / 1754f))
        }
        compose.waitUntil(5_000) { compose.onAllNodes(androidx.compose.ui.test.hasText("What is in this box?")).fetchSemanticsNodes().isNotEmpty() }
        compose.onNodeWithText("Other number").performClick()
        compose.onNodeWithText("Column name (e.g. Internal marks)").performTextInput("Internal")
        compose.onNodeWithText("Save").performClick()
        compose.onNodeWithText("Save and read").performClick()
        compose.waitUntil(5_000) { saved }

        val after = app.templates.get(t.id)
        assertNotNull(after)
        val internal = after!!.fields.single { it.kind == FieldKind.MARK }
        assertEquals("Internal", internal.label)
        // Snapped to the printed box: x 620..860, y 1270..1380 of the page.
        assertEquals(620.0 / 1240, internal.box.left, 0.02)
        assertEquals(860.0 / 1240, internal.box.right, 0.02)
        assertEquals(1270.0 / 1754, internal.box.top, 0.02)
        assertEquals(1380.0 / 1754, internal.box.bottom, 0.02)
        app.templates.delete(t.id)
    }
}
