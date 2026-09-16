#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
swift build -c release --product Lanes
swift build -c release --product LanesProxy
LANES_APP="$PWD/build/Lanes.app"
mkdir -p "$LANES_APP/Contents/MacOS" "$LANES_APP/Contents/Resources"
cp .build/release/Lanes "$LANES_APP/Contents/MacOS/Lanes"
cp .build/release/LanesProxy "$LANES_APP/Contents/MacOS/LanesProxy"
cp Resources/Info.plist "$LANES_APP/Contents/Info.plist"
codesign --force --sign - "$LANES_APP"
printf 'Built %s\n' "$LANES_APP"
