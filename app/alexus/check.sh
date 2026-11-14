#!/bin/zsh
set -euo pipefail
cd "${0:A:h}"
xcodegen generate
xcodebuild -project ALEXUS.xcodeproj -scheme ALEXUSMac -configuration Debug -derivedDataPath build -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO CURRENT_PROJECT_VERSION="${ALEXUS_BUILD_NUMBER:-1}" ALEXUS_CANONICAL_SOURCE_ROOT="${ALEXUS_SOURCE_ROOT:-$PWD}" test
xcodebuild -project ALEXUS.xcodeproj -scheme ALEXUSiOS -configuration Debug -derivedDataPath build -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO CURRENT_PROJECT_VERSION="${ALEXUS_BUILD_NUMBER:-1}" ALEXUS_CANONICAL_SOURCE_ROOT="${ALEXUS_SOURCE_ROOT:-$PWD}" build
python3 -I Host/check_host.py
python3 -I Host/check_remote.py
python3 -I Host/check_chat.py
python3 -I Host/check_deployments.py
python3 -I Host/check_transport.py
