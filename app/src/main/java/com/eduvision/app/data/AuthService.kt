package com.eduvision.app.data

import android.content.Context
import androidx.credentials.CredentialManager
import androidx.credentials.CustomCredential
import androidx.credentials.GetCredentialRequest
import androidx.credentials.exceptions.GetCredentialCancellationException
import androidx.credentials.exceptions.NoCredentialException
import com.google.android.libraries.identity.googleid.GetSignInWithGoogleOption
import com.google.android.libraries.identity.googleid.GoogleIdTokenCredential
import com.google.firebase.auth.FirebaseAuth
import com.google.firebase.auth.FirebaseAuthException
import com.google.firebase.auth.FirebaseUser
import com.google.firebase.auth.GoogleAuthProvider
import kotlinx.coroutines.channels.awaitClose
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.callbackFlow
import kotlinx.coroutines.tasks.await

class AuthFailure(message: String) : Exception(message)
class AuthCancelled : Exception()

/** Firebase email/password and Google sign-in. */
class AuthService(private val webClientId: String) {
    private val auth get() = FirebaseAuth.getInstance()

    val currentUser: FirebaseUser? get() = auth.currentUser

    val user: Flow<FirebaseUser?> = callbackFlow {
        val l = FirebaseAuth.AuthStateListener { trySend(it.currentUser) }
        auth.addAuthStateListener(l)
        awaitClose { auth.removeAuthStateListener(l) }
    }

    suspend fun signIn(email: String, password: String) {
        validate(email, password)
        wrap { auth.signInWithEmailAndPassword(email.trim(), password).await() }
    }

    suspend fun register(email: String, password: String, confirm: String) {
        validate(email, password)
        if (password != confirm) throw AuthFailure("Those passwords do not match.")
        if (password.length < 6) throw AuthFailure("Use at least 6 characters for your password.")
        wrap { auth.createUserWithEmailAndPassword(email.trim(), password).await() }
    }

    suspend fun resetPassword(email: String) {
        if (email.isBlank()) throw AuthFailure("Enter your email address first.")
        wrap { auth.sendPasswordResetEmail(email.trim()).await() }
    }

    /**
     * Google through Credential Manager. Needs the OAuth web client id from
     * google-services.json and an APK signed with a key whose SHA-1 is
     * registered in the Firebase project.
     */
    suspend fun signInWithGoogle(activity: Context) {
        val option = GetSignInWithGoogleOption.Builder(webClientId).build()
        val request = GetCredentialRequest.Builder().addCredentialOption(option).build()
        val cred = try {
            CredentialManager.create(activity).getCredential(activity, request).credential
        } catch (_: GetCredentialCancellationException) {
            throw AuthCancelled()
        } catch (_: NoCredentialException) {
            throw AuthFailure("No Google account is available on this device.")
        } catch (e: Exception) {
            throw AuthFailure("Google sign-in failed: ${e.message}")
        }
        if (cred !is CustomCredential || cred.type != GoogleIdTokenCredential.TYPE_GOOGLE_ID_TOKEN_CREDENTIAL) {
            throw AuthFailure("Google sign-in returned an unexpected credential.")
        }
        val token = GoogleIdTokenCredential.createFrom(cred.data).idToken
        wrap { auth.signInWithCredential(GoogleAuthProvider.getCredential(token, null)).await() }
    }

    fun signOut() = auth.signOut()

    private fun validate(email: String, password: String) {
        if (email.isBlank() || password.isEmpty()) throw AuthFailure("Enter your email and password.")
        if (!email.trim().matches(Regex("^[^@\\s]+@[^@\\s]+\\.[^@\\s]+$"))) throw AuthFailure("That email address does not look right.")
    }

    private suspend fun wrap(block: suspend () -> Unit) {
        try {
            block()
        } catch (e: FirebaseAuthException) {
            throw AuthFailure(describe(e.errorCode))
        } catch (e: com.google.firebase.FirebaseNetworkException) {
            throw AuthFailure("No internet connection. Sign-in needs it once; scanning works offline.")
        }
    }

    private fun describe(code: String) = when (code) {
        "ERROR_INVALID_EMAIL" -> "That email address does not look right."
        "ERROR_USER_NOT_FOUND", "ERROR_WRONG_PASSWORD", "ERROR_INVALID_CREDENTIAL" -> "Wrong email or password."
        "ERROR_EMAIL_ALREADY_IN_USE" -> "An account with this email already exists. Sign in instead."
        "ERROR_WEAK_PASSWORD" -> "Use a stronger password (at least 6 characters)."
        "ERROR_TOO_MANY_REQUESTS" -> "Too many attempts. Wait a minute and try again."
        "ERROR_USER_DISABLED" -> "This account has been disabled."
        else -> "Sign-in failed ($code)."
    }
}
