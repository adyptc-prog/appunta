import java.util.Properties

plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

val keyProperties = Properties().apply {
    // -PkeyProperties=<cale> permite alt fișier (ex. CI); implicit android/key.properties.
    val keyPropertiesFile = rootProject.file(
        providers.gradleProperty("keyProperties").getOrElse("key.properties")
    )
    if (keyPropertiesFile.exists()) load(keyPropertiesFile.inputStream())
}

android {
    namespace = "com.example.management_app"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        isCoreLibraryDesugaringEnabled = true
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    buildFeatures {
        // BuildConfig.DEBUG — jurnalul detaliat (Diag) doar în debug.
        buildConfig = true
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    defaultConfig {
        applicationId = "app.sayitapp.organizator"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        create("release") {
            storeFile = keyProperties["storeFile"]?.let { file(it) }
            storePassword = keyProperties["storePassword"] as String?
            keyAlias = keyProperties["keyAlias"] as String?
            keyPassword = keyProperties["keyPassword"] as String?
        }
    }

    testOptions {
        // Robolectric: testele JVM rulează receiverele și SharedPreferences reale.
        unitTests.isIncludeAndroidResources = true
        // Testele verifică textele în română: fixează limba telefonului simulat
        // (AppLang), indiferent de limba mașinii. Testele pentru engleză o aleg explicit.
        unitTests.all { it.systemProperty("applang.testDeviceLanguage", "ro") }
    }

    buildTypes {
        release {
            // Întotdeauna cheia de release: fără key.properties build-ul de
            // release eșuează (vezi mai jos), în loc să producă pe tăcute un
            // APK semnat cu cheia de debug, care nu se poate instala peste
            // versiunea publicată.
            signingConfig = signingConfigs.getByName("release")
        }
    }
}

val releaseKeyMissing = keyProperties["storeFile"]
    ?.let { !project.file(it as String).exists() } ?: true

// preReleaseBuild rulează la începutul oricărui build de release (APK sau bundle).
tasks.matching { it.name == "preReleaseBuild" }.configureEach {
    doFirst {
        if (releaseKeyMissing) {
            // Fără diacritice: consola Windows le afișează greșit.
            throw GradleException(
                "Lipseste cheia de semnare release: creeaza android/key.properties " +
                    "(storeFile, storePassword, keyAlias, keyPassword) cu keystore-ul aplicatiei."
            )
        }
    }
}

flutter {
    source = "../.."
}

dependencies {
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
    implementation("androidx.work:work-runtime-ktx:2.9.1")

    testImplementation("junit:junit:4.13.2")
    // android.jar conține doar stub-uri pentru org.json — testele JVM au
    // nevoie de implementarea reală.
    testImplementation("org.json:json:20240303")
    testImplementation("org.robolectric:robolectric:4.15.1")
    testImplementation("androidx.test:core:1.6.1")
}
