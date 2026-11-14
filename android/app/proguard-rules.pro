# kotlinx.serialization: keep the generated serializers of the models
-keepattributes *Annotation*, InnerClasses
-keepclassmembers class app.tonalo.android.** {
    *** Companion;
    kotlinx.serialization.KSerializer serializer(...);
}
-keep,includedescriptorclasses class app.tonalo.android.**$$serializer { *; }
