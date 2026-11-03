# Running the device benchmark on Firebase Test Lab

Uses only synthetic sheets (`app/src/androidTest/assets/bench`, made by
`training/synthetic/make_sheet.py`). Never put photos of real sheets in the
test APK: Test Lab uploads it to Google's servers.

```
./gradlew :app:assembleDebug :app:assembleDebugAndroidTest
gcloud firebase test android run --project edusignin-c3d6f --type instrumentation \
  --app app/build/outputs/apk/debug/app-universal-debug.apk \
  --test app/build/outputs/apk/androidTest/debug/app-debug-androidTest.apk \
  --device model=a03su,version=33 --device model=TECNO-BF6,version=31 --device model=a14m,version=34 \
  --test-targets "class com.eduvision.app.DeviceBenchmarkTest" --timeout 15m
```

The test logs `EduBench key=value` lines (model load times, first-scan
layout time, per-scan timings, values read). Read them from each device's
`logcat` in the results bucket the command prints:

```
gsutil cat gs://<bucket>/<run>/<device>/logcat | grep EduBench
```

The free Spark plan allows 5 physical-device test runs per day.
