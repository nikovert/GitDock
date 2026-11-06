#!/bin/zsh

set -euo pipefail

repo_root="${0:A:h:h}"
cd "$repo_root"

package_path="Packages/GitDockCore"
sdk_path="$(xcrun --sdk macosx --show-sdk-path)"
bin_path="$(swift build --package-path "$package_path" --show-bin-path)"

swift build --package-path "$package_path" --target GitDockCore
swift run --package-path "$package_path" GitDockCoreChecks

# Locate the emitted module after building, including on a fresh checkout.
module_path="$bin_path"
if [[ ! -e "$module_path/GitDockCore.swiftmodule" ]]; then
  module_path="$bin_path/Modules"
fi

rg --files GitDock -g '*.swift' -0 | xargs -0 swiftc \
  -typecheck \
  -parse-as-library \
  -swift-version 6 \
  -strict-concurrency=complete \
  -target arm64-apple-macosx14.0 \
  -sdk "$sdk_path" \
  -I "$module_path"

mkdir -p .build/checks
swiftc \
  -parse-as-library \
  -swift-version 6 \
  -strict-concurrency=complete \
  GitDock/Shared/AvatarImageCache.swift \
  GitDockChecks/AvatarImageCacheCheck.swift \
  -framework AppKit \
  -framework Combine \
  -o .build/checks/avatar-image-cache-check
.build/checks/avatar-image-cache-check

swiftc \
  -parse-as-library \
  -swift-version 6 \
  -strict-concurrency=complete \
  GitDock/StatusItem/StatusMenuSizing.swift \
  GitDockChecks/StatusMenuSizingCheck.swift \
  -o .build/checks/status-menu-sizing-check
.build/checks/status-menu-sizing-check

plutil -lint GitDock/Resources/Info.plist
xcodegen generate
