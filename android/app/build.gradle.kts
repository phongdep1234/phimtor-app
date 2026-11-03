plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    id("org.jetbrains.kotlin.plugin.compose")
}

android {
    namespace = "com.thayphong.phimtor"
    compileSdk = 36

    defaultConfig {
        applicationId = "com.thayphong.phimtor"
        minSdk = 23
        targetSdk = 34
        versionCode = 200
        versionName = "2.0.0"
        ndk { abiFilters += listOf("arm64-v8a", "armeabi-v7a") }
    }

    signingConfigs {
        create("release") {
            // khoá ký lấy từ biến môi trường của GitHub Actions (không lưu trong mã nguồn)
            storeFile = file(System.getenv("PT_KEYSTORE") ?: "phimtor.jks")
            storePassword = System.getenv("PT_STORE_PASS") ?: ""
            keyAlias = System.getenv("PT_KEY_ALIAS") ?: "phimtor"
            keyPassword = System.getenv("PT_KEY_PASS") ?: ""
        }
    }

    buildTypes {
        release {
            isMinifyEnabled = false
            signingConfig = signingConfigs.getByName("release")
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    buildFeatures { compose = true }
    packaging { jniLibs { useLegacyPackaging = true } }
}

kotlin {
    compilerOptions { jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17) }
}

dependencies {
    implementation(files("libs/phimengine.aar"))
    implementation("org.videolan.android:libvlc-all:3.7.7")
    implementation(platform("androidx.compose:compose-bom:2024.12.01"))
    implementation("androidx.compose.ui:ui")
    implementation("androidx.compose.foundation:foundation")
    implementation("androidx.compose.material3:material3")
    implementation("androidx.compose.material:material-icons-extended")
    implementation("androidx.activity:activity-compose:1.9.3")
    implementation("androidx.core:core-ktx:1.13.1")
    implementation("io.coil-kt:coil-compose:2.7.0")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.9.0")
}
