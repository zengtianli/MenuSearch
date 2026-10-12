#!/bin/bash
# Read-only preflight, also run by Xcode before compiling. No third-party Python packages needed.
set -euo pipefail
cd "$(dirname "$0")"
python3 - <<'PY'
import json, pathlib, plistlib, re, struct, sys

root = plistlib.loads(pathlib.Path('../Info.plist').read_bytes())
spec = pathlib.Path('project.yml').read_text()
problems = []
version = re.search(r'^\s+MARKETING_VERSION: ["\x27]?([0-9.]+)', spec, re.M).group(1)
bundle = re.search(r'^\s+PRODUCT_BUNDLE_IDENTIFIER: (\S+)', spec, re.M).group(1)
if version != root['CFBundleShortVersionString']:
    problems.append(f"MARKETING_VERSION is {version}, ../Info.plist is {root['CFBundleShortVersionString']}")
if bundle != root['CFBundleIdentifier']:
    problems.append('bundle identifier differs from ../Info.plist')
for key in root:
    if not re.search(r'^\s+' + re.escape(key) + ': ', spec, re.M):
        problems.append(f'Info.plist key missing: {key}')
for key, value in [('CFBundleShortVersionString', '$(MARKETING_VERSION)'), ('CFBundleVersion', '$(CURRENT_PROJECT_VERSION)')]:
    if f'{key}: {value}' not in spec:
        problems.append(f'{key} must use {value}')
if 'com.apple.security.app-sandbox: true' not in spec or 'temporary-exception' in spec:
    problems.append('sandbox must be enabled, without temporary exceptions')
if 'SWIFT_ACTIVE_COMPILATION_CONDITIONS: APP_STORE APP_LIFECYCLE_KVS' not in spec:
    problems.append('store and KVS compilation conditions missing')
if list(pathlib.Path('../Sources').rglob('*sync-conflict-*.swift')):
    problems.append('Swift synchronization conflict copies must be reconciled')
iconset = pathlib.Path('Assets.xcassets/AppIcon.appiconset')
images = json.loads((iconset / 'Contents.json').read_text())['images']
expected = {(str(size) + 'x' + str(size), scale) for size in (16, 32, 128, 256, 512) for scale in ('1x', '2x')}
if {(i['size'], i['scale']) for i in images} != expected or len(images) != 10:
    problems.append('all 10 macOS icon slots are required')
for entry in images:
    png = iconset / entry['filename']
    side = int(entry['size'].split('x')[0]) * int(entry['scale'][0])
    if not png.is_file() or struct.unpack('>II', png.read_bytes()[16:24]) != (side, side):
        problems.append(f'icon dimensions invalid: {png}')
if problems:
    print('store/check.sh: failed\n' + '\n'.join(problems), file=sys.stderr); sys.exit(1)
print(f'store/check.sh: ok (version {version}, 10 icon slots, sandbox + selected files + KVS)')
PY
