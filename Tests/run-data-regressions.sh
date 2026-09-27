#!/bin/sh
set -eu
project_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
test_output=$(mktemp -d /tmp/imnu-academic-checks.XXXXXX)
trap 'rm -rf "$test_output"' EXIT HUP INT TERM
cd "$project_dir"
swiftc -swift-version 6 -parse-as-library \
  -target "$(uname -m)-apple-macosx14.0" -sdk "$(xcrun --sdk macosx --show-sdk-path)" \
  Sources/IMNUScheduleFloat/Models.swift \
  Sources/IMNUScheduleFloat/ScheduleStore.swift \
  Sources/IMNUScheduleFloat/CredentialStore.swift \
  Sources/IMNUScheduleFloat/CookieVault.swift \
  Tests/AcademicDataRegression.swift \
  -o "$test_output/academic-data-regression"
"$test_output/academic-data-regression"
node Tests/PortalSnapshotRegression.cjs
node Tests/WindowsDataRegression.cjs
