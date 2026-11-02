#!/usr/bin/env bash
# Builds and signs a sample plugin with publish.sh (dry run) and checks the result
# the way the marketplace and PrusaSlicer do: openssl verifies manifest.sig over
# manifest.txt, and every file in the zip matches its checksum.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

openssl genpkey -algorithm RSA -out "$work/key.pem" -pkeyopt rsa_keygen_bits:2048 2>/dev/null
openssl pkey -in "$work/key.pem" -pubout -out "$work/pub.pem"

plugin="$work/repo/plugins/flow-tower"
mkdir -p "$plugin/assets" "$plugin/.git"
cat >"$plugin/manifest.json" <<'EOF'
{"id":"com.example.flow-tower","name":"Flow tower","version":"1.2.0","author":"00000000-0000-4000-8000-000000000000","license":"MIT","min_slicer_version":"2.9.0"}
EOF
printf -- '-- plugin\nreturn {}\n' >"$plugin/main.lua"
printf 'icon' >"$plugin/assets/icon file.png"
printf 'stale' >"$plugin/manifest.sig"
printf 'not shipped' >"$plugin/.git/HEAD"
# Only the root manifest.txt / manifest.sig are the signature's; a nested one ships.
mkdir -p "$plugin/docs" "$plugin/.github"
printf 'notes' >"$plugin/docs/manifest.txt"
# .github is not shipped, so a link in it is not followed and not refused.
ln -s /etc/hosts "$plugin/.github/hosts"

expect_fail() {
  local name="$1"
  shift
  if (cd "$work/repo" && env "$@" "$here/../publish.sh") >"$work/log" 2>&1; then
    echo "FAIL: $name should have failed" >&2
    exit 1
  fi
  echo "ok: $name ($(grep -o '::error::.*' "$work/log" | head -1))"
}

common=(INPUT_PATH=plugins/flow-tower "INPUT_PRIVATE_KEY=$(cat "$work/key.pem")" INPUT_DRY_RUN=true
  "RUNNER_TEMP=$work" "GITHUB_OUTPUT=$work/out")

(cd "$work/repo" && env "${common[@]}" GITHUB_REF_TYPE=tag GITHUB_REF_NAME=flow-tower/v1.2.0 \
  "$here/../publish.sh") 2>"$work/log"
bundle="$(grep '^bundle=' "$work/out" | cut -d= -f2-)"
[ -f "$bundle" ] || { echo "FAIL: no bundle" >&2; exit 1; }

mkdir "$work/unzipped"
(cd "$work/unzipped" && unzip -q "$bundle")
[ ! -e "$work/unzipped/.git" ] || { echo "FAIL: .git shipped" >&2; exit 1; }
openssl dgst -sha256 -verify "$work/pub.pem" -signature "$work/unzipped/manifest.sig" \
  "$work/unzipped/manifest.txt" >/dev/null
echo "ok: signature verifies"
(cd "$work/unzipped" && while IFS= read -r line; do
  sum="${line%%  *}"
  file="${line#*  }"
  if command -v sha256sum >/dev/null; then
    actual="$(sha256sum "$file" | cut -d' ' -f1)"
  else
    actual="$(shasum -a 256 "$file" | cut -d' ' -f1)"
  fi
  [ "$sum" = "$actual" ] || { echo "FAIL: checksum of $file" >&2; exit 1; }
done <manifest.txt)
lines="$(wc -l <"$work/unzipped/manifest.txt" | tr -d ' ')"
[ "$lines" = "4" ] || { echo "FAIL: manifest.txt lists $lines files, expected 4" >&2; exit 1; }
grep -q '  docs/manifest.txt$' "$work/unzipped/manifest.txt" || { echo "FAIL: docs/manifest.txt not shipped" >&2; exit 1; }
[ ! -e "$work/unzipped/.github" ] || { echo "FAIL: .github shipped" >&2; exit 1; }
echo "ok: manifest.txt covers every file"

expect_fail "tag for another version" "${common[@]}" GITHUB_REF_TYPE=tag GITHUB_REF_NAME=v1.1.0
expect_fail "tag that only ends like the version" "${common[@]}" GITHUB_REF_TYPE=tag GITHUB_REF_NAME=11.2.0
openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out "$work/ec.pem" 2>/dev/null
openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:1024 -out "$work/small.pem" 2>/dev/null
expect_fail "an EC key" "${common[@]/INPUT_PRIVATE_KEY=*/INPUT_PRIVATE_KEY=$(cat "$work/ec.pem")}"
expect_fail "a 1024-bit RSA key" "${common[@]/INPUT_PRIVATE_KEY=*/INPUT_PRIVATE_KEY=$(cat "$work/small.pem")}"
# A bundle must never carry what is outside it, or a key.
bad="$work/repo/plugins/bad"
mkdir -p "$bad"
cp "$plugin/manifest.json" "$plugin/main.lua" "$bad/"
ln -s /etc/hosts "$bad/hosts"
expect_fail "a symbolic link in the folder" "${common[@]/INPUT_PATH=*/INPUT_PATH=plugins/bad}"
rm "$bad/hosts"
cp "$work/key.pem" "$bad/private_key.pem"
expect_fail "a private key in the folder" "${common[@]/INPUT_PATH=*/INPUT_PATH=plugins/bad}"
rm "$bad/private_key.pem"
sed -i.bak 's/"com.example.flow-tower"/"..\/..\/evil"/' "$bad/manifest.json"
expect_fail "an id that is not reverse-DNS" "${common[@]/INPUT_PATH=*/INPUT_PATH=plugins/bad}"
cp "$plugin/manifest.json" "$bad/manifest.json"
sed -i.bak 's/"1.2.0"/"1.2.0\/..\/x"/' "$bad/manifest.json"
expect_fail "a version that is not semver" "${common[@]/INPUT_PATH=*/INPUT_PATH=plugins/bad}"

expect_fail "not a private key" "${common[@]/INPUT_PRIVATE_KEY=*/INPUT_PRIVATE_KEY=nope}"
expect_fail "upload without id-token permission" "${common[@]/INPUT_DRY_RUN=true/INPUT_DRY_RUN=false}"
echo "all good"
