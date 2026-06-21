# AudioCaptureMain is launched by app_process via its class name — must not be renamed.
-keep class com.voiceguard.shell.AudioCaptureMain { *; }
-keepclassmembers class com.voiceguard.shell.AudioCaptureMain {
    public static void main(java.lang.String[]);
}

# libadb-android — ADB protocol + SPAKE2 wireless pairing.
-keep class io.github.muntashirakon.adb.** { *; }
-dontwarn io.github.muntashirakon.adb.**

# Conscrypt TLS provider (required for Android 11+ wireless debugging).
-keep class org.conscrypt.** { *; }
-dontwarn org.conscrypt.**

# BouncyCastle PKIX — X509 certificate generation.
-keep class org.bouncycastle.** { *; }
-dontwarn org.bouncycastle.**

-keep class io.flutter.app.** { *; }
-keep class io.flutter.plugin.** { *; }
-keep class io.flutter.util.** { *; }
-keep class io.flutter.view.** { *; }
-keep class io.flutter.embedding.** { *; }
-keep class io.flutter.plugins.** { *; }

-keep class com.cloudwebrtc.webrtc.** { *; }
-keep class org.webrtc.** { *; }
-keep class com.llfbandit.record.** { *; }
-keep class com.simform.audio_waveforms.** { *; }

-dontwarn com.google.android.play.core.splitcompat.SplitCompatApplication
-dontwarn com.google.android.play.core.splitinstall.SplitInstallException
-dontwarn com.google.android.play.core.splitinstall.SplitInstallManager
-dontwarn com.google.android.play.core.splitinstall.SplitInstallManagerFactory
-dontwarn com.google.android.play.core.splitinstall.SplitInstallRequest$Builder
-dontwarn com.google.android.play.core.splitinstall.SplitInstallRequest
-dontwarn com.google.android.play.core.splitinstall.SplitInstallSessionState
-dontwarn com.google.android.play.core.splitinstall.SplitInstallStateUpdatedListener
-dontwarn com.google.android.play.core.tasks.OnFailureListener
-dontwarn com.google.android.play.core.tasks.OnSuccessListener
-dontwarn com.google.android.play.core.tasks.Task
