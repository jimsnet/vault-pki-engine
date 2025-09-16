#!/bin/bash

set -e

# Function to display usage
usage() {
    echo "Usage: $0 -c CLIENT_NAME [-b BASE_NAME] [-t MAX_TTL]"
    echo "  -c CLIENT_NAME   Client name (mandatory)"
    echo "  -b BASE_NAME     Base name (optional, defaults to 'jimsnet')"
    echo "  -t MAX_TTL       Max TTL for root CA (optional, defaults to '87600h' - 10 years)"
    echo "                   Examples: 87600h, 175200h, 43800h"
    echo "Example: $0 -c abc"
    echo "Example: $0 -c xyz -b my-company -t 175200h"
    exit 1
}

# Default values
BASE_NAME="jimsnet"
CLIENT_NAME=""
MAX_TTL="87600h" # 10 years default

# Parse command line arguments
while getopts "c:b:t:" opt; do
    case $opt in
        c) CLIENT_NAME="$OPTARG" ;;
        b) BASE_NAME="$OPTARG" ;;
        t) MAX_TTL="$OPTARG" ;;
        *) usage ;;
    esac
done

# Validate mandatory parameters
if [ -z "$CLIENT_NAME" ]; then
    echo "Error: Client name is mandatory"
    usage
fi

# Validate TTL format (basic validation)
if ! echo "$MAX_TTL" | grep -Eq '^[0-9]+[smh]$'; then
    echo "Error: TTL must be in format like 87600h, 525600m, 31536000s"
    usage
fi

# Construct the PKI path
PKI_PATH="${BASE_NAME}_${CLIENT_NAME}_ROOT"

# Create ROOT_CERT/base_name directory
ROOT_CERT_DIR="ROOT_CERT/${BASE_NAME}"
mkdir -p "$ROOT_CERT_DIR"

echo "=== Setting up Root PKI ==="
echo "Base name: $BASE_NAME"
echo "Client name: $CLIENT_NAME"
echo "PKI path: $PKI_PATH"
echo "Max TTL: $MAX_TTL"
echo "Certificate directory: $ROOT_CERT_DIR"

# Enable PKI secrets engine for Root CA
vault secrets enable -path=$PKI_PATH pki

# Set max lease TTL for Root CA
vault secrets tune -max-lease-ttl=$MAX_TTL $PKI_PATH

# Generate Root CA certificate
echo "Generating Root CA certificate..."
CERT_FILE="${ROOT_CERT_DIR}/${BASE_NAME}_${CLIENT_NAME}_root-ca.crt"
vault write -field=certificate $PKI_PATH/root/generate/internal \
    common_name="$BASE_NAME $CLIENT_NAME Root CA" \
    issuer_name="${BASE_NAME}-${CLIENT_NAME}-root" \
    key_type=rsa \
    key_bits=4096 \
    ttl=$MAX_TTL > "$CERT_FILE"

echo "Root CA certificate saved to: $(pwd)/$CERT_FILE"

# Configure URLs for Root CA
echo "Configuring URLs for Root CA..."
vault write $PKI_PATH/config/urls \
    issuing_certificates="$VAULT_ADDR/v1/$PKI_PATH/ca" \
    crl_distribution_points="$VAULT_ADDR/v1/$PKI_PATH/crl" \
    ocsp_servers="$VAULT_ADDR/v1/$PKI_PATH/ocsp" \
    enable_templating=true

# Calculate intermediate TTL (half of root TTL)
# Extract numeric value and unit from MAX_TTL
TTL_VALUE=$(echo $MAX_TTL | sed 's/[^0-9]*//g')
TTL_UNIT=$(echo $MAX_TTL | sed 's/[0-9]*//g')
INTERMEDIATE_TTL_VALUE=$((TTL_VALUE / 2))
INTERMEDIATE_TTL="${INTERMEDIATE_TTL_VALUE}${TTL_UNIT}"

# Create a role for signing intermediate certificates
echo "Creating intermediate signing role with TTL: $INTERMEDIATE_TTL..."
vault write $PKI_PATH/roles/intermediate-signer \
    allow_any_name=true \
    enforce_hostnames=false \
    max_ttl=$INTERMEDIATE_TTL \
    key_usage="DigitalSignature,KeyCertSign,CRLSign" \
    basic_constraints_valid_for_non_ca=true \
    use_csr_common_name=true

# Verify the setup
echo "=== Root PKI Verification ==="
echo "Issuers:"
vault list $PKI_PATH/issuers
echo ""
echo "URLs config:"
vault read $PKI_PATH/config/urls
echo ""
echo "Role config:"
vault read $PKI_PATH/roles/intermediate-signer

echo "=== Root PKI Setup Complete ==="
echo "PKI path: $PKI_PATH"
echo "Root certificate: $CERT_FILE"
echo "Root CA TTL: $MAX_TTL"
echo "Intermediate signing TTL: $INTERMEDIATE_TTL"

# List the created certificate file
echo ""
echo "Certificate file created:"
ls -la "$CERT_FILE"

# Show directory structure
echo ""
echo "Directory structure:"
find ROOT_CERT -type f -name "*.crt" 2>/dev/null || echo "No certificate files found in ROOT_CERT directory"

