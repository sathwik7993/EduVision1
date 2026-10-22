import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'firebase_options.dart';
import 'pages/home_page.dart';
import 'pages/login_or_register_page.dart';
import 'services/auth_service.dart';
import 'theme/app_theme.dart';
import 'widgets/glass.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
  SystemChrome.setSystemUIOverlayStyle(AppTheme.overlayStyle);

  // A Firebase failure is fatal for this app -- every screen behind the gate
  // needs auth. The old code caught the error, printed it, and carried on into
  // a UI that would then throw on first use.
  Object? initError;
  try {
    await _initialiseFirebase();
  } on Object catch (e) {
    initError = e;
  }

  runApp(EduVisionApp(initError: initError));
}

/// Bring up the default Firebase app, tolerating the fact that it may already
/// exist.
///
/// On Android the com.google.gms.google-services plugin registers a ContentProvider
/// that initialises the [DEFAULT] app from google-services.json before any Dart
/// code runs. Calling initializeApp() again with options that differ from that
/// native app -- even in one field -- fails with [core/duplicate-app] rather
/// than reconciling them. Hot restart hits the same path.
Future<FirebaseApp> _initialiseFirebase() async {
  if (Firebase.apps.isNotEmpty) {
    return Firebase.app();
  }
  try {
    return await Firebase.initializeApp(
      options: DefaultFirebaseOptions.currentPlatform,
    );
  } on FirebaseException catch (e) {
    if (e.code == 'duplicate-app') return Firebase.app();
    rethrow;
  }
}

class EduVisionApp extends StatelessWidget {
  const EduVisionApp({super.key, this.initError});

  final Object? initError;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'EduVision',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light(),
      home: initError == null
          ? const AuthGate()
          : _StartupError(error: initError!),
    );
  }
}

/// Routes to the app or the sign-in flow based on Firebase auth state.
///
/// This replaces the old arrangement where `main.dart` and `auth_page.dart`
/// each ran their own StreamBuilder over the same stream, nested inside one
/// another.
class AuthGate extends StatelessWidget {
  const AuthGate({super.key});

  @override
  Widget build(BuildContext context) {
    return StreamBuilder(
      stream: AuthService.instance.authStateChanges,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const _Splash();
        }
        // AnimatedSwitcher gives a crossfade instead of the hard cut the app
        // previously did between the login screen and home.
        return AnimatedSwitcher(
          duration: AppMotion.normal,
          switchInCurve: AppMotion.curve,
          child: snapshot.hasData
              ? const HomePage(key: ValueKey('home'))
              : const LoginOrRegisterPage(key: ValueKey('auth')),
        );
      },
    );
  }
}

class _Splash extends StatelessWidget {
  const _Splash();

  @override
  Widget build(BuildContext context) {
    return const AmbientBackground(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        body: Center(child: CircularProgressIndicator()),
      ),
    );
  }
}

class _StartupError extends StatelessWidget {
  const _StartupError({required this.error});

  final Object error;

  @override
  Widget build(BuildContext context) {
    return AmbientBackground(
      animate: false,
      child: Scaffold(
        backgroundColor: Colors.transparent,
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(AppSpacing.lg),
            child: GlassCard(
              radius: AppRadius.xl,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.cloud_off,
                      size: 46, color: AppColors.inkMuted),
                  const SizedBox(height: AppSpacing.md),
                  Text('Could not start EduVision',
                      style: Theme.of(context).textTheme.titleLarge),
                  const SizedBox(height: AppSpacing.sm),
                  Text(
                    'Firebase failed to initialise. Check that '
                    'google-services.json matches this build.',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                  const SizedBox(height: AppSpacing.md),
                  Text(
                    '$error',
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      fontSize: 11,
                      color: AppColors.inkFaint,
                      fontFamily: 'monospace',
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
