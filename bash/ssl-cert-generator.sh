#!/bin/bash
#
# SSL Certificate Generator
# -------------------------
# A utility to quickly generate self-signed SSL/TLS certificates
# for local development and testing purposes.
#

set -e

DOMAIN="localhost"
DAYS=365
OUT_DIR="."
KEY_SIZE=2048

usage() {
    echo "Usage: $0 [options]"
    echo "Options:"
    echo "  -d, --domain <domain>   Domain name (default: localhost)"
    echo "  -y, --days <days>       Validity in days (default: 365)"
    echo "  -o, --out-dir <dir>     Output directory (default: current directory)"
    echo "  -k, --key-size <size>   RSA key size (default: 2048)"
    echo "  -h, --help              Show this help message"
    exit 1
}

# Parse command line arguments
while [[ "$#" -gt 0 ]]; do
    case $1 in
        -d|--domain) DOMAIN="$2"; shift ;;
        -y|--days) DAYS="$2"; shift ;;
        -o|--out-dir) OUT_DIR="$2"; shift ;;
        -k|--key-size) KEY_SIZE="$2"; shift ;;
        -h|--help) usage ;;
        *) echo "Unknown parameter passed: $1"; usage ;;
    esac
    shift
done

if ! command -v openssl &> /dev/null; then
    echo "Error: openssl is not installed."
    exit 1
fi

mkdir -p "$OUT_DIR"

KEY_FILE="$OUT_DIR/${DOMAIN}.key"
CERT_FILE="$OUT_DIR/${DOMAIN}.crt"

echo "Generating self-signed certificate for '$DOMAIN'..."
echo "Validity: $DAYS days"
echo "Key Size: $KEY_SIZE bits"

# Generate certificate and key
openssl req -x509 \
    -nodes \
    -days "$DAYS" \
    -newkey rsa:"$KEY_SIZE" \
    -keyout "$KEY_FILE" \
    -out "$CERT_FILE" \
    -subj "/C=US/ST=State/L=City/O=LocalDev/CN=$DOMAIN" \
    2>/dev/null

if [ $? -eq 0 ]; then
    echo -e "\n✅ Success! Files generated:"
    echo "  Private Key: $KEY_FILE"
    echo "  Certificate: $CERT_FILE"
    
    chmod 600 "$KEY_FILE"
    chmod 644 "$CERT_FILE"
else
    echo -e "\n❌ Failed to generate certificate."
    exit 1
fi
