#!/usr/bin/env bash
# release.sh <version> — publish a claudacity release from this Mac: bump the
# version, build the arm64 and x86_64 binaries, push the release commit and tag
# to origin/main, and upload both binaries to a GitHub release. Run it from a
# clean checkout of origin/main; nothing here uses GitHub Actions.
set -euo pipefail

REPO="raineorshine/claudacity"
VERSION="${1:?usage: scripts/release.sh <version>, e.g. 1.0.0}"
VERSION="${VERSION#v}"
TAG="v${VERSION}"

die() { echo "❌  $*" >&2; exit 1; }

cd "$(git rev-parse --show-toplevel)"

[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "version must look like 1.2.3, got $VERSION"
git fetch -q origin main --tags
[ -z "$(git status --porcelain --untracked-files=no)" ] || die "uncommitted changes"
[ "$(git rev-parse HEAD)" = "$(git rev-parse origin/main)" ] || die "HEAD is not origin/main; ship first"
if git rev-parse -q --verify "refs/tags/$TAG" >/dev/null; then die "tag $TAG already exists"; fi
PREV=$(git describe --tags --abbrev=0 --match 'v[0-9]*' 2>/dev/null || true)

# Bump the two version strings marked `x-release-version`.
sed -i '' -E "s/^(    \.version = \")[^\"]+(\", \/\/ x-release-version)$/\1${VERSION}\2/" build.zig.zon
sed -i '' -E "s/^(const VERSION = \")[^\"]+(\"; \/\/ x-release-version)$/\1${VERSION}\2/" src/main.zig
grep -q "\"${VERSION}\", // x-release-version" build.zig.zon || die "build.zig.zon version not bumped"
grep -q "\"${VERSION}\"; // x-release-version" src/main.zig || die "src/main.zig VERSION not bumped"

# Release notes: the feat and fix commits since the last release.
RANGE="${PREV:+$PREV..}HEAD"
NOTES=$(git log --no-merges --format='* %s (%h)' "$RANGE" | grep -E '^\* (feat|fix)(\(.*\))?!?:' || true)
[ -n "$NOTES" ] || NOTES="* maintenance release"
{
  echo "# Changelog"
  echo
  echo "## [${VERSION}](https://github.com/${REPO}/compare/${PREV:-$TAG}...${TAG}) ($(date +%Y-%m-%d))"
  echo
  echo "$NOTES"
  tail -n +2 CHANGELOG.md
} >CHANGELOG.md.new
mv CHANGELOG.md.new CHANGELOG.md

# Build both binaries before anything is pushed. A cross build has no SDK
# paths of its own, so both get the macOS SDK as --sysroot (build.zig).
SDK=$(xcrun --show-sdk-path)
OUT=$(mktemp -d)
ASSETS=()
for ARCH in aarch64 x86_64; do
  echo "➜   Building ${ARCH}..."
  zig build -Doptimize=ReleaseSmall -Dtarget="${ARCH}-macos" --sysroot "$SDK" --prefix "$OUT/$ARCH"
  ASSET="$OUT/claudacity-${ARCH}-apple-darwin"
  cp "$OUT/$ARCH/bin/claudacity" "$ASSET"
  GOT=$(arch "-${ARCH/aarch64/arm64}" "$ASSET" --version)
  [ "$GOT" = "claudacity ${VERSION}" ] || die "${ARCH} binary reports '$GOT'"
  ASSETS+=("$ASSET")
done

git commit -q -m "chore: release ${TAG}" -- build.zig.zon src/main.zig CHANGELOG.md
git tag "$TAG"
git push --atomic origin HEAD:main "$TAG"

gh release create "$TAG" "${ASSETS[@]}" --repo "$REPO" --title "$TAG" --notes "$NOTES"
rm -rf "$OUT"
echo "✅  ${TAG} released: https://github.com/${REPO}/releases/tag/${TAG}"
