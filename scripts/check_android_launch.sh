#!/usr/bin/env bash
# CI only: install the signed release on a disposable emulator and reach Home
# from a cold process in both system appearances.
set -euo pipefail
apk=${1:?expected path to signed x86_64 APK}
export ANDROID_SERIAL=emulator-5564
sdk=${ANDROID_HOME:?}
export PATH="$sdk/cmdline-tools/latest/bin:$sdk/platform-tools:$PATH"
image='system-images;android-35;google_apis;x86_64'
sdkmanager 'platform-tools' 'emulator' "$image" >/dev/null
export ANDROID_AVD_HOME="$RUNNER_TEMP/segmeris-avd"
mkdir -p "$ANDROID_AVD_HOME"
echo no | avdmanager create avd --name segmeris --package "$image" --device pixel_6 >/dev/null
sudo setfacl -m "u:$(id -un):rw" /dev/kvm
"$sdk/emulator/emulator" -avd segmeris -port 5564 -no-window -no-audio -no-boot-anim \
  -no-snapshot -gpu swiftshader_indirect >"$RUNNER_TEMP/emulator.log" 2>&1 &
emulator_pid=$!
trap 'kill "$emulator_pid" 2>/dev/null || true' EXIT
timeout 150 adb wait-for-device
timeout 180 bash -c 'until [[ $(adb shell getprop sys.boot_completed | tr -d "\r") == 1 ]]; do sleep 2; done'
adb shell input keyevent KEYCODE_WAKEUP
adb shell wm dismiss-keyguard
adb install "$apk"
for mode in no yes; do
  adb shell cmd uimode night "$mode"
  adb shell am start -S -W -n com.blue.segmeris/.MainActivity
  ready=false
  for _ in {1..10}; do
    if adb shell uiautomator dump /data/local/tmp/segmeris-home.xml >/dev/null &&
       adb shell cat /data/local/tmp/segmeris-home.xml | grep 'segmeris.settings' >/dev/null; then
      ready=true
      break
    fi
    sleep 1
  done
  if [[ "$ready" != true ]]; then
    adb logcat -d -s AndroidRuntime:E flutter:E
    exit 1
  fi
done
