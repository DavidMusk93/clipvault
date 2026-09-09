#!/bin/bash
# One-time: install ClipVault Local CA into macOS System trust so Chrome
# stops showing NET::ERR_CERT_AUTHORITY_INVALID on https://127.0.0.1:8080.
set -euo pipefail
CA="${CLIPVAULT_TLS_DIR:-$HOME/Library/Application Support/Keepsake/tls}/ca.pem"
if [ ! -f "$CA" ]; then
  echo "FAIL: missing $CA — start ClipFlowServer once so clipvault-http writes the CA" >&2
  exit 1
fi
LOGIN="$HOME/Library/Keychains/login.keychain-db"
if security add-trusted-cert -d -r trustRoot -p ssl -p basic -k "$LOGIN" "$CA"; then
  echo "OK trusted in login keychain."
else
  echo "Login keychain failed; asking for admin to install into System keychain..."
  osascript <<APPLESCRIPT
do shell script "security add-trusted-cert -d -r trustRoot -p ssl -p basic -k /Library/Keychains/System.keychain " & quoted form of "$CA" with administrator privileges
APPLESCRIPT
fi
echo "Fully quit Chrome (Cmd-Q), then open https://127.0.0.1:8080"
