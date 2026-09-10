#!/usr/bin/env bash
# Install a headless Chrome for SiteProfiles::LocalBrowser.
#
# For Render's NATIVE Ruby environment, which is what this service uses: the
# Dockerfile installs chromium and chromium-driver, but a native service never
# builds it, so nothing was installed and every scan of a walled site failed
# with the browser unable to start. There is no root and no apt here, so the
# binaries are downloaded into the project directory, which is what persists
# into the running service.
#
# Add to the Render Build Command, before bundle install:
#   ./bin/install-chrome.sh && bundle install
#
# Idempotent: a build that already has the binaries re-uses them.
set -euo pipefail

DEST="${CHROME_INSTALL_DIR:-$(pwd)/vendor/chrome}"
CHANNEL="${CHROME_CHANNEL:-Stable}"
PLATFORM="linux64"

if [ -x "$DEST/chrome-headless-shell-$PLATFORM/chrome-headless-shell" ] \
   && [ -x "$DEST/chromedriver-$PLATFORM/chromedriver" ]; then
  echo "chrome: already installed at $DEST"
  exit 0
fi

mkdir -p "$DEST"
cd "$DEST"

# Google's own Chrome for Testing endpoint — the same source Puppeteer uses,
# and the only one that guarantees the driver matches the browser. A mismatched
# pair is the classic cause of "cannot start browser" in a container.
ENDPOINT="https://googlechromelabs.github.io/chrome-for-testing/last-known-good-versions-with-downloads.json"
echo "chrome: resolving ${CHANNEL} build"
JSON="$(curl -fsSL "$ENDPOINT")"

url_for() {
  echo "$JSON" | ruby -rjson -e '
    data = JSON.parse(STDIN.read)
    channel, binary, platform = ARGV
    entry = data.dig("channels", channel, "downloads", binary)&.find { |d| d["platform"] == platform }
    abort("no download for #{binary} #{platform}") unless entry
    puts entry["url"]
  ' "$CHANNEL" "$1" "$PLATFORM"
}

# chrome-headless-shell rather than full chrome: it is the build meant for
# exactly this, roughly half the size, and needs fewer system libraries — which
# matters on a native environment where we cannot install any.
for BINARY in chrome-headless-shell chromedriver; do
  URL="$(url_for "$BINARY")"
  echo "chrome: downloading $BINARY"
  curl -fsSL -o "$BINARY.zip" "$URL"
  unzip -q -o "$BINARY.zip"
  rm "$BINARY.zip"
done

chmod +x "chrome-headless-shell-$PLATFORM/chrome-headless-shell" "chromedriver-$PLATFORM/chromedriver"
echo "chrome: installed in $DEST"
