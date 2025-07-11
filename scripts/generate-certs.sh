#!/bin/bash

# Generate self-signed certificates for testing
# This script creates certificates for local development and testing

set -e

CERT_DIR="certs"
KEY_FILE="$CERT_DIR/server.key"
CERT_FILE="$CERT_DIR/server.crt"

echo "🔐 Generating self-signed certificates for HTTPS load balancer..."

# Create certs directory if it doesn't exist
mkdir -p "$CERT_DIR"

# Generate private key
echo "Generating private key..."
openssl genrsa -out "$KEY_FILE" 2048

# Generate certificate signing request
echo "Generating certificate signing request..."
openssl req -new -key "$KEY_FILE" -out "$CERT_DIR/server.csr" -subj "/C=US/ST=State/L=City/O=Organization/CN=localhost"

# Generate self-signed certificate
echo "Generating self-signed certificate..."
openssl x509 -req -days 365 -in "$CERT_DIR/server.csr" -signkey "$KEY_FILE" -out "$CERT_FILE"

# Set proper permissions
chmod 600 "$KEY_FILE"
chmod 644 "$CERT_FILE"

# Clean up CSR file
rm "$CERT_DIR/server.csr"

echo "✅ Certificates generated successfully!"
echo "📁 Certificate files:"
echo "   - Private key: $KEY_FILE"
echo "   - Certificate: $CERT_FILE"
echo ""
echo "⚠️  Note: These are self-signed certificates for testing only."
echo "   For production, use certificates from a trusted CA."
echo ""
echo "🚀 You can now start the load balancer with HTTPS enabled." 