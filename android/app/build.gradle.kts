import java.util.Properties

plugins {
    alias(libs.plugins.android.application)
    alias(libs.plugins.kotlin.android)
    alias(libs.plugins.kotlin.compose)
    alias(libs.plugins.kotlin.serialization)
}

val keystore = rootProject.file("keystore.properties").takeIf { it.exists() }?.let { f ->
    Properties().apply { f.inputStream().use { input -> load(input) } }
}

android {
    namespace = "app.tonalo.android"
    compileSdk = 35

    defaultConfig {
        applicationId = "app.tonalo.android"
        minSdk = 26
        targetSdk = 35
        versionCode = 1
        versionName = "0.1.0"
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
    }

    // The upload key for Google Play lives outside the repository: keystore.properties next to this project's
    // settings.gradle.kts (storeFile, storePassword, keyAlias, keyPassword). Without it, a release build is signed
    // with the debug key – fine for trying it out, not for the Play Store.
    signingConfigs {
        if (keystore != null) create("upload") {
            storeFile = rootProject.file(keystore.getProperty("storeFile"))
            storePassword = keystore.getProperty("storePassword")
            keyAlias = keystore.getProperty("keyAlias")
            keyPassword = keystore.getProperty("keyPassword")
        }
    }

    buildTypes {
        release {
            signingConfig = if (keystore != null) signingConfigs.getByName("upload") else signingConfigs.getByName("debug")
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlinOptions {
        jvmTarget = "17"
    }
    buildFeatures {
        compose = true
    }
}

dependencies {
    implementation(libs.androidx.core.ktx)
    implementation(libs.androidx.activity.compose)
    implementation(libs.androidx.lifecycle.runtime.compose)
    implementation(libs.androidx.lifecycle.viewmodel.compose)
    implementation(libs.androidx.navigation.compose)

    implementation(platform(libs.compose.bom))
    implementation(libs.compose.ui)
    implementation(libs.compose.ui.tooling.preview)
    implementation(libs.compose.material3)
    implementation(libs.compose.material.icons)
    debugImplementation(libs.compose.ui.tooling)

    implementation(libs.media3.exoplayer)
    implementation(libs.media3.session)
    implementation(libs.media3.datasource.okhttp)

    implementation(libs.okhttp)
    implementation(libs.androidsvg)

    androidTestImplementation(libs.test.runner)
    androidTestImplementation(libs.test.junit)
    androidTestImplementation(libs.junit)
    implementation(libs.kotlinx.serialization.json)
    implementation(libs.coil.compose)
    implementation(libs.coil.network.okhttp)
    implementation(libs.coil.svg)
    implementation(libs.palette)
    implementation(libs.media3.datasource)
}
