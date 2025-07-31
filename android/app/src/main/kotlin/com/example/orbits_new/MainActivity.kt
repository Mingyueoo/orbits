package com.example.orbits_new

import io.flutter.embedding.android.FlutterActivity

import io.flutter.embedding.engine.FlutterEngine // Import FlutterEngine
import androidx.annotation.NonNull // Import NonNull

//add the registration code to your MainActivity.kt file.
class MainActivity: FlutterActivity() {
    // Override configureFlutterEngine to register your plugin
    override fun configureFlutterEngine(@NonNull flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // Register your plugin here
        // The string "ble_uuid_broadcaster" MUST match the channel name
        // you used in both your Dart and Kotlin code.
        flutterEngine.plugins.add(BleUuidBroadcasterPlugin())
        flutterEngine.plugins.add(BleScanServicePlugin())
    }
}
