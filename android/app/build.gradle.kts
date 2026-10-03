import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// ---------------------------------------------------------------------------
// 签名：**有 key.properties 就用正式钥匙，没有就退回 debug 签名**（S-4）。
//
// 为什么这么写：原来这里硬编码 `signingConfig = signingConfigs.getByName("debug")`
// （Flutter 模板默认），于是 release 包一律用公开的 debug keystore 签名 ——
// 谁都能用同一把 key 签一个"同应用的更新"。更麻烦的是**换签名的那一天**：
// 签名不同，Android 会拒绝覆盖安装，已装用户必须先卸载，而卸载会连私有目录里的
// 数据一起删掉。所以换签名要趁早，而这一步不该再被"还得改 gradle"挡着。
//
// 现在只需放一个 `android/key.properties`（已在 .gitignore 里，绝不入库）：
//     storeFile=<keystore 绝对路径或相对 android/ 的路径>
//     storePassword=...
//     keyAlias=...
//     keyPassword=...
// 没有这个文件时行为与以前**完全一致**（debug 签名），所以这次改动是零风险的。
// ---------------------------------------------------------------------------
val keystoreProperties = Properties()
val keystorePropertiesFile = rootProject.file("key.properties")
val hasReleaseKey = keystorePropertiesFile.exists()
if (hasReleaseKey) {
    keystorePropertiesFile.inputStream().use { keystoreProperties.load(it) }
}

android {
    namespace = "com.maker.guideline"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
        // ⚠️ 临时探针加（2026-10-03）：`flutter_local_notifications` v10+ **强制**
        // 要求脱糖 —— 它用 `java.time` 做定时，在 minSdk 24 上不打开就直接编不过
        // （插件 README 的原话是"即使用不到定时通知也要打开"）。
        // 正式保留与否，与探针结论一起决定。
        isCoreLibraryDesugaringEnabled = true
    }

    defaultConfig {
        applicationId = "com.maker.guideline"
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        if (hasReleaseKey) {
            create("release") {
                storeFile = file(keystoreProperties.getProperty("storeFile"))
                storePassword = keystoreProperties.getProperty("storePassword")
                keyAlias = keystoreProperties.getProperty("keyAlias")
                keyPassword = keystoreProperties.getProperty("keyPassword")
            }
        }
    }

    buildTypes {
        release {
            signingConfig = if (hasReleaseKey) {
                signingConfigs.getByName("release")
            } else {
                // 没有 key.properties 时保持老行为，`flutter run --release` 照旧可用
                signingConfigs.getByName("debug")
            }
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}

// ⚠️ 临时探针加（2026-10-03）：与上面 `isCoreLibraryDesugaringEnabled` 配对的
// 脱糖库本身。版本跟着 `flutter_local_notifications` README 给的那一版。
dependencies {
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
}
