#!/usr/bin/env bash
# Runs the test suite. With full Xcode this is plain `swift test`. With only the Command Line
# Tools installed, SwiftPM needs explicit search paths for the bundled Swift Testing framework.
set -euo pipefail
cd "$(dirname "$0")/.."

developer_dir="$(xcode-select -p)"
extra=()
if [[ "$developer_dir" == *CommandLineTools* ]]; then
  frameworks="$developer_dir/Library/Developer/Frameworks"
  libs="$developer_dir/Library/Developer/usr/lib"
  extra=(
    -Xswiftc -F -Xswiftc "$frameworks"
    -Xlinker -F -Xlinker "$frameworks"
    -Xlinker -rpath -Xlinker "$frameworks"
    -Xlinker -rpath -Xlinker "$libs"
  )
fi

swift test ${extra[@]+"${extra[@]}"} "$@"
