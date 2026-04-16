#!/bin/bash
# Generate self-signed TLS certificates for development.
# For production, use Let's Encrypt / certbot instead.
#
# Usage: bash gen-certs.sh [hostname]
#   hostname defaults to localhost

set -e

HOSTNAME="${1:-localhost}"
CERT_DIR="$(dirname "$0")/certs"

mkdir -p "$CERT_DIR"

openssl req -x509 -nodes -days 365 \
  -newkey rsa:2048 \
  -keyout "$CERT_DIR/key.pem" \
  -out "$CERT_DIR/cert.pem" \
  -subj "/CN=$HOSTNAME" \
  -addext "subjectAltName=DNS:$HOSTNAME,DNS:localhost,IP:127.0.0.1,IP:10.0.2.2"

echo ""
echo "[ok] Certificates generated in $CERT_DIR"
echo "  cert.pem — server certificate"
echo "  key.pem  — private key"
echo ""
echo "⚠ Self-signed: clients must pin this cert or accept the warning."
