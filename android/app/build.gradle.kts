import java.util.Properties

plugins {
    id("com.android.application")
    id("kotlin-android")
    id("dev.flutter.flutter-gradle-plugin")
}

val keystoreProperties = Properties()
val keystorePropertiesFile = rootProject.file("key.properties")
if (keystorePropertiesFile.exists()) {
    keystorePropertiesFile.inputStream().use(keystoreProperties::load)
}
val releaseStoreFile = keystoreProperties.getProperty("storeFile")
    ?.takeIf(String::isNotBlank)
    ?.let(rootProject::file)
    ?.takeIf { it.isFile }
val hasReleaseSigning = releaseStoreFile != null &&
    listOf("keyAlias", "keyPassword", "storePassword").all {
        !keystoreProperties.getProperty(it).isNullOrBlank()
    }

android {
    namespace = "com.blue.segmeris"
    compileSdk = 37
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    sourceSets {
        getByName("main") {
            java.srcDirs("src/main/kotlin", "src/main/java")
        }
    }

    defaultConfig {
        applicationId = "com.blue.segmeris"
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"

    }

    signingConfigs {
        if (hasReleaseSigning) {
            create("release") {
                keyAlias = keystoreProperties.getProperty("keyAlias")
                keyPassword = keystoreProperties.getProperty("keyPassword")
                storeFile = releaseStoreFile
                storePassword = keystoreProperties.getProperty("storePassword")
            }
        }
    }

    buildTypes {
        release {
            signingConfig = signingConfigs.getByName(
                if (hasReleaseSigning) "release" else "debug"
            )
            
            // Keep MediaTranscoder class from being stripped by R8
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro"
            )
        }
    }

    lint {
        abortOnError = false
        checkReleaseBuilds = false
        disable.addAll(listOf("LintVital", "LintVitalRelease"))
    }
}

dependencies {
    testImplementation("junit:junit:4.13.2")
    androidTestImplementation("androidx.test.ext:junit:1.2.1")
    androidTestImplementation("androidx.test:runner:1.6.2")
    // Flutter integration_test also resolves these on the debug runtime classpath.
    debugImplementation("androidx.test.ext:junit:1.2.1")
    debugImplementation("androidx.test:runner:1.6.2")
    implementation("androidx.core:core-ktx:1.15.0")
}

flutter {
    source = "../.."
}
