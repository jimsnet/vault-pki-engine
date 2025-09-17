#!/bin/bash

set -e

# Function to display usage
usage() {
    echo "Usage: $0 -c CLIENT_NAME -v VENDOR_NAME [-b BASE_NAME] [-t MAX_TTL]"
    echo "  -c CLIENT_NAME   Client name (mandatory)"
    echo "  -v VENDOR_NAME   Vendor name (mandatory)"
    echo "  -b BASE_NAME     Base name (optional, defaults to 'jimsnet')"
    echo "  -t MAX_TTL       Max TTL for intermediate CA (optional, defaults to '43800h' - 5 years)"
    echo "Example: $0 -c abc -v vendor1"
    echo "Example: $0 -c xyz -v aws -b my-company -t 87600h"
    exit 1
}

# Default values
BASE_NAME="jimsnet"
CLIENT_NAME=""
VENDOR_NAME=""
MAX_TTL="43800h" # 5 years default

# Parse command line arguments
while getopts "c:v:b:t:" opt; do
    case $opt in
        c) CLIENT_NAME="$OPTARG" ;;
        v) VENDOR_NAME="$OPTARG" ;;
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

if [ -z "$VENDOR_NAME" ]; then
    echo "Error: Vendor name is mandatory"
    usage
fi

# Validate TTL format
if ! echo "$MAX_TTL" | grep -Eq '^[0-9]+[smh]$'; then
    echo "Error: TTL must be in format like 43800h, 262800m, 15768000s"
    usage
fi

# Construct the PKI paths
PKI_PATH_ROOT="${BASE_NAME}_${CLIENT_NAME}_ROOT"
PKI_PATH_INT="${BASE_NAME}_${CLIENT_NAME}_${VENDOR_NAME}_INT"

# Create intermediate certificate directory (changed to INT_CERTS)
INT_CERTS_DIR="INT_CERTS/${BASE_NAME}/${CLIENT_NAME}"
mkdir -p "$INT_CERTS_DIR"

echo "=== Setting up Intermediate PKI for Digital Signing ==="
echo "Base name: $BASE_NAME"
echo "Client name: $CLIENT_NAME"
echo "Vendor name: $VENDOR_NAME"
echo "Root PKI path: $PKI_PATH_ROOT"
echo "Intermediate PKI path: $PKI_PATH_INT"
echo "Max TTL: $MAX_TTL"
echo "Certificate directory: $INT_CERTS_DIR"

# Enable PKI secrets engine for Intermediate CA
vault secrets enable -path=$PKI_PATH_INT pki
vault secrets tune -max-lease-ttl=$MAX_TTL $PKI_PATH_INT

# Generate CSR for Intermediate CA
echo "Generating Intermediate CA CSR..."
CSR_FILE="${INT_CERTS_DIR}/${BASE_NAME}_${CLIENT_NAME}_${VENDOR_NAME}.csr"
vault write -format=json $PKI_PATH_INT/intermediate/generate/internal \
    common_name="$BASE_NAME $CLIENT_NAME $VENDOR_NAME Intermediate CA" \
    issuer_name="${BASE_NAME}-${CLIENT_NAME}-${VENDOR_NAME}-intermediate" \
    key_type=rsa \
    key_bits=4096 | jq -r '.data.csr' > "$CSR_FILE"

# Check if CSR was created successfully
if [ ! -f "$CSR_FILE" ]; then
    echo "Error: CSR file was not created: $CSR_FILE"
    exit 1
fi

echo "CSR successfully created: $CSR_FILE"

# Read CSR content into variable
CSR_CONTENT=$(cat "$CSR_FILE")

# Sign the Intermediate CSR with Root CA
echo "Signing Intermediate CA certificate..."
CERT_FILE="${INT_CERTS_DIR}/${BASE_NAME}_${CLIENT_NAME}_${VENDOR_NAME}_int-ca.crt"
vault write -format=json $PKI_PATH_ROOT/root/sign-intermediate \
    csr="$CSR_CONTENT" \
    format=pem \
    ttl=$MAX_TTL \
    use_csr_values=true | jq -r '.data.certificate' > "$CERT_FILE"

# Check if certificate was created successfully
if [ ! -f "$CERT_FILE" ]; then
    echo "Error: Certificate file was not created: $CERT_FILE"
    exit 1
fi

echo "Certificate successfully created: $CERT_FILE"

# Read certificate content into variable
CERT_CONTENT=$(cat "$CERT_FILE")

# Set the signed certificate back to Intermediate CA
echo "Setting signed certificate for Intermediate CA..."
vault write $PKI_PATH_INT/intermediate/set-signed certificate="$CERT_CONTENT"

# Clean up CSR file
rm -f "$CSR_FILE"

# Configure URLs for Intermediate CA
echo "Configuring URLs for Intermediate CA..."
vault write $PKI_PATH_INT/config/urls \
    issuing_certificates="$VAULT_ADDR/v1/$PKI_PATH_INT/ca" \
    crl_distribution_points="$VAULT_ADDR/v1/$PKI_PATH_INT/crl" \
    ocsp_servers="$VAULT_ADDR/v1/$PKI_PATH_INT/ocsp" \
    enable_templating=true
	
# Set the default issuer
echo "Setting default issuer..."
ISSUER_ID=$(vault list -format=json $PKI_PATH_INT/issuers | jq -r '.[0]')
if [ -n "$ISSUER_ID" ] && [ "$ISSUER_ID" != "null" ]; then
    vault write $PKI_PATH_INT/config/issuers default="$ISSUER_ID"
else
    echo "Warning: No issuers found, skipping default issuer setup"
fi

# Update the issuer with AIA information
vault write $PKI_PATH_INT/issuer/$ISSUER_ID \
    issuing_certificates="$VAULT_ADDR/v1/$PKI_PATH_INT/ca" \
    crl_distribution_points="$VAULT_ADDR/v1/$PKI_PATH_INT/crl" \
    ocsp_servers="$VAULT_ADDR/v1/$PKI_PATH_INT/ocsp"

# Create role specifically for digital signing of reports
echo "Creating digital signing role for user certificates..."
vault write $PKI_PATH_INT/roles/digital_signing \
    allow_any_name=true \
    enforce_hostnames=false \
    server_flag=true \
    client_flag=true \
    code_signing_flag=true \
    document_signing_flag=true \
    key_usage="DigitalSignature,NonRepudiation,KeyEncipherment,DataEncipherment,KeyAgreement" \
    ext_key_usage="1.3.6.1.5.5.7.3.1,1.3.6.1.5.5.7.3.2,1.3.6.1.5.5.7.3.3,1.3.6.1.5.5.7.3.4,1.3.6.1.4.1.311.10.3.12" \
    max_ttl=8760h \
    use_csr_common_name=true \
    no_store=false

# Verify the setup
echo "=== Intermediate PKI Verification ==="
echo "Issuers:"
vault list $PKI_PATH_INT/issuers
echo ""
echo "URLs config:"
vault read $PKI_PATH_INT/config/urls
echo ""
echo "Digital signing role config:"
vault read $PKI_PATH_INT/roles/digital_signing

echo "=== Intermediate PKI Setup Complete ==="
echo "Intermediate PKI path: $PKI_PATH_INT"
echo "Intermediate certificate: $CERT_FILE"

# List the created certificate files
echo ""
echo "Certificate files created:"
ls -la "$CERT_FILE"

# Show directory structure
echo ""
echo "Directory structure:"
find INT_CERTS -type f -name "*.crt" 2>/dev/null || echo "No intermediate files found"
