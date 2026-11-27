package co.bmlab.sidequests.sidequests

import android.content.Context
import android.hardware.Sensor
import android.hardware.SensorEvent
import android.hardware.SensorEventListener
import android.hardware.SensorManager
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterFragmentActivity() {

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        registerAmbientLightChannels(flutterEngine)
    }

    /**
     * Sensor feature (mirror of the Kotlin app's AmbientLightMonitor): streams the ambient light
     * sensor (lux) to Dart. The listener is registered only while Dart listens, and Dart only
     * listens while the app is in the foreground, so nothing runs in the background.
     * Devices without a light sensor report isAvailable = false.
     */
    private fun registerAmbientLightChannels(flutterEngine: FlutterEngine) {
        val sensorManager = getSystemService(Context.SENSOR_SERVICE) as SensorManager
        val lightSensor: Sensor? = sensorManager.getDefaultSensor(Sensor.TYPE_LIGHT)
        val messenger = flutterEngine.dartExecutor.binaryMessenger

        MethodChannel(messenger, "sidequests/ambient_light/info").setMethodCallHandler { call, result ->
            when (call.method) {
                "isAvailable" -> result.success(lightSensor != null)
                else -> result.notImplemented()
            }
        }

        EventChannel(messenger, "sidequests/ambient_light/lux").setStreamHandler(
            object : EventChannel.StreamHandler {
                private var listener: SensorEventListener? = null

                override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
                    val sensor = lightSensor
                    if (sensor == null) {
                        events.endOfStream()
                        return
                    }
                    val sensorListener = object : SensorEventListener {
                        override fun onSensorChanged(event: SensorEvent) {
                            val lux = event.values.firstOrNull() ?: return
                            events.success(lux.toDouble())
                        }

                        override fun onAccuracyChanged(sensor: Sensor?, accuracy: Int) = Unit
                    }
                    listener = sensorListener
                    sensorManager.registerListener(sensorListener, sensor, SensorManager.SENSOR_DELAY_NORMAL)
                }

                override fun onCancel(arguments: Any?) {
                    listener?.let { sensorManager.unregisterListener(it) }
                    listener = null
                }
            }
        )
    }
}
