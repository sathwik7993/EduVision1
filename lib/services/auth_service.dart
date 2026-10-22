import 'package:firebase_auth/firebase_auth.dart';
import 'package:google_sign_in/google_sign_in.dart';

/// Raised for anything the UI should show as a message rather than a crash.
class AuthFailure implements Exception {
  const AuthFailure(this.message);
  final String message;

  @override
  String toString() => message;
}

/// Thrown when the user backs out of the Google sheet. Callers should treat
/// this as a no-op, not an error.
class AuthCancelled implements Exception {
  const AuthCancelled();
}

/// All authentication in one place.
///
/// Previously `signInWithGoogle` was copy-pasted into both the login and
/// register pages, each with its own error handling and debug prints.
class AuthService {
  AuthService._();
  static final instance = AuthService._();

  /// The OAuth *web* client id (client_type 3) from
  /// android/app/google-services.json. On Android, google_sign_in needs the web
  /// client id here -- not the Android one -- to return an idToken that
  /// Firebase will accept.
  static const _serverClientId =
      '73270853162-13dnlf8sg4n5d8n7gnh1neqn77k9niqg.apps.googleusercontent.com';

  bool _initialised = false;

  FirebaseAuth get _auth => FirebaseAuth.instance;
  User? get currentUser => _auth.currentUser;
  Stream<User?> get authStateChanges => _auth.authStateChanges();

  /// google_sign_in 7.x requires an explicit one-time initialize() before any
  /// authenticate() call. This did not exist in the 6.x API the app used.
  Future<void> _ensureInitialised() async {
    if (_initialised) return;
    await GoogleSignIn.instance.initialize(serverClientId: _serverClientId);
    _initialised = true;
  }

  Future<UserCredential> signIn({
    required String email,
    required String password,
  }) async {
    _validate(email: email, password: password);
    try {
      return await _auth.signInWithEmailAndPassword(
        email: email.trim(),
        password: password,
      );
    } on FirebaseAuthException catch (e) {
      throw AuthFailure(_describe(e));
    }
  }

  Future<UserCredential> register({
    required String email,
    required String password,
    required String confirmPassword,
  }) async {
    _validate(email: email, password: password);
    if (password != confirmPassword) {
      throw const AuthFailure('Those passwords do not match.');
    }
    if (password.length < 6) {
      throw const AuthFailure('Use at least 6 characters for your password.');
    }
    try {
      return await _auth.createUserWithEmailAndPassword(
        email: email.trim(),
        password: password,
      );
    } on FirebaseAuthException catch (e) {
      throw AuthFailure(_describe(e));
    }
  }

  Future<UserCredential> signInWithGoogle() async {
    await _ensureInitialised();

    if (!GoogleSignIn.instance.supportsAuthenticate()) {
      throw const AuthFailure(
        'Google sign-in is not supported on this platform.',
      );
    }

    try {
      final account = await GoogleSignIn.instance.authenticate(
        scopeHint: const ['email', 'profile'],
      );

      // In 7.x `authentication` is a synchronous property exposing only an
      // idToken; the 6.x accessToken now lives on authorizationClient and is
      // not needed for a Firebase credential.
      final idToken = account.authentication.idToken;
      if (idToken == null) {
        throw const AuthFailure(
          'Google did not return a sign-in token. Check that the SHA-1 '
          'fingerprint for this build is registered in Firebase.',
        );
      }

      return await _auth.signInWithCredential(
        GoogleAuthProvider.credential(idToken: idToken),
      );
    } on GoogleSignInException catch (e) {
      // Backing out is a normal user action, not a failure to report.
      if (e.code == GoogleSignInExceptionCode.canceled) {
        throw const AuthCancelled();
      }
      throw AuthFailure('Google sign-in failed: ${e.code.name}');
    } on FirebaseAuthException catch (e) {
      throw AuthFailure(_describe(e));
    }
  }

  Future<void> sendPasswordReset(String email) async {
    if (email.trim().isEmpty) {
      throw const AuthFailure('Enter your email address first.');
    }
    try {
      await _auth.sendPasswordResetEmail(email: email.trim());
    } on FirebaseAuthException catch (e) {
      throw AuthFailure(_describe(e));
    }
  }

  Future<void> signOut() async {
    try {
      if (_initialised) await GoogleSignIn.instance.signOut();
    } on GoogleSignInException {
      // Never block a Firebase sign-out on the Google plugin failing.
    }
    await _auth.signOut();
  }

  void _validate({required String email, required String password}) {
    if (email.trim().isEmpty || password.isEmpty) {
      throw const AuthFailure('Please fill in both fields.');
    }
    if (!RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(email.trim())) {
      throw const AuthFailure('That does not look like a valid email address.');
    }
  }

  /// Firebase error codes are not user-facing. The old code showed a generic
  /// "An error occurred" for everything except two cases.
  String _describe(FirebaseAuthException e) {
    return switch (e.code) {
      'invalid-credential' ||
      'wrong-password' ||
      'user-not-found' =>
        'Incorrect email or password.',
      'invalid-email' => 'That email address is not valid.',
      'user-disabled' => 'This account has been disabled.',
      'email-already-in-use' => 'An account already exists for that email.',
      'weak-password' => 'That password is too weak.',
      'too-many-requests' => 'Too many attempts. Try again in a few minutes.',
      'network-request-failed' =>
        'No internet connection. Sign-in needs a network.',
      'operation-not-allowed' =>
        'This sign-in method is not enabled in Firebase.',
      _ => e.message ?? 'Something went wrong. Please try again.',
    };
  }
}
