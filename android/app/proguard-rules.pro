# TensorFlow Lite Keep Rules
-keep class org.tensorflow.lite.** { *; }
-dontwarn org.tensorflow.lite.**

# TensorFlow Lite GPU optional delegate missing classes
-dontwarn org.tensorflow.lite.gpu.**

# YellowSense Biometric SDK & Models
-keep class com.yellowsense.sdk.** { *; }
-dontwarn com.yellowsense.sdk.**
-keep class com.yellowsense.uidai_app.** { *; }
-dontwarn com.yellowsense.uidai_app.**

# Flutter and Plugin Channel Bindings
-keep class io.flutter.** { *; }
-dontwarn io.flutter.**
-keep class io.flutter.plugin.** { *; }
-dontwarn io.flutter.plugin.**

# Coroutines and Common Android Dependencies
-dontwarn kotlinx.coroutines.**
