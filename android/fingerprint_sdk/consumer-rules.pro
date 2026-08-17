# TensorFlow Lite Keep Rules
-keep class org.tensorflow.lite.** { *; }
-dontwarn org.tensorflow.lite.**

# TensorFlow Lite GPU optional delegate missing classes
-dontwarn org.tensorflow.lite.gpu.**

# YellowSense Biometric SDK & Models
-keep class com.yellowsense.sdk.** { *; }
-dontwarn com.yellowsense.sdk.**

# Coroutines
-dontwarn kotlinx.coroutines.**
