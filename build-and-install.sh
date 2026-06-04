#!/usr/bin/env bash
set -euo pipefail

# Builds the signed non-root release APK via the flake and installs it on a
# connected device over adb. Pass extra args through to `adb` device selection,
# e.g. `./build-and-install.sh -s <serial>`.

repo_root="$(git rev-parse --show-toplevel)"
cd "$repo_root"

apk="$repo_root/app-nonRoot-release-signed.apk"
package="com.limelight.unofficial"

# Resolve adb: prefer one from the flake's pinned SDK, fall back to PATH.
sdk="$(nix eval --raw .#packages."$(nix eval --impure --raw --expr builtins.currentSystem)".androidSdk 2>/dev/null)/libexec/android-sdk"
if [ -x "$sdk/platform-tools/adb" ]; then
	adb="$sdk/platform-tools/adb"
elif command -v adb >/dev/null 2>&1; then
	adb="$(command -v adb)"
else
	echo "error: adb not found (neither in the pinned SDK nor on PATH)" >&2
	exit 1
fi

# Persistent signing key so installs stay upgrade-compatible (no reinstall, no
# data loss). The keystore and its passwords live in gitignored files. Override
# any of KEYSTORE/KEY_ALIAS/KEYSTORE_PASS/KEY_PASS via the environment to use a
# different key.
keystore_env="$repo_root/keystore.env"
if [ ! -f "$keystore_env" ]; then
	echo ">> No keystore.env found, generating a persistent local signing key"
	ks="$repo_root/release.keystore"
	alias="moonlight"
	pass="$(head -c 32 /dev/urandom | base64 | tr -dc 'A-Za-z0-9')"
	pass="${pass:0:24}"
	nix shell nixpkgs#jdk17 -c keytool -genkeypair -v \
		-keystore "$ks" -alias "$alias" \
		-keyalg RSA -keysize 2048 -validity 10000 \
		-storepass "$pass" -keypass "$pass" \
		-dname "CN=Moonlight Local Build"
	umask 077
	cat >"$keystore_env" <<EOF
KEYSTORE=$ks
KEY_ALIAS=$alias
KEYSTORE_PASS=$pass
KEY_PASS=$pass
EOF
fi

set -a
# shellcheck source=/dev/null
. "$keystore_env"
set +a

echo ">> Building signed APK"
nix run .#build

echo ">> Waiting for an adb device"
"$adb" "$@" wait-for-device

echo ">> Installing $apk"
if ! "$adb" "$@" install -r "$apk"; then
	echo ">> Reinstall failed (likely a signing-key mismatch with an existing install)." >&2
	echo ">> Uninstalling $package and retrying a clean install." >&2
	"$adb" "$@" uninstall "$package" || true
	"$adb" "$@" install "$apk"
fi

echo ">> Launching $package"
"$adb" "$@" shell monkey -p "$package" -c android.intent.category.LAUNCHER 1 >/dev/null

echo ">> Done"
