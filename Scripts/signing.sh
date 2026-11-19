#!/bin/bash
#
# Signing keys live in 1Password, read through its CLI (`op`), never in a
# repository. Each key is one item in the vault (SIGNING_VAULT, "Game
# Signing" by default) holding the keystore file (`keystore`), its password
# (`password`, the store's and the key's), its alias (`alias`) and the
# certificate's SHA-1 (`sha1`), which is what Google's consoles ask for.
#
#   Scripts/signing.sh store <item> <keystore> [alias]
#       Saves a keystore as <item>, its password read from SIGNING_PASSWORD
#       (or asked for), its SHA-1 worked out with keytool. Refuses an item
#       that already exists.
#   Scripts/signing.sh fetch <item> <out>
#       Writes the keystore to <out> (mode 600) and checks its SHA-1 against
#       the item's; prints nothing else.
#   Scripts/signing.sh password <item>   prints the password
#   Scripts/signing.sh alias <item>      prints the alias
#   Scripts/signing.sh sha1 <item>       prints the SHA-1 the item records
#   Scripts/signing.sh debug [item]
#       Makes sure ~/.android/debug.keystore is the shared debug key: fetched
#       from <item> ("Android Debug Keystore") only when it's missing, so
#       debug builds don't ask 1Password (and Touch ID) every time. Its
#       password is Android's public "android".
#
# A release build calls `fetch` and `password` when it signs, then deletes
# the keystore it fetched; nothing secret stays on disk or in the build's
# logs. `op` signs in through the 1Password app (Settings → Developer →
# Integrate with 1Password CLI), so the first read in a while asks for
# Touch ID, unless a service account reads instead: everything but `store`
# reads with OP_SERVICE_ACCOUNT_TOKEN when it's set, else with the token kept
# in the macOS Keychain under the service SIGNING_TOKEN_SERVICE
# ("op-service-account-game-signing" by default), so builds never prompt.
# Give that account read access to the vault alone. `store` writes, so it
# always signs in through the 1Password app.

set -euo pipefail

VAULT="${SIGNING_VAULT:-Game Signing}"
DEBUG_ITEM="Android Debug Keystore"
DEBUG_KEYSTORE="$HOME/.android/debug.keystore"

die() { echo "signing.sh: $*" >&2; exit 1; }

command -v op >/dev/null || die "the 1Password CLI isn't installed (brew install --cask 1password-cli)"

# Reads go through the service account when there is one.
if [ "${1:-}" != store ] && [ -z "${OP_SERVICE_ACCOUNT_TOKEN:-}" ] && command -v security >/dev/null; then
    token="$(security find-generic-password -s "${SIGNING_TOKEN_SERVICE:-op-service-account-game-signing}" -w 2>/dev/null || true)"
    [ -n "$token" ] && export OP_SERVICE_ACCOUNT_TOKEN="$token"
    unset token
fi
[ "${1:-}" = store ] && unset OP_SERVICE_ACCOUNT_TOKEN

field() { op read --no-newline "op://$VAULT/$1/$2"; }

# The SHA-1 of a keystore's (only, or named) key.
keystore_sha1() {
    local keystore="$1" alias="${3:-}"
    local args=(-list -v -keystore "$keystore" -storepass:env SIGNING_KEYTOOL_PASSWORD)
    [ -n "$alias" ] && args+=(-alias "$alias")
    SIGNING_KEYTOOL_PASSWORD="$2" keytool "${args[@]}" 2>/dev/null | awk '/SHA1:/ { print $2; exit }'
}

keystore_alias() {
    SIGNING_KEYTOOL_PASSWORD="$2" keytool -list -keystore "$1" -storepass:env SIGNING_KEYTOOL_PASSWORD 2>/dev/null \
        | awk -F, '/PrivateKeyEntry/ { print $1; exit }'
}

fetch() {
    local item="$1" out="$2"
    mkdir -p "$(dirname "$out")"
    (umask 077; op read --force --out-file "$out" "op://$VAULT/$item/keystore" >/dev/null)
    local password alias want got
    password="$(field "$item" password)"
    alias="$(field "$item" alias)"
    want="$(field "$item" sha1)"
    got="$(keystore_sha1 "$out" "$password" "$alias")"
    if [ "$got" != "$want" ]; then
        rm -f "$out"
        die "$item: the keystore's SHA-1 ($got) isn't the one recorded ($want)"
    fi
}

case "${1:-}" in
    store)
        [ $# -ge 3 ] || die "usage: store <item> <keystore> [alias]"
        item="$2" keystore="$3" alias="${4:-}"
        [ -f "$keystore" ] || die "no keystore at $keystore"
        if op item get "$item" --vault "$VAULT" >/dev/null 2>&1; then
            die "$item is already in $VAULT"
        fi
        password="${SIGNING_PASSWORD:-}"
        if [ -z "$password" ]; then
            read -r -s -p "Password for $keystore: " password; echo >&2
        fi
        [ -n "$alias" ] || alias="$(keystore_alias "$keystore" "$password")"
        sha1="$(keystore_sha1 "$keystore" "$password" "$alias")"
        [ -n "$sha1" ] || die "couldn't read $keystore with that password"
        # The password goes in on stdin, never on a command line.
        SIGNING_ITEM="$item" SIGNING_PASSWORD="$password" SIGNING_ALIAS="$alias" SIGNING_SHA1="$sha1" \
            python3 -c 'import json, os; e = os.environ; print(json.dumps({"title": e["SIGNING_ITEM"], "category": "PASSWORD", "fields": [
                {"id": "password", "type": "CONCEALED", "purpose": "PASSWORD", "label": "password", "value": e["SIGNING_PASSWORD"]},
                {"id": "alias", "type": "STRING", "label": "alias", "value": e["SIGNING_ALIAS"]},
                {"id": "sha1", "type": "STRING", "label": "sha1", "value": e["SIGNING_SHA1"]}]}))' \
            | op item create --vault "$VAULT" >/dev/null
        op item edit "$item" --vault "$VAULT" "keystore[file]=$keystore" >/dev/null
        echo "$item: stored ($alias, SHA-1 $sha1)"
        ;;
    fetch)
        [ $# -eq 3 ] || die "usage: fetch <item> <out>"
        fetch "$2" "$3"
        ;;
    password|alias|sha1)
        [ $# -eq 2 ] || die "usage: $1 <item>"
        field "$2" "$1"
        ;;
    debug)
        item="${2:-$DEBUG_ITEM}"
        [ -f "$DEBUG_KEYSTORE" ] || fetch "$item" "$DEBUG_KEYSTORE"
        ;;
    *)
        sed -n '3,30p' "$0" | sed 's/^# \{0,1\}//'
        exit 2
        ;;
esac
