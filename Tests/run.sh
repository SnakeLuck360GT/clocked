#!/bin/bash
# Compiles and runs the test programs against the app's sources (no Xcode or SwiftPM needed).
set -euo pipefail
cd "$(dirname "$0")/.."
SDK=/Library/Developer/CommandLineTools/SDKs/MacOSX26.sdk
[ -d "$SDK" ] || SDK="$(xcrun --show-sdk-path)"
SRC=Sources/Clocked
OUT=$(mktemp -d)
# Each test is a script, so it's compiled as main.swift alongside the sources it needs.
build() {
  mkdir -p "$OUT/$1.src" && cp "Tests/$1.swift" "$OUT/$1.src/main.swift"
  swiftc -O -swift-version 5 -sdk "$SDK" -o "$OUT/$1" "$OUT/$1.src/main.swift" "${@:2}"
}

build NeuralNetTests $SRC/PhoneNet.swift
build LearningSimulation $SRC/PhoneNet.swift $SRC/Learning.swift $SRC/Posture.swift $SRC/PhoneEvidence.swift $SRC/CameraMonitor.swift $SRC/AudioMonitor.swift $SRC/ActivityMonitor.swift $SRC/Interventions.swift $SRC/Storage.swift
build DetectionScenarios $SRC/PhoneEvidence.swift $SRC/Posture.swift
build HeadDownTests $SRC/Posture.swift $SRC/PhoneNet.swift
build GroupSyncTests $SRC/Groups.swift $SRC/StudyLog.swift $SRC/Storage.swift Sources/Shared/SyncProtocol.swift

status=0
for t in NeuralNetTests HeadDownTests GroupSyncTests DetectionScenarios LearningSimulation; do
  echo "== $t"
  "$OUT/$t" || status=1
done
exit $status
