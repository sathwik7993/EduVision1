package com.eduvision.app

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.BackHandler
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.viewModels
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.navigation.NavBackStackEntry
import androidx.navigation.compose.NavHost
import androidx.navigation.compose.composable
import androidx.navigation.compose.rememberNavController
import com.eduvision.app.ui.AccountScreen
import com.eduvision.app.ui.EduTheme
import com.eduvision.app.ui.HomeScreen
import com.eduvision.app.ui.LoginScreen
import com.eduvision.app.ui.RegisterScreen
import com.eduvision.app.ui.ResultsScreen
import com.eduvision.app.ui.ReviewScreen
import com.eduvision.app.ui.ScanViewModel
import com.eduvision.app.ui.TemplateEditorScreen
import com.eduvision.app.ui.TemplatesScreen

class MainActivity : ComponentActivity() {
    private val scan: ScanViewModel by viewModels()

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        val app = application as EduApp
        setContent {
            EduTheme { AppNav(app, scan) }
        }
    }
}

@Composable
fun AppNav(app: EduApp, scan: ScanViewModel, signedIn: Boolean? = null) {
    val nav = rememberNavController()
    val user by app.auth.user.collectAsState(initial = app.auth.currentUser)
    // [signedIn] overrides the account state (UI tests run without Firebase sign-in).
    val start = if ((signedIn ?: (app.auth.currentUser != null))) "home" else "login"

    LaunchedEffect(user) {
        if (signedIn != null) return@LaunchedEffect
        val route = nav.currentDestination?.route
        if (user == null && route != null && route != "login" && route != "register") {
            nav.navigate("login") { popUpTo(0) }
        } else if (user != null && (route == "login" || route == "register")) {
            nav.navigate("home") { popUpTo(0) }
        }
    }

    /**
     * Leaves the screen of [entry], once. A screen can ask to close twice
     * (a button, then its reaction to the cleared scan); a second plain
     * popBackStack() would close the home screen too and leave a black
     * window.
     */
    fun close(entry: NavBackStackEntry) {
        if (nav.currentBackStackEntry == entry) nav.popBackStack()
    }

    NavHost(nav, startDestination = start) {
        composable("login") { LoginScreen(app.auth, onRegister = { nav.navigate("register") }) }
        composable("register") { e -> RegisterScreen(app.auth, onBack = { close(e) }) }
        composable("home") {
            HomeScreen(app, scan,
                onReview = { nav.navigate("review") },
                onSetup = { id -> nav.navigate("setup/$id") },
                onResults = { nav.navigate("results") },
                onTemplates = { nav.navigate("templates") },
                onAccount = { nav.navigate("account") })
        }
        composable("review") { e -> ReviewScreen(app, scan, onDone = { close(e) }) }
        composable("results") { e -> ResultsScreen(app, onBack = { close(e) }) }
        composable("templates") { e ->
            TemplatesScreen(app, onBack = { close(e) }, onEdit = { nav.navigate("template/$it") })
        }
        composable("template/{id}") { entry ->
            TemplateEditorScreen(app, entry.arguments?.getString("id")!!, onBack = { close(entry) })
        }
        composable("setup/{id}") { entry ->
            val cancel = { scan.reset(); close(entry) }
            // The phone's back button too: otherwise the scan stays in set-up
            // and the home screen opens this screen again at once.
            BackHandler { cancel() }
            TemplateEditorScreen(app, entry.arguments?.getString("id")!!, setup = true,
                onBack = cancel,
                onSaved = { scan.setupDone(); nav.navigate("review") { popUpTo("home") } })
        }
        composable("account") { e -> AccountScreen(app, onBack = { close(e) }) }
    }
}
