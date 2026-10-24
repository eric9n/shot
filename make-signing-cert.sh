#!/bin/sh
# Creates the self-signed code-signing certificate "Shot Local" in your login keychain, once. build.sh then signs Shot.app
# with it, so macOS sees the same app after every rebuild and keeps its Screen Recording permission (and its login item).
# The key lives only in your keychain. macOS asks for your password to trust the certificate; that is expected.
set -e
NAME="${SHOT_SIGN_ID:-Shot Local}"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-identity -p codesigning | grep -q "\"$NAME\""; then
    echo "\"$NAME\" is already in your keychain; nothing to do."
    exit 0
fi

DIR=$(mktemp -d)
trap 'rm -rf "$DIR"' EXIT
PASS=$(/usr/bin/openssl rand -hex 12)

/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -subj "/CN=$NAME" \
    -keyout "$DIR/key.pem" -out "$DIR/cert.pem" \
    -addext "keyUsage=critical,digitalSignature" -addext "extendedKeyUsage=critical,codeSigning" 2>/dev/null
/usr/bin/openssl pkcs12 -export -inkey "$DIR/key.pem" -in "$DIR/cert.pem" -out "$DIR/id.p12" -name "$NAME" -passout "pass:$PASS"

security import "$DIR/id.p12" -k "$KEYCHAIN" -P "$PASS" -T /usr/bin/codesign
# Trust it for code signing only (macOS asks for your password here).
security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$DIR/cert.pem"

if security find-identity -v -p codesigning | grep -q "\"$NAME\""; then
    echo "Done: \"$NAME\" is ready. Run ./build.sh. The first time it signs, macOS may ask to let codesign use the key: choose Always Allow."
else
    echo "The certificate was added but is not trusted yet. Open Keychain Access, find \"$NAME\", and set Trust > Code Signing to Always Trust." >&2
    exit 1
fi
