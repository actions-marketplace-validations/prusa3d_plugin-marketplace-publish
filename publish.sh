#!/usr/bin/env bash
# Sign a PrusaSlicer plugin bundle and publish it to the Prusa Plugin Marketplace.
#
# 1. Read manifest.json, check the release tag against its version.
# 2. Write manifest.txt (sha256 of every file) and sign it into manifest.sig
#    with the author's RSA key - the same bytes `openssl dgst -sha256 -sign`
#    produces, which is what the marketplace and PrusaSlicer verify.
# 3. Zip the bundle flat (manifest.json at the root).
# 4. Ask GitHub for this run's OIDC token, audience = the marketplace, and
#    upload. The marketplace checks the token's repository and workflow against
#    the plugin's trusted publishers; no other credential exists.
#
# Inputs come as INPUT_* environment variables (see action.yml), so the script
# also runs outside Actions for testing.
set -euo pipefail

fail() {
  echo "::error::$*" >&2
  exit 1
}
note() { echo "$*" >&2; }
output() { if [ -n "${GITHUB_OUTPUT:-}" ]; then echo "$1=$2" >>"$GITHUB_OUTPUT"; fi; }
summary() { if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then echo "$*" >>"$GITHUB_STEP_SUMMARY"; fi; }

for tool in jq openssl zip curl; do
  command -v "$tool" >/dev/null || fail "$tool is required on the runner"
done
if command -v sha256sum >/dev/null; then
  sha256() { sha256sum "$1" | cut -d' ' -f1; }
else
  sha256() { shasum -a 256 "$1" | cut -d' ' -f1; }
fi

src="${INPUT_PATH:-.}"
marketplace="${INPUT_MARKETPLACE_URL:-https://plugin-marketplace.prusa3d.com}"
marketplace="${marketplace%/}"
[ -f "$src/manifest.json" ] || fail "no manifest.json in '$src' (set the path input to the plugin folder)"
[ -n "${INPUT_PRIVATE_KEY:-}" ] || fail "private-key is empty: pass the signing key secret, e.g. private-key: \${{ secrets.PRUSA_SLICER_PLUGIN_MARKETPLACE_SIGNING_KEY }}"

id="$(jq -er '.id' "$src/manifest.json")" || fail "manifest.json has no id"
version="$(jq -er '.version' "$src/manifest.json")" || fail "manifest.json has no version"
output plugin-id "$id"
output version "$version"
note "Plugin $id $version"

# A release tag names the version it ships. Anything before the version is a
# prefix: v1.2.0, my-plugin/v1.2.0, com.example.plugin@1.2.0.
if [ "${INPUT_CHECK_VERSION:-true}" = "true" ] && [ "${GITHUB_REF_TYPE:-}" = "tag" ]; then
  tag="${GITHUB_REF_NAME:-}"
  prefix="${tag%"$version"}"
  if [ "$prefix" = "$tag" ] || [[ -n "$prefix" && ! "$prefix" =~ (^|[/@_-])v?$ ]]; then
    fail "tag '$tag' does not match manifest.json version $version (expected e.g. v$version)"
  fi
fi

event="${GITHUB_EVENT_PATH:-}"
release_field() {
  if [ -n "$event" ] && [ -f "$event" ]; then jq -r "$1 // empty" "$event"; fi
}

channel="${INPUT_CHANNEL:-}"
if [ -z "$channel" ]; then
  channel=stable
  if [ "$(release_field '.release.prerelease')" = "true" ]; then channel=beta; fi
fi
case "$channel" in stable | beta) ;; *) fail "channel must be stable or beta, got '$channel'" ;; esac

changelog="${INPUT_CHANGELOG:-}"
[ -n "$changelog" ] || changelog="$(release_field '.release.body')"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
bundle_dir="$work/bundle"
mkdir -p "$bundle_dir"
# The bundle is the folder as committed, minus an old signature and VCS files.
(cd "$src" && tar --exclude=.git --exclude=.github --exclude=manifest.txt --exclude=manifest.sig -cf - .) |
  (cd "$bundle_dir" && tar -xf -)

(
  cd "$bundle_dir"
  find . -type f ! -name manifest.txt ! -name manifest.sig | sed 's|^\./||' | LC_ALL=C sort |
    while IFS= read -r file; do
      printf '%s  %s\n' "$(sha256 "$file")" "$file"
    done
) >"$work/manifest.txt"
mv "$work/manifest.txt" "$bundle_dir/manifest.txt"

key="$work/key.pem"
(umask 077 && printf '%s\n' "$INPUT_PRIVATE_KEY" >"$key")
key_text="$(openssl pkey -in "$key" -noout -text 2>/dev/null)" || fail "private-key is not a PEM private key"
# The marketplace registers RSA keys of 2048 bits or more only; anything else
# would sign fine here and fail verification there with a vaguer message.
grep -qi '^modulus:' <<<"$key_text" || fail "private-key must be an RSA key (the marketplace verifies RSA signatures only)"
bits="$(head -1 <<<"$key_text" | grep -o '[0-9]\+' | head -1)"
[ "${bits:-0}" -ge 2048 ] || fail "private-key must be RSA with at least 2048 bits, got ${bits:-unknown}"
openssl dgst -sha256 -sign "$key" -out "$bundle_dir/manifest.sig" "$bundle_dir/manifest.txt"
openssl pkey -in "$key" -pubout -out "$work/public.pem"
rm -f "$key"
openssl dgst -sha256 -verify "$work/public.pem" -signature "$bundle_dir/manifest.sig" \
  "$bundle_dir/manifest.txt" >/dev/null || fail "the signature does not verify against its own key"
fingerprint="$(openssl pkey -pubin -in "$work/public.pem" -outform DER | openssl dgst -sha256 -r | cut -d' ' -f1)"
note "Signed with key $fingerprint"

out_dir="${RUNNER_TEMP:-$PWD}"
bundle="$out_dir/$id@$version.zip"
rm -f "$bundle"
(cd "$bundle_dir" && zip -q -X -r "$bundle" .)
output bundle "$bundle"
note "Bundle $bundle ($(wc -c <"$bundle" | tr -d ' ') bytes)"

if [ "${INPUT_DRY_RUN:-false}" = "true" ]; then
  note "Dry run: not uploading."
  summary "### $id $version signed (dry run, not uploaded)"
  exit 0
fi

if [ -z "${ACTIONS_ID_TOKEN_REQUEST_URL:-}" ] || [ -z "${ACTIONS_ID_TOKEN_REQUEST_TOKEN:-}" ]; then
  fail "no OIDC token available: give the job 'permissions: id-token: write'"
fi
audience="$(jq -rn --arg v "$marketplace" '$v|@uri')"
token="$(curl -sSf -H "Authorization: bearer $ACTIONS_ID_TOKEN_REQUEST_TOKEN" \
  "$ACTIONS_ID_TOKEN_REQUEST_URL&audience=$audience" | jq -r '.value')" ||
  fail "could not get an OIDC token from GitHub"
echo "::add-mask::$token"

base64 <"$bundle" | tr -d '\n' >"$work/bundle.b64"
printf '%s' "$changelog" >"$work/changelog.md"
jq -n --rawfile bundle "$work/bundle.b64" --rawfile changelog "$work/changelog.md" \
  --arg channel "$channel" \
  '{bundle: $bundle, channel: $channel} + (if $changelog == "" then {} else {changelog: $changelog} end)' \
  >"$work/body.json"

status="$(curl -sS -o "$work/response.json" -w '%{http_code}' -X POST \
  -H "Authorization: Bearer $token" -H 'Content-Type: application/json' \
  --data-binary "@$work/body.json" "$marketplace/api/publish/v1/releases")" ||
  fail "could not reach $marketplace"

if [ "$status" != "201" ]; then
  message="$(jq -r '.error // empty' "$work/response.json" 2>/dev/null || true)"
  [ -n "$message" ] || message="$(head -c 500 "$work/response.json")"
  fail "the marketplace refused the release ($status): $message"
fi

url="$(jq -r '.url' "$work/response.json")"
output url "$url"
note "Published $id $version to the $channel channel; it is waiting for review: $url"
summary "### $id $version submitted to the Plugin Marketplace"
summary ""
summary "Channel \`$channel\`, signed with key \`${fingerprint:0:16}…\`. Every release is scanned and reviewed before it goes public: [follow it in the author console]($url)."
