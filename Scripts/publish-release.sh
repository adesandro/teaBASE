#!/usr/bin/env -S pkgx +gh +gum +create-dmg +npx +rustup +xz bash -eo pipefail

cd "$(dirname "$0")"/..

if ! test "$APPLE_PASSWORD"; then
  echo "\$APPLE_PASSWORD must be set to an Apple App Specific Password"
  exit 1
fi
if ! test "$APPLE_USERNAME"; then
  echo "\$APPLE_USERNAME must be set to the Apple ID for the \$APPLE_PASSWORD"
  exit 2
fi

if ! git diff-index --quiet HEAD --; then
  echo "error: dirty working tree" >&2
  exit 1
fi

if [ "$(git rev-parse --abbrev-ref HEAD)" != main ]; then
  echo "error: requires main branch" >&2
  exit 1
fi

if test "$VERBOSE"; then
  set -x
fi

# ensure we have the latest version tags
git fetch origin -pft

# ensure github tags the right release
git push origin main

versions="$(git tag | grep '^v[0-9]\+\.[0-9]\+\.[0-9]\+')"
v_latest="$(npx --yes -- semver --include-prerelease $versions | tail -n1)"

case $1 in
clobber)
  v_new=$v_latest
  ;;
major|minor|patch|prerelease)
  v_new=$(npx -- semver bump $v_latest --increment $1)
  ;;
"")
  echo "usage $0 <major|minor|patch|prerelease|VERSION>" >&2
  exit 1;;
*)
  if test "$(npx --yes -- semver """$1""")" != "$1"; then
    echo "$1 doesn't look like valid semver."
    exit 1
  fi
  v_new=$1
  ;;
esac

if [ $v_new = $v_latest ] && [ "$1" != clobber ]; then
  echo "$v_new already exists!" >&2
  exit 1
fi

if [ "$1" == clobber ]; then
  true
elif ! gh release view v$v_new >/dev/null 2>&1; then
  gum confirm "prepare draft release for $v_new?" || exit 1

  gh release create \
    v$v_new \
    --draft=true \
    --generate-notes \
    --notes-start-tag=v$v_latest \
    --title=v$v_new
else
  gum format "> existing $v_new release found, using that"
  echo  #spacer
fi

tmp_xcconfig="$(mktemp)"
echo "MARKETING_VERSION = $v_new" > "$tmp_xcconfig"

xcodebuild \
  -scheme teaBASE \
  -configuration Release \
  -xcconfig "$tmp_xcconfig" \
  -derivedDataPath ./Build \
  -destination "generic/platform=macOS" \
  ARCHS="x86_64 arm64" \
  EXCLUDED_ARCHS="" \
  build

BPB_DIR="$PWD/Build/Build/Intermediates.noindex/teaBASE.build/Release/teaBASE.build/DerivedSources/bpb"
pushd "$BPB_DIR"
rustup target add x86_64-apple-darwin
~/.cargo/bin/cargo build --release --target x86_64-apple-darwin
popd

lipo -create \
  -output ./Build/Build/Products/Release/teaBASE.prefPane/Contents/MacOS/bpb \
  "$BPB_DIR"/target/release/bpb \
  "$BPB_DIR"/target/x86_64-apple-darwin/release/bpb

curl https://pkgx.sh/Darwin/x86_64 -o ./Build/pkgx_intel

lipo -create \
  -output build/Build/Products/Release/teaBASE.prefPane/Contents/MacOS/pkgx \
  ./Build/pkgx_intel \
  ./Build/Build/Products/Release/teaBASE.prefPane/Contents/MacOS/pkgx

codesign \
  --entitlements ./Build/Build/Intermediates.noindex/teaBASE.build/Release/teaBASE.build/DerivedSources/cdto/Sources/cd_to.entitlements \
  --deep --force \
  --options runtime \
  --sign "Developer ID Application: Tea Inc. (7WV56FL599)" \
  ./Build/Build/Products/Release/teaBASE.prefPane/Contents/Resources/cd\ to.app/

codesign \
  --entitlements ./Sundries/teaBASE.entitlements \
  --deep --force \
  --options runtime \
  --sign "Developer ID Application: Tea Inc. (7WV56FL599)" \
  ./Build/Build/Products/Release/teaBASE.prefPane

rm -f teaBASE-$v_new.dmg

create-dmg \
  --volname "teaBASE v$v_new" \
  --window-size 435 435 \
  --window-pos 538 273 \
  --filesystem APFS \
  --format ULFO \
  --background ./Resources/dmg-bg@2x.png \
  --icon teaBASE.prefPane 217.5 223.5 \
  --hide-extension teaBASE.prefPane \
  --icon-size 100 \
  teaBASE-$v_new.dmg \
  ./Build/Build/Products/Release/teaBASE.prefPane

codesign \
  --force \
  --sign "Developer ID Application: Tea Inc. (7WV56FL599)" \
  ./teaBASE-$v_new.dmg

xcrun notarytool submit \
  --apple-id $APPLE_USERNAME \
  --team-id 7WV56FL599 \
  --password $APPLE_PASSWORD \
  --wait \
  ./teaBASE-$v_new.dmg

xcrun stapler staple ./teaBASE-$v_new.dmg

gh release upload --clobber v$v_new teaBASE-$v_new.dmg

gh release view v$v_new

if [ "$1" != clobber ]; then
  gum confirm "draft prepared, release $v_new?" || exit 1

  gh release edit \
    v$v_new \
    --verify-tag \
    --latest \
    --draft=false \
  --discussion-category=Announcements
fi

gh release view v$v_new --web
