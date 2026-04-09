package com.example.example

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // Minimal handler for the platform channel demo.
        // Responds to all methods with success(null) so calls generate
        // proper VM timeline events instead of MissingPluginException.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "sleuth_demo_channel")
            .setMethodCallHandler { _, result -> result.success(null) }
    }
}
