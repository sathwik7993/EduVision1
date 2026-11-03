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
    }

    var state by mutableStateOf<State>(State.Idle)
        private set

    /** What the model read before the teacher touched anything, for the correction log. */
    private var modelValues: Map<FieldKind, String> = emptyMap()

    fun process(uri: Uri) {
        state = State.Working
        viewModelScope.launch {
            state = try {
                val photo = withContext(Dispatchers.IO) { Scanner.copyToFile(app, uri) }
                val scan = app.scanner.scan(photo)
                modelValues = mapOf(
                    FieldKind.REGISTRATION to scan.result.registrationNo.value,
                    FieldKind.PART_A to scan.result.partA.value,
                    FieldKind.PART_B to scan.result.partB.value,
                )
                State.Ready(scan, validate(scan.result, scan.template))
            } catch (e: Exception) {
                State.Failed(e.message ?: e.toString())
            }
        }
    }

    private fun validate(r: ScanResult, t: SheetTemplate) =
        ScanValidator.validate(r, t, app.roster.load(), app.results.registrations())

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
        app.corrections.record(s.result, modelValues)
        reset()
    }

    fun reset() {
        state = State.Idle
    }
}
