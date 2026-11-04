import java.util.Properties

plugins {
    alias(libs.plugins.android.application)
    alias(libs.plugins.kotlin.android)
    alias(libs.plugins.kotlin.compose)
    alias(libs.plugins.kotlin.serialization)
    alias(libs.plugins.google.services)
}

// Release signing comes from key.properties at the repo root (gitignored). Without
// it the release build is signed with the debug key: installable, not publishable.
val keystore = Properties().apply {
    rootProject.file("key.properties").takeIf { it.exists() }?.inputStream()?.use(::load)
}

android {
    namespace = "com.eduvision.app"
    compileSdk = 36

    defaultConfig {
        // Must match package_name in google-services.json (Firebase project).
        applicationId = "com.example.eduvision_0_1"
        minSdk = 24
        targetSdk = 36
        versionCode = 8
        versionName = "0.4.4"
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
    }

    signingConfigs {
        if (keystore.isNotEmpty()) {
            create("release") {
                storeFile = rootProject.file(keystore.getProperty("storeFile"))
                storePassword = keystore.getProperty("storePassword")
                keyAlias = keystore.getProperty("keyAlias")
                keyPassword = keystore.getProperty("keyPassword")
            }
        }
    }

    buildTypes {
        release {
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
            signingConfig = signingConfigs.findByName("release") ?: signingConfigs.getByName("debug")
        }
    }

    splits {
        // One APK per CPU type: ONNX Runtime and OpenCV are native libraries,
        // and a universal APK would carry all of them.
        abi {
            isEnable = true
            reset()
            include("arm64-v8a", "armeabi-v7a", "x86_64")
            // The universal APK is for device farms that need one file for all phones.
            isUniversalApk = true
        }
    }

    sourceSets["main"].assets.srcDir(rootProject.file("assets"))
    androidResources {
        // Models are memory-read by ONNX Runtime; storing them uncompressed
        // keeps the APK download the same size and the first load faster.
        noCompress += "onnx"
        ignoreAssetsPattern = "!NOTICE.md:!.*"
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlin {
        compilerOptions { jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17) }
    }
    buildFeatures {
        compose = true
        buildConfig = true
    }
    testOptions {
        unitTests.isIncludeAndroidResources = true
        unitTests.all { test ->
            // Robolectric fetches its Android runtime jar at test time; a
            // mirror can be set in ~/.gradle/gradle.properties.
            providers.gradleProperty("robolectricRepo").orNull?.let {
                test.systemProperty("robolectric.dependency.repo.url", it)
            }
        }
    }
    packaging {
        resources.excludes += setOf("META-INF/{AL2.0,LGPL2.1}", "META-INF/versions/9/OSGI-INF/MANIFEST.MF")
    }
}

dependencies {
    implementation(project(":core"))
    implementation(libs.opencv.android)
    implementation(libs.onnxruntime.android)
    implementation(libs.kotlinx.coroutines.android)
    implementation(libs.kotlinx.coroutines.play)
    implementation(libs.exifinterface)

    implementation(platform(libs.compose.bom))
    implementation(libs.compose.ui)
    implementation(libs.compose.material3)
    implementation(libs.compose.material.icons)
    implementation(libs.activity.compose)
    implementation(libs.navigation.compose)
    implementation(libs.lifecycle.viewmodel.compose)
    implementation(libs.lifecycle.runtime.compose)
    debugImplementation(libs.compose.ui.tooling)

    implementation(libs.mlkit.docscanner)
    implementation(platform(libs.firebase.bom))
    implementation(libs.firebase.auth)
    implementation(libs.credentials)
    implementation(libs.credentials.play)
    implementation(libs.googleid)

    testImplementation(libs.junit)
    testImplementation(libs.robolectric)
    testImplementation(libs.androidx.test.core)
    testImplementation(platform(libs.compose.bom))
    testImplementation(libs.compose.ui.test.junit4)
    debugImplementation(libs.compose.ui.test.manifest)

    androidTestImplementation(libs.androidx.test.runner)
    androidTestImplementation(libs.androidx.test.ext.junit)
    androidTestImplementation(libs.junit)
    androidTestImplementation(platform(libs.compose.bom))
    androidTestImplementation(libs.compose.ui.test.junit4)
}
