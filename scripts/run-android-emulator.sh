#!/usr/bin/env bash
set -euo pipefail
source build.env
export ANDROID_AVD_HOME="$RUNNER_TEMP/android-avd"
mkdir -p "$ANDROID_AVD_HOME"
echo no | avdmanager create avd --force \
  --name ort-packaging-smoke \
  --package "system-images;android-$ANDROID_TARGET_SDK;google_apis;x86_64" \
  --path "$ANDROID_AVD_HOME/ort-packaging-smoke.avd" \
  --device medium_phone
available_avds="$("$ANDROID_HOME/emulator/emulator" -list-avds)"
grep -Fqx 'ort-packaging-smoke' <<<"$available_avds" || {
  printf 'Created AVD was not visible to the emulator. Available AVDs:\n%s\n' "$available_avds" >&2
  exit 1
}
[ ! -e /dev/kvm ] || sudo chmod 666 /dev/kvm
emulator_log="$RUNNER_TEMP/android-emulator.log"
export ANDROID_SERIAL=emulator-5554
dump_emulator_diagnostics() {
  echo "--- Android emulator diagnostics ---" >&2
  adb devices -l >&2 || true
  tail -n 300 "$emulator_log" >&2 || true
}
cleanup_emulator() {
  status=$?
  trap - EXIT
  if [ "$status" -ne 0 ]; then
    dump_emulator_diagnostics
  fi
  timeout 10 adb emu kill >/dev/null 2>&1 || true
  exit "$status"
}
trap cleanup_emulator EXIT
adb start-server
nohup "$ANDROID_HOME/emulator/emulator" \
  -avd ort-packaging-smoke \
  -port 5554 \
  -no-window -noaudio -no-boot-anim -no-snapshot \
  -gpu swiftshader >"$emulator_log" 2>&1 &
timeout 180 adb wait-for-device
boot_deadline=$((SECONDS + 600))
while [ "$(adb shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" != 1 ]; do
  [ "$SECONDS" -lt "$boot_deadline" ] || exit 1
  sleep 5
done
timeout 300 scripts/test-android-runtime.sh x86_64
