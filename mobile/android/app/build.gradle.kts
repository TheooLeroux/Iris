plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
    id("com.chaquo.python")
}

android {
    namespace = "fr.recolecture.entre_les_lignes"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "fr.recolecture.entre_les_lignes"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        ndk { abiFilters += listOf("armeabi-v7a", "arm64-v8a", "x86_64") }
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    buildTypes {
        release {
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName("debug")
        }
    }
}

flutter {
    source = "../.."
}

// Une seule copie des modules : le PC et Android utilisent le même moteur.
val prepareIrisPython by tasks.registering(Sync::class) {
    from("../../../prototype") {
        include("agent.py", "advice_filters.py", "storage.py", "catalogues.py",
            "catalogue_clients.py", "reading_links.py", "chapter_pages.py", "mobile_engine.py", "mangatime.py")
    }
    // Uniquement pour la première installation personnelle locale de l'updater.
    // Le workflow public n'active jamais cette option.
    if (System.getenv("IRIS_PERSONAL_BOOTSTRAP") == "1") {
        from("../../data") { include("recolecture.sqlite3"); into("seed") }
        from("../../../mangatime-20261119-134639-04c64935.json") { into("seed") }
        from("../../../recherche-catalogues") {
            include("audit-complet/resultats-revus.json", "vowrune-identification.json")
            into("seed/recherche-catalogues")
        }
    } else {
        from("../../seed") { into("seed") }
    }
    into(layout.buildDirectory.dir("generated/irisPython"))
}

chaquopy {
    defaultConfig {
        version = "3.11"
        val localPython = file("../../.tools/python311/python.exe")
        if (localPython.exists()) buildPython(localPython.absolutePath)
    }
    sourceSets.getByName("main") {
        srcDir(layout.buildDirectory.dir("generated/irisPython"))
    }
}
tasks.configureEach {
    if (name.contains("Python") && name != "prepareIrisPython") dependsOn(prepareIrisPython)
}
