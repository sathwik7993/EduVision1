package com.eduvision.app

import android.app.Application
import com.eduvision.app.data.AuthService
import com.eduvision.app.data.CorrectionStore
import com.eduvision.app.data.ResultsStore
import com.eduvision.app.data.RosterStore
import com.eduvision.app.data.TemplateStore
import com.eduvision.app.recog.Scanner
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch

/** App-wide services, created once. */
class EduApp : Application() {
    val templates by lazy { TemplateStore(this) }
    val results by lazy { ResultsStore(this) }
    val roster by lazy { RosterStore(this) }
    val corrections by lazy { CorrectionStore(this) }
    val knownValues by lazy { com.eduvision.app.data.KnownValuesStore(this) }
    val scanner by lazy { Scanner(this, templates) }
    val auth by lazy { AuthService(getString(R.string.default_web_client_id)) }

    val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)

    override fun onCreate() {
        super.onCreate()
        // Models load while the teacher is still on the home screen.
        scope.launch { runCatching { scanner.warmUp() } }
    }
}
