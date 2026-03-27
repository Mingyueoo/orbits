package com.example.orbitz

import io.flutter.embedding.android.FlutterActivity

import io.flutter.embedding.engine.FlutterEngine // Import FlutterEngine
import androidx.annotation.NonNull // Import NonNull
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.plugins.GeneratedPluginRegistrant

//add the registration code to your MainActivity.kt file.
class MainActivity: FlutterActivity() {
    // Override configureFlutterEngine to register your plugin
    override fun configureFlutterEngine(@NonNull flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        GeneratedPluginRegistrant.registerWith(flutterEngine)

        flutterEngine.plugins.add(BleUuidBroadcasterPlugin())
        flutterEngine.plugins.add(BleScanServicePlugin())


        // 缓存当前 FlutterEngine，供后台服务使用
        FlutterEngineCache
            .getInstance()
            .put("my_flutter_engine", flutterEngine)
    }
}
