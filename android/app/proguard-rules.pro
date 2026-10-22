# --- Google ML Kit text recognition ---
-keep class com.google.mlkit.vision.text.** { *; }
-keep class com.google.mlkit.common.** { *; }
-dontwarn com.google.mlkit.**

# ML Kit ships per-script text recognizers behind optional dependencies. R8 warns
# about the ones that are not bundled; only the Latin recognizer is used here.
-dontwarn com.google.mlkit.vision.text.chinese.**
-dontwarn com.google.mlkit.vision.text.devanagari.**
-dontwarn com.google.mlkit.vision.text.japanese.**
-dontwarn com.google.mlkit.vision.text.korean.**

# --- Play Services / Firebase ---
-keep class com.google.android.gms.** { *; }
-dontwarn com.google.android.gms.**
-keep class com.google.firebase.** { *; }
-dontwarn com.google.firebase.**

# --- TensorFlow Lite (offline digit classifier) ---
-keep class org.tensorflow.lite.** { *; }
-keep class org.tensorflow.lite.gpu.** { *; }
-dontwarn org.tensorflow.lite.**

# --- ONNX Runtime (on-device field recognizer) ---
# The runtime is reached from JNI; R8 cannot see those references.
-keep class ai.onnxruntime.** { *; }
-dontwarn ai.onnxruntime.**

# --- ML Kit document scanner (Play services module) ---
-keep class com.google.mlkit.vision.documentscanner.** { *; }


# --- androidx.window (pulled in by the Flutter embedding) ---
# Optional OEM extension APIs, present only on some devices. R8 reported them as
# missing in the release build; they are looked up reflectively at runtime.
-dontwarn androidx.window.extensions.**
-dontwarn androidx.window.sidecar.**

