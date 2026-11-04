// Recognition pipeline, validation and data model: plain Kotlin on the JVM so
// the whole pipeline runs (and is tested) on a desktop against the real model
// and the sample photos. OpenCV and ONNX Runtime are compileOnly: the Android
// app supplies their Android builds, the tests their desktop builds.
plugins {
    alias(libs.plugins.kotlin.jvm)
    alias(libs.plugins.kotlin.serialization)
}

// Bytecode level 17 (what Android's D8 accepts), built with whatever JDK runs Gradle.
java {
    sourceCompatibility = JavaVersion.VERSION_17
    targetCompatibility = JavaVersion.VERSION_17
}
kotlin {
    compilerOptions { jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17) }
}

dependencies {
    api(libs.kotlinx.serialization.json)
    compileOnly(libs.onnxruntime.jvm)
    compileOnly(libs.opencv.jvm)
    testImplementation(libs.onnxruntime.jvm)
    testImplementation(libs.opencv.jvm)
    testImplementation(libs.junit)
}

tasks.test {
    // The real-photo tests read sample_images/ and assets/ from the repo root.
    systemProperty("repoRoot", rootDir.absolutePath)
    maxHeapSize = "2g"
    testLogging {
        events("failed")
        showStandardStreams = true
        exceptionFormat = org.gradle.api.tasks.testing.logging.TestExceptionFormat.FULL
    }
}
