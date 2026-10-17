#!/usr/bin/env bash
# Build the mobile flavor and run it in the iOS Simulator on an Apple Silicon Mac.
#
#   npm run ios:sim                      # newest booted-or-available iPhone
#   SIM="iPhone 17 Pro" npm run ios:sim  # a specific simulator by name (or UDID)
#
# Google ML Kit (@capacitor-mlkit/barcode-scanning) ships no arm64-simulator slice and its pod
# forces EXCLUDED_ARCHS=arm64 for the simulator, which makes an x86_64-only app that current
# simulator runtimes refuse to install. So this sync leaves that one plugin out (ios.includePlugins
# on a temporary copy of the config): check-in barcode scanning / photo import are unavailable in
# the simulator, typing a code still works. A device build is unaffected — run `npm run
# build:mobile` again afterwards to restore the full Podfile before archiving.
set -euo pipefail

cd "$(dirname "$0")/.."
FRONTEND="$PWD"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
DERIVED="${DERIVED:-$FRONTEND/ios/build-sim}"

echo "› Building the mobile web bundle"
VITE_MOBILE=1 npx vite build
node ../scripts/catalogue/stage-media.mjs dist

echo "› Syncing iOS without ML Kit (simulator only)"
CONFIG=capacitor.config.json
cp "$CONFIG" "$CONFIG.sim-backup"
trap 'mv -f "$FRONTEND/$CONFIG.sim-backup" "$FRONTEND/$CONFIG"' EXIT
node -e '
  const fs = require("fs")
  const cfg = JSON.parse(fs.readFileSync(process.argv[1], "utf8"))
  const pkg = JSON.parse(fs.readFileSync("package.json", "utf8"))
  const plugins = Object.keys(pkg.dependencies).filter(d =>
    fs.existsSync(`node_modules/${d}/package.json`) &&
    require(`./node_modules/${d}/package.json`).capacitor?.ios &&
    d !== "@capacitor-mlkit/barcode-scanning")
  cfg.ios = { ...cfg.ios, includePlugins: plugins }
  fs.writeFileSync(process.argv[1], JSON.stringify(cfg, null, 2))
' "$CONFIG"
npx cap sync ios

# Ad-hoc signed ("Sign to Run Locally"), no Apple account needed: an unsigned build carries no
# entitlements, and HealthKit (the watch's workout) refuses to run without its entitlement.
echo "› Building for the simulator"
xcodebuild -workspace ios/App/App.xcworkspace -scheme App -configuration Debug \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath "$DERIVED" build -quiet \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= PROVISIONING_PROFILE_SPECIFIER=""
APP="$DERIVED/Build/Products/Debug-iphonesimulator/App.app"
# The Xcode project may carry its own bundle id (a personal team needs a unique one).
BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Info.plist")"

# Pick the simulator: $SIM by name/UDID, else a booted iPhone, else the newest available iPhone.
SIMS="$(xcrun simctl list devices available -j)"
UDID="$(SIM="${SIM:-}" node -e '
  const all = Object.entries(JSON.parse(require("fs").readFileSync(0, "utf8")).devices)
    .filter(([rt]) => rt.includes("iOS"))
    .sort(([a], [b]) => b.localeCompare(a, undefined, { numeric: true }))
    .flatMap(([, ds]) => ds)
  const want = process.env.SIM
  const d = want ? all.find(x => x.udid === want || x.name === want)
    : all.find(x => x.state === "Booted" && x.name.startsWith("iPhone"))
      || all.find(x => x.name.startsWith("iPhone"))
  if (!d) { console.error("No matching iPhone simulator" + (want ? ` for "${want}"` : "")); process.exit(1) }
  console.log(d.udid)
' <<<"$SIMS")"

echo "› Launching on $UDID"
xcrun simctl boot "$UDID" 2>/dev/null || true
open -b com.apple.iphonesimulator 2>/dev/null \
  || echo "  (Simulator.app not found — the device runs headless; open it from Xcode to see it)"
xcrun simctl bootstatus "$UDID" -b >/dev/null
xcrun simctl install "$UDID" "$APP"
xcrun simctl launch "$UDID" "$BUNDLE_ID"

# A watch paired with this iPhone simulator gets the watch app too (simulators do not install it
# from the phone by themselves). Pair one with: xcrun simctl pair <watch udid> <phone udid>
WATCH="$(xcrun simctl list pairs -j | node -e '
  const pairs = Object.values(JSON.parse(require("fs").readFileSync(0, "utf8")).pairs)
  const p = pairs.find(p => p.phone.udid === process.argv[1])
  if (p) console.log(p.watch.udid)
' "$UDID")"
if [ -n "$WATCH" ] && [ -d "$APP/Watch/openGym.app" ]; then
  echo "› Installing the watch app on $WATCH"
  xcrun simctl boot "$WATCH" 2>/dev/null || true
  xcrun simctl bootstatus "$WATCH" -b >/dev/null
  xcrun simctl install "$WATCH" "$APP/Watch/openGym.app"
  xcrun simctl launch "$WATCH" "$BUNDLE_ID.watchkitapp" >/dev/null || true
fi
