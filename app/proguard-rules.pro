# ONNX Runtime is reached from JNI; R8 cannot see those references.
-keep class ai.onnxruntime.** { *; }
-dontwarn ai.onnxruntime.**

# OpenCV's Java classes are called back from native code.
-keep class org.opencv.** { *; }

# kotlinx.serialization: keep generated serializers of the core model.
-keepattributes *Annotation*, InnerClasses
-keepclassmembers class com.eduvision.core.model.** {
    *** Companion;
    kotlinx.serialization.KSerializer serializer(...);
}
-keep,includedescriptorclasses class com.eduvision.core.model.**$$serializer { *; }

# Credential Manager / Google ID (reflection from Play services).
-if class androidx.credentials.CredentialManager
-keep class androidx.credentials.playservices.** { *; }
