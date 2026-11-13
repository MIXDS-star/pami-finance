# Plugins that are called from native/Dart code by name (JNI via jnigen) must not
# be renamed or stripped by R8. shared_preferences_android and
# path_provider_android ship without these rules; without them the release app
# fails at startup with NoSuchMethodError (seen on a real device).
-keep class io.flutter.plugins.** { *; }
-keep class dev.flutter.** { *; }
-keep class com.github.dart_lang.jni.** { *; }
-keepclassmembers class * {
    @androidx.annotation.Keep *;
}
# Kotlin coroutine continuations appear in those JNI signatures.
-keep class kotlin.coroutines.** { *; }
-keep class kotlinx.coroutines.** { *; }
