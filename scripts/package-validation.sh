#!/bin/zsh

set -euo pipefail

repo_root="${0:A:h:h}"
cd "$repo_root"

version="${GITHUBBAR_VERSION:-0.1.0}"
build_number="${GITHUBBAR_BUILD_NUMBER:-$(git rev-list --count HEAD)}"
commit="$(git rev-parse --short=12 HEAD)"
deployment_target="14.0"
build_root="${GITHUBBAR_BUILD_DIR:-$repo_root/.build/validation}"
dist_dir="${GITHUBBAR_DIST_DIR:-$repo_root/dist}"
source "$repo_root/scripts/package-paths.sh"
githubbar_validate_package_paths "$repo_root" "$build_root" "$dist_dir" "$version" "$build_number"
build_root="${build_root:A}"
dist_dir="${dist_dir:A}"
sdk_path="$(xcrun --sdk macosx --show-sdk-path)"
app_name="GitDock"
app_path="$build_root/$app_name.app"
artifact_base="$app_name-validation-$version-$commit"
archive_path="$dist_dir/$artifact_base.zip"

typeset -a core_sources app_sources cli_sources architectures
core_sources=($repo_root/Packages/GitDockCore/Sources/GitDockCore/**/*.swift(N))
app_sources=($repo_root/GitDock/**/*.swift(N))
cli_sources=($repo_root/Packages/GitDockCore/CLI/GitDockWorkspaceCLI/**/*.swift(N))
architectures=(arm64 x86_64)

if (( ${#core_sources} == 0 || ${#app_sources} == 0 || ${#cli_sources} == 0 )); then
  print -u2 "Could not locate GitDock Swift sources."
  exit 1
fi

rm -rf -- "$build_root"
mkdir -p "$build_root" "$dist_dir" "$app_path/Contents/MacOS" "$app_path/Contents/Resources"

for architecture in $architectures; do
  architecture_dir="$build_root/$architecture"
  mkdir -p "$architecture_dir"

  swiftc \
    -parse-as-library \
    -O \
    -whole-module-optimization \
    -swift-version 6 \
    -strict-concurrency=complete \
    -target "$architecture-apple-macosx$deployment_target" \
    -sdk "$sdk_path" \
    -module-name GitDockCore \
    -emit-module \
    -emit-module-path "$architecture_dir/GitDockCore.swiftmodule" \
    -emit-library \
    -static \
    "${core_sources[@]}" \
    -o "$architecture_dir/libGitDockCore.a"

  swiftc \
    -O \
    -whole-module-optimization \
    -swift-version 6 \
    -strict-concurrency=complete \
    -target "$architecture-apple-macosx$deployment_target" \
    -sdk "$sdk_path" \
    -module-name GitDock \
    -I "$architecture_dir" \
    "${app_sources[@]}" \
    "$architecture_dir/libGitDockCore.a" \
    -framework AppKit \
    -framework SwiftUI \
    -framework OSLog \
    -framework ServiceManagement \
    -o "$architecture_dir/GitDock"

  swiftc \
    -parse-as-library \
    -O \
    -whole-module-optimization \
    -swift-version 6 \
    -strict-concurrency=complete \
    -target "$architecture-apple-macosx$deployment_target" \
    -sdk "$sdk_path" \
    -module-name GitDockWorkspaceCLI \
    -I "$architecture_dir" \
    "${cli_sources[@]}" \
    "$architecture_dir/libGitDockCore.a" \
    -o "$architecture_dir/GitDockWorkspaceCLI"
done

lipo -create \
  "$build_root/arm64/GitDock" \
  "$build_root/x86_64/GitDock" \
  -output "$app_path/Contents/MacOS/GitDock"

lipo -create \
  "$build_root/arm64/GitDockWorkspaceCLI" \
  "$build_root/x86_64/GitDockWorkspaceCLI" \
  -output "$app_path/Contents/MacOS/GitDockWorkspaceCLI"

cp GitDock/Resources/Info.plist "$app_path/Contents/Info.plist"
cp GitDock/Resources/GitDock.icns "$app_path/Contents/Resources/GitDock.icns"
cp docs/releases/validation-release.md "$app_path/Contents/Resources/VALIDATION-README.md"
cp docs/agent-chat.md "$app_path/Contents/Resources/agent-chat.md"
cp scripts/review-chat-adapter.py "$app_path/Contents/Resources/review-chat-adapter.py"

plutil -replace CFBundleExecutable -string GitDock "$app_path/Contents/Info.plist"
plutil -replace CFBundleIdentifier -string com.nikovert.githubbar "$app_path/Contents/Info.plist"
plutil -replace CFBundleName -string GitDock "$app_path/Contents/Info.plist"
plutil -replace CFBundleDisplayName -string GitDock "$app_path/Contents/Info.plist"
plutil -replace CFBundleShortVersionString -string "$version" "$app_path/Contents/Info.plist"
plutil -replace CFBundleVersion -string "$build_number" "$app_path/Contents/Info.plist"
plutil -replace LSMinimumSystemVersion -string "$deployment_target" "$app_path/Contents/Info.plist"
plutil -remove SUEnableAutomaticChecks "$app_path/Contents/Info.plist"
plutil -remove SUFeedURL "$app_path/Contents/Info.plist"
plutil -remove SUPublicEDKey "$app_path/Contents/Info.plist"

codesign --force --sign - "$app_path/Contents/MacOS/GitDockWorkspaceCLI"
codesign --force --sign - "$app_path"
codesign --verify --strict --verbose=2 "$app_path/Contents/MacOS/GitDockWorkspaceCLI"
codesign --verify --deep --strict --verbose=2 "$app_path"
plutil -lint "$app_path/Contents/Info.plist"
lipo "$app_path/Contents/MacOS/GitDock" -verify_arch arm64
lipo "$app_path/Contents/MacOS/GitDock" -verify_arch x86_64
lipo "$app_path/Contents/MacOS/GitDockWorkspaceCLI" -verify_arch arm64
lipo "$app_path/Contents/MacOS/GitDockWorkspaceCLI" -verify_arch x86_64

if strings "$app_path/Contents/MacOS/GitDock" \
  "$app_path/Contents/MacOS/GitDockWorkspaceCLI" | rg "secret-test-token|fixture-token|test-token" >/dev/null; then
  print -u2 "Validation artifact contains a test credential marker."
  exit 1
fi

rm -f "$archive_path" "$archive_path.sha256"
ditto -c -k --sequesterRsrc --keepParent "$app_path" "$archive_path"
(
  cd "$dist_dir"
  shasum -a 256 "${archive_path:t}" > "${archive_path:t}.sha256"
)

print "Created $archive_path"
print "Architectures: $(lipo -archs "$app_path/Contents/MacOS/GitDock")"
print "CLI architectures: $(lipo -archs "$app_path/Contents/MacOS/GitDockWorkspaceCLI")"
print "SHA-256: $(cut -d ' ' -f 1 "$archive_path.sha256")"
print "This validation build is ad-hoc signed and not notarized; see VALIDATION-README.md."
