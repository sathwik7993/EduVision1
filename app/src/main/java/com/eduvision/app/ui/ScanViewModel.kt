package com.eduvision.app.ui

import android.app.Application
import android.net.Uri
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import com.eduvision.app.EduApp
import com.eduvision.app.recog.Scan
import com.eduvision.app.recog.NeedsSetup
import com.eduvision.app.recog.Scanner
import com.eduvision.core.model.ExtractedField
import com.eduvision.core.model.FieldKind
import com.eduvision.core.model.ScanResult
import com.eduvision.core.model.SheetTemplate
import com.eduvision.core.validate.ScanValidator
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/** The scan being reviewed, shared by the home and review screens. */
class ScanViewModel(application: Application) : AndroidViewModel(application) {
    private val app = application as EduApp

    sealed interface State {
        data object Idle : State
        data object Working : State
        data class Failed(val message: String) : State
        data class Ready(val scan: Scan, val result: ScanResult) : State

        /** A new paper layout: the teacher selects its fields, then [photo] is read with it. */
        data class Setup(val templateId: String, val photo: java.io.File) : State
    }

    var state by mutableStateOf<State>(State.Idle)
        private set

    /** What the model read before the teacher touched anything, for the correction log. */
    private var modelValues: Map<String, String> = emptyMap()

    fun process(uri: Uri, newLayout: Boolean = false) {
        state = State.Working
        viewModelScope.launch {
            state = try {
                val photo = withContext(Dispatchers.IO) { Scanner.copyToFile(app, uri) }
                ready(app.scanner.scan(photo, newLayout))
            } catch (e: NeedsSetup) {
                State.Setup(e.templateId, e.photo)
            } catch (e: Exception) {
                State.Failed(e.message ?: e.toString())
            }
        }
    }

    /** The teacher saved the new layout's fields: read the sample sheet with it. */
    fun setupDone() {
        val s = state as? State.Setup ?: return
        state = State.Working
        viewModelScope.launch {
            state = try {
                val t = app.templates.get(s.templateId) ?: error("Layout was deleted")
                if (t.fields.isEmpty()) State.Idle
                else ready(Scan(app.scanner.reread(s.photo, t), t, true, s.photo))
            } catch (e: Exception) {
                State.Failed(e.message ?: e.toString())
            }
        }
    }

    private fun ready(scan: Scan): State.Ready {
        val r = scan.result
        modelValues = buildMap {
            put(FieldKind.REGISTRATION.name, r.registrationNo.value)
            put(FieldKind.PART_A.name, r.partA.value)
            put(FieldKind.PART_B.name, r.partB.value)
            (r.writtenTotals + r.extras + r.questions).forEach { put(it.label, it.field.value) }
        }
        return State.Ready(scan, validate(r, scan.template))
    }

    private fun validate(r: ScanResult, t: SheetTemplate) =
        suggestKnown(ScanValidator.validate(r, t, app.roster.load(), app.results.registrations()), t)

    /** Titles of the layout's written-word fields. */
    private fun textFields(t: SheetTemplate) = t.fields.filter { it.kind == FieldKind.TEXT }.map { it.title }.toSet()

    /** A written field close to a value confirmed on earlier sheets gets it as a one-tap suggestion. */
    private fun suggestKnown(r: ScanResult, t: SheetTemplate): ScanResult {
        val text = textFields(t)
        return r.copy(extras = r.extras.map { m ->
            if (m.label !in text || m.field.edited || m.field.suggestion != null) return@map m
            val s = app.knownValues.of(t.id, m.label).suggest(m.field.value) ?: return@map m
            m.copy(field = m.field.copy(suggestion = s))
        })
    }

    /** A value the teacher typed or confirmed: authoritative, then re-check the rest. */
    fun edit(update: (ScanResult) -> ScanResult) {
        val s = state as? State.Ready ?: return
        state = s.copy(result = validate(update(s.result), s.scan.template))
    }

    fun manual(f: ExtractedField, value: String) = ExtractedField.manual(value.trim().uppercase(), f.crop)

    /** Applies the registration format to the template and re-reads the photo with it. */
    fun setRegistrationMask(mask: String) {
        val s = state as? State.Ready ?: return
        val t = s.scan.template.copy(registrationMask = mask.uppercase().filter { it in "DAX" }.ifEmpty { null })
        app.templates.save(t)
        state = State.Working
        viewModelScope.launch {
            state = try {
                val saved = app.templates.get(t.id)!!
                val r = app.scanner.reread(s.scan.photo, saved)
                State.Ready(s.scan.copy(template = saved, newLayout = false, result = r), validate(r, saved))
            } catch (e: Exception) {
                State.Failed(e.message ?: e.toString())
            }
        }
    }

    fun setMaxima(partA: Int, partB: Int) {
        val s = state as? State.Ready ?: return
        val t = s.scan.template.copy(partAMax = partA, partBMax = partB)
        app.templates.save(t)
        state = s.copy(scan = s.scan.copy(template = t), result = validate(s.result, t))
    }

    fun blockingErrors(): List<String> {
        val s = state as? State.Ready ?: return emptyList()
        return ScanValidator.blockingErrors(s.result, s.scan.template)
    }

    fun isDuplicate(): Boolean {
        val s = state as? State.Ready ?: return false
        return app.results.contains(s.result.registrationNo.value)
    }

    fun save() {
        val s = state as? State.Ready ?: return
        app.results.save(s.result, s.scan.template.name)
        val text = textFields(s.scan.template)
        app.knownValues.record(s.scan.template.id, s.result.extras.filter { it.label in text }.associate { it.label to it.field.value })
        app.corrections.record(s.result, modelValues)
        reset()
    }

    fun reset() {
        state = State.Idle
    }
}
