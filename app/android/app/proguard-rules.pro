# youtubedl-android ships no keep rules. Its updater and models are read through
# Jackson by reflection, so shrinking must leave them alone.
-keep class com.yausername.** { *; }
-keep class com.fasterxml.jackson.** { *; }
-keepattributes Signature,*Annotation*,InnerClasses,EnclosingMethod
-dontwarn com.fasterxml.jackson.databind.**
-dontwarn java.beans.**
