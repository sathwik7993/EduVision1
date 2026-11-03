package com.eduvision.app

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.viewModels
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
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
fun AppNav(app: EduApp, scan: ScanViewModel) {
    val nav = rememberNavController()
    val user by app.auth.user.collectAsState(initial = app.auth.currentUser)
    val start = if (app.auth.currentUser == null) "login" else "home"

    LaunchedEffect(user) {
        val route = nav.currentDestination?.route
        if (user == null && route != null && route != "login" && route != "register") {
            nav.navigate("login") { popUpTo(0) }
        } else if (user != null && (route == "login" || route == "register")) {
            nav.navigate("home") { popUpTo(0) }
        }
    }

    NavHost(nav, startDestination = start) {
        composable("login") { LoginScreen(app.auth, onRegister = { nav.navigate("register") }) }
        composable("register") { RegisterScreen(app.auth, onBack = { nav.popBackStack() }) }
        composable("home") {
            HomeScreen(app, scan,
                onReview = { nav.navigate("review") },
                onResults = { nav.navigate("results") },
                onTemplates = { nav.navigate("templates") },
                onAccount = { nav.navigate("account") })
        }
        composable("review") { ReviewScreen(app, scan, onDone = { nav.popBackStack() }) }
        composable("results") { ResultsScreen(app, onBack = { nav.popBackStack() }) }
        composable("templates") {
            TemplatesScreen(app, onBack = { nav.popBackStack() }, onEdit = { nav.navigate("template/$it") })
        }
        composable("template/{id}") { entry ->
            TemplateEditorScreen(app, entry.arguments?.getString("id")!!, onBack = { nav.popBackStack() })
        }
        composable("account") { AccountScreen(app, onBack = { nav.popBackStack() }) }
    }
}
