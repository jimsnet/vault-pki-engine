#!/bin/bash
# Complete PKI Certificate Management

# Default values (can be overridden with environment variables)
BASE_NAME="${BASE_NAME:-jimsnet}"
CLIENT_NAME="${CLIENT_NAME:-client1}"
VENDOR_NAME="${VENDOR_NAME:-vendor1}"

# Construct the PKI path
PKI_PATH="${BASE_NAME}_${CLIENT_NAME}_${VENDOR_NAME}_INT"

ACTION=$1
SERIAL=$2

case $ACTION in
  list)
    echo "=== Listing All Issued Certificates ==="
    echo "PKI Path: $PKI_PATH"
    vault list $PKI_PATH/certs
    ;;
    
  view)
    if [ -z "$SERIAL" ]; then
        echo "Usage: $0 view <serial_number>"
        echo "First run '$0 list' to get serial numbers"
        exit 1
    fi
    echo "=== Viewing Certificate: $SERIAL ==="
    echo "PKI Path: $PKI_PATH"
    vault read $PKI_PATH/cert/$SERIAL
    ;;
    
  revoke)
    if [ -z "$SERIAL" ]; then
        echo "Usage: $0 revoke <serial_number>"
        echo "First run '$0 list' to get serial numbers"
        exit 1
    fi
    echo "=== Revoking Certificate: $SERIAL ==="
    echo "PKI Path: $PKI_PATH"
    vault write $PKI_PATH/revoke serial_number=$SERIAL
    echo "Revocation completed"
    
    # Force CRL update after revocation
    echo "Updating CRL..."
    vault write $PKI_PATH/rotate-crl 2>/dev/null || \
      echo "Note: CRL rotation might not be supported in this Vault version"
    ;;
    
  crl)
    echo "=== Certificate Revocation List ==="
    echo "PKI Path: $PKI_PATH"
    
    # Try multiple methods to get CRL
    echo "Attempting to retrieve CRL..."
    
    # Method 1: Direct vault read (best method)
    if vault read -field=crl $PKI_PATH/crl > crl.pem 2>/dev/null; then
        if [ -s "crl.pem" ] && grep -q "BEGIN X509 CRL" crl.pem; then
            echo "CRL downloaded to crl.pem"
            echo ""
            echo "CRL Information:"
            openssl crl -in crl.pem -noout -text 2>/dev/null | head -20
            echo ""
            echo "Use 'openssl crl -in crl.pem -noout -text' to view full CRL"
            exit 0
        fi
    fi
    
    # Method 2: Check if CRL is empty or non-existent
    echo "CRL appears to be empty or not generated yet."
    echo "This could mean:"
    echo "1. CRL distribution is not configured"
    echo "2. CRL generation is disabled"
    echo "3. No certificates have been revoked yet"
    
    # Check configuration
    echo ""
    echo "Checking PKI configuration..."
    vault read $PKI_PATH/config/urls
    
    # Check if any certificates are revoked
    echo ""
    echo "Checking for revoked certificates..."
    SERIALS=$(vault list -format=json $PKI_PATH/certs 2>/dev/null | jq -r '.[]')
    REVOKED_FOUND=0
    for s in $SERIALS; do
        CERT_INFO=$(vault read -format=json $PKI_PATH/cert/$s 2>/dev/null)
        if [ $? -eq 0 ]; then
            REVOCATION_TIME=$(echo "$CERT_INFO" | jq -r '.data.revocation_time')
            if [ "$REVOCATION_TIME" != "0" ] && [ "$REVOCATION_TIME" != "null" ]; then
                echo "Revoked certificate found: $s"
                REVOKED_FOUND=1
            fi
        fi
    done
    
    if [ $REVOKED_FOUND -eq 0 ]; then
        echo "No revoked certificates found in storage."
    else
        echo ""
        echo "Revoked certificates exist but CRL is not available."
        echo "You need to configure CRL distribution:"
        echo "vault write $PKI_PATH/config/urls \\"
        echo "    issuing_certificates=\"\$VAULT_ADDR/v1/$PKI_PATH/ca\" \\"
        echo "    crl_distribution_points=\"\$VAULT_ADDR/v1/$PKI_PATH/crl\" \\"
        echo "    enable_templating=true"
    fi
    ;;
    
  issue)
    echo "=== Issuing New Certificate ==="
    echo "PKI Path: $PKI_PATH"
    read -p "Common Name: " CN
    if [ -z "$CN" ]; then
        echo "Error: Common Name is required"
        exit 1
    fi
    
    read -p "TTL (e.g., 24h, 720h): " TTL
    if [ -z "$TTL" ]; then
        TTL="720h"
    fi
    
    read -p "Organization (optional): " ORG
    read -p "Organizational Unit (optional): " OU
    read -p "Email (optional): " EMAIL
    read -p "Country (optional, 2-letter code): " COUNTRY
    
    echo ""
    echo "Issuing certificate for: $CN"
    
    # Create USER_CERTS directory structure
    USER_CERTS_DIR="USER_CERTS/${CLIENT_NAME}/${VENDOR_NAME}"
    mkdir -p "$USER_CERTS_DIR"
    
    # Build the command based on provided fields
    CMD="vault write $PKI_PATH/issue/digital_signing common_name=\"$CN\" ttl=\"$TTL\""
    
    if [ -n "$ORG" ]; then
        CMD="$CMD organization=\"$ORG\""
    fi
    if [ -n "$OU" ]; then
        CMD="$CMD organizational_unit=\"$OU\""
    fi
    if [ -n "$EMAIL" ]; then
        CMD="$CMD email_address=\"$EMAIL\""
    fi
    if [ -n "$COUNTRY" ]; then
        CMD="$CMD country=\"$COUNTRY\""
    fi
    
    # Execute the command and capture output
    CERT_JSON=$(eval $CMD -format=json 2>/dev/null)
    if [ $? -ne 0 ]; then
        echo "Error: Failed to issue certificate"
        exit 1
    fi
    
    # Extract and display information
    SERIAL_NUMBER=$(echo "$CERT_JSON" | jq -r '.data.serial_number')
    CERT_PEM=$(echo "$CERT_JSON" | jq -r '.data.certificate')
    COMMON_NAME=$(echo "$CERT_PEM" | openssl x509 -noout -subject 2>/dev/null | sed 's/.*CN=//' | cut -d'/' -f1)
    EXPIRATION=$(echo "$CERT_JSON" | jq -r '.data.expiration')
    
    echo ""
    echo "Certificate issued successfully!"
    echo "Serial Number: $SERIAL_NUMBER"
    echo "Common Name: ${COMMON_NAME:-$CN}"
    echo "Expiration: $EXPIRATION"
    echo ""
    echo "Save this serial number for future reference: $SERIAL_NUMBER"
    
    # Also output the certificate and key to files in USER_CERTS directory
    CERT_FILE="${USER_CERTS_DIR}/${CN// /_}_cert.pem"
    KEY_FILE="${USER_CERTS_DIR}/${CN// /_}_key.pem"

    # Output the certificate and key to files
    echo "$CERT_JSON" | jq -r '.data.certificate' > "$CERT_FILE"
    echo "$CERT_JSON" | jq -r '.data.private_key' > "$KEY_FILE"
    
    ENCRYPT=0
	read -sp "Set password for private key (press Enter for no password): " KEY_PASSWORD
	echo
	if [ -n "$KEY_PASSWORD" ]; then
	  read -sp "Confirm password: " KEY_PASSWORD_CONFIRM
	  echo
	  if [ "$KEY_PASSWORD" != "$KEY_PASSWORD_CONFIRM" ]; then
		  echo "Error: Passwords do not match!"
          echo "⚠️  Proceeding with no password! "
          ENCRYPT=0
	  else
        # Encrypt the private key
        ENCRYPTED_KEY_FILE="${USER_CERTS_DIR}/${CN// /_}_encrypted_key.pem"
        openssl rsa -aes256 -in "$KEY_FILE" -out "$ENCRYPTED_KEY_FILE" -passout pass:"$KEY_PASSWORD"
        if [ $? -eq 0 ]; then    
            ENCRYPT=1
            rm -f "$KEY_FILE"
            echo "Certificate saved to:  $CERT_FILE"
            echo "Password-protected private key saved to: $ENCRYPTED_KEY_FILE"
            chmod 600 "$CERT_FILE" "$ENCRYPTED_KEY_FILE"
            # Security warning
            echo ""
            echo "⚠️  SECURITY WARNING:"
            echo "   - Remember this password: it will be required for digital signing"
            echo "   - Files are saved in: $USER_CERTS_DIR"
            echo "   - Do not share the private key or password"
        else
            echo "Error: Failed to encrypt private key. Saving unencrypted key."
            ENCRYPT=0
        fi
      fi
    fi
    
	if [ $ENCRYPT -eq 0 ]; then
	  echo "Certificate saved to: $CERT_FILE"
	  echo "Private key saved to: $KEY_FILE"
	  # Security warning
	  echo ""
	  echo "⚠️  SECURITY WARNING: Private key is NOT password protected!"
	  echo "   - Set appropriate file permissions: chmod 600 $KEY_FILE"
	  echo "   - Do not share the private key"
	  echo "   - Consider using a password to protect the key"
	fi
    # Show directory structure
    echo ""
    echo "Directory structure created:"
    find USER_CERTS -type f -name "$CN*.pem" 2>/dev/null || echo "No user certificate files found"
    ;;

  export-pfx)
    if [ -z "$SERIAL" ]; then
        echo "Usage: $0 export-pfx <common_name>"
        echo "Example: $0 export-pfx jimmy"
        exit 1
    fi
    
    CN="$SERIAL"  # Using SERIAL parameter for common name
    
    CERT_FILE="USER_CERTS/${CLIENT_NAME}/${VENDOR_NAME}/${CN// /_}_cert.pem"
    KEY_FILE="USER_CERTS/${CLIENT_NAME}/${VENDOR_NAME}/${CN// /_}_key.pem"
    ENCRYPTED_KEY_FILE="USER_CERTS/${CLIENT_NAME}/${VENDOR_NAME}/${CN// /_}_encrypted_key.pem"
    PFX_FILE="USER_CERTS/${CLIENT_NAME}/${VENDOR_NAME}/${CN// /_}.p12"
    
    # Check which key file exists
    if [ -f "$ENCRYPTED_KEY_FILE" ]; then
        KEY_FILE_TO_USE="$ENCRYPTED_KEY_FILE"
        IS_ENCRYPTED=true
    elif [ -f "$KEY_FILE" ]; then
        KEY_FILE_TO_USE="$KEY_FILE"
        IS_ENCRYPTED=false
    else
        echo "Error: No certificate or key files found for: $CN"
        echo "Checked: $CERT_FILE and $KEY_FILE"
        exit 1
    fi
    
    if [ ! -f "$CERT_FILE" ]; then
        echo "Error: Certificate file not found: $CERT_FILE"
        exit 1
    fi
    
    read -sp "Enter password for PKCS#12 file: " PFX_PASSWORD
    echo
    read -sp "Confirm password: " PFX_PASSWORD_CONFIRM
    echo
    
    if [ "$PFX_PASSWORD" != "$PFX_PASSWORD_CONFIRM" ]; then
        echo "Error: Passwords do not match!"
        exit 1
    fi
    
    if [ "$IS_ENCRYPTED" = true ]; then
        read -sp "Enter private key password: " KEY_PASSWORD
        echo
        openssl pkcs12 -export \
            -in "$CERT_FILE" \
            -inkey "$KEY_FILE_TO_USE" \
            -out "$PFX_FILE" \
            -name "$CN Digital Signature" \
            -passin pass:"$KEY_PASSWORD" \
            -passout pass:"$PFX_PASSWORD"
    else
        openssl pkcs12 -export \
            -in "$CERT_FILE" \
            -inkey "$KEY_FILE_TO_USE" \
            -out "$PFX_FILE" \
            -name "$CN Digital Signature" \
            -passout pass:"$PFX_PASSWORD"
    fi
    
    if [ $? -eq 0 ]; then
        echo "PKCS#12 file created: $PFX_FILE"
        echo "Use this password to import into Adobe Acrobat or other applications"
        chmod 600 "$PFX_FILE"
    else
        echo "Error: Failed to create PKCS#12 file"
        exit 1
    fi
    ;;
        
  search)
    if [ -z "$SERIAL" ]; then
        echo "Usage: $0 search <common_name_pattern>"
        exit 1
    fi
    echo "=== Searching for certificates containing: $SERIAL ==="
    echo "PKI Path: $PKI_PATH"
    SERIALS=$(vault list -format=json $PKI_PATH/certs 2>/dev/null | jq -r '.[]')
    if [ -z "$SERIALS" ]; then
        echo "No certificates found or error accessing certificate list"
        exit 1
    fi
    
    FOUND=0
    for s in $SERIALS; do
        # Use the issue endpoint to get certificate details since cert endpoint returns null
        CERT_INFO=$(vault read -format=json $PKI_PATH/cert/$s 2>/dev/null)
        if [ $? -eq 0 ]; then
            # Try to get common name from different fields
            COMMON_NAME=$(echo "$CERT_INFO" | jq -r '.data.common_name // .data.certificate | select(. != null)')
            if [ -z "$COMMON_NAME" ] || [ "$COMMON_NAME" == "null" ]; then
                # If common_name is null, try to parse the certificate
                CERT_PEM=$(echo "$CERT_INFO" | jq -r '.data.certificate')
                if [ -n "$CERT_PEM" ] && [ "$CERT_PEM" != "null" ]; then
                    COMMON_NAME=$(echo "$CERT_PEM" | openssl x509 -noout -subject 2>/dev/null | sed 's/.*CN=//' | cut -d'/' -f1)
                fi
            fi
            
            if [ -n "$COMMON_NAME" ] && [ "$COMMON_NAME" != "null" ] && echo "$COMMON_NAME" | grep -iq "$SERIAL"; then
                EXPIRATION=$(echo "$CERT_INFO" | jq -r '.data.expiration')
                REVOCATION_TIME=$(echo "$CERT_INFO" | jq -r '.data.revocation_time')
                STATUS="Active"
                if [ "$REVOCATION_TIME" != "0" ] && [ "$REVOCATION_TIME" != "null" ]; then
                    STATUS="Revoked"
                fi
                echo "Found: $s"
                echo "  Common Name: $COMMON_NAME"
                echo "  Status: $STATUS"
                echo "  Expires: $EXPIRATION"
                echo ""
                FOUND=1
            fi
        fi
    done
    
    if [ $FOUND -eq 0 ]; then
        echo "No certificates found matching pattern: $SERIAL"
    fi
    ;;
    
  cleanup)
    echo "=== Cleaning up old certificates ==="
    echo "PKI Path: $PKI_PATH"
    read -p "Are you sure you want to revoke all expired certificates? (y/N): " CONFIRM
    if [[ "$CONFIRM" =~ ^[Yy]$ ]]; then
        SERIALS=$(vault list -format=json $PKI_PATH/certs 2>/dev/null | jq -r '.[]')
        if [ -z "$SERIALS" ]; then
            echo "No certificates found to clean up"
            exit 0
        fi
        
        REVOKED=0
        SKIPPED=0
        for s in $SERIALS; do
            CERT_INFO=$(vault read -format=json $PKI_PATH/cert/$s 2>/dev/null)
            if [ $? -eq 0 ]; then
                EXPIRATION=$(echo "$CERT_INFO" | jq -r '.data.expiration')
                REVOCATION_TIME=$(echo "$CERT_INFO" | jq -r '.data.revocation_time')
                
                # Skip already revoked certificates
                if [ "$REVOCATION_TIME" != "0" ] && [ "$REVOCATION_TIME" != "null" ]; then
                    SKIPPED=$((SKIPPED + 1))
                    continue
                fi
                
                if [ "$EXPIRATION" != "null" ]; then
                    EXPIRATION_TS=$(date -d "$EXPIRATION" +%s 2>/dev/null)
                    CURRENT_TS=$(date +%s)
                    
                    if [ $EXPIRATION_TS -lt $CURRENT_TS ] 2>/dev/null; then
                        echo "Revoking expired certificate: $s (expired: $EXPIRATION)"
                        vault write $PKI_PATH/revoke serial_number=$s >/dev/null 2>&1
                        if [ $? -eq 0 ]; then
                            echo "  ✓ Successfully revoked"
                            REVOKED=$((REVOKED + 1))
                        else
                            echo "  ✗ Failed to revoke"
                        fi
                    fi
                fi
            fi
        done
        echo "Cleanup completed. Revoked $REVOKED expired certificates, skipped $SKIPPED already revoked."
    else
        echo "Cleanup cancelled"
    fi
    ;;
    
  status)
    if [ -z "$SERIAL" ]; then
        echo "Usage: $0 status <serial_number>"
        exit 1
    fi
    echo "=== Certificate Status: $SERIAL ==="
    echo "PKI Path: $PKI_PATH"
    CERT_INFO=$(vault read -format=json $PKI_PATH/cert/$SERIAL 2>/dev/null)
    if [ $? -ne 0 ]; then
        echo "Certificate not found: $SERIAL"
        exit 1
    fi
    
    # Try to get common name from certificate PEM data
    CERT_PEM=$(echo "$CERT_INFO" | jq -r '.data.certificate')
    if [ -n "$CERT_PEM" ] && [ "$CERT_PEM" != "null" ]; then
        COMMON_NAME=$(echo "$CERT_PEM" | openssl x509 -noout -subject 2>/dev/null | sed 's/.*CN=//' | cut -d'/' -f1)
        SERIAL_NUMBER=$(echo "$CERT_PEM" | openssl x509 -noout -serial 2>/dev/null | cut -d'=' -f2)
        EXPIRATION=$(echo "$CERT_PEM" | openssl x509 -noout -enddate 2>/dev/null | cut -d'=' -f2)
    else
        COMMON_NAME=$(echo "$CERT_INFO" | jq -r '.data.common_name')
        SERIAL_NUMBER=$(echo "$CERT_INFO" | jq -r '.data.serial_number')
        EXPIRATION=$(echo "$CERT_INFO" | jq -r '.data.expiration')
    fi
    
    REVOCATION_TIME=$(echo "$CERT_INFO" | jq -r '.data.revocation_time')
    
    echo "Common Name: ${COMMON_NAME:-Not available}"
    echo "Serial Number: ${SERIAL_NUMBER:-Not available}"
    echo "Expiration: ${EXPIRATION:-Not available}"
    
    if [ "$REVOCATION_TIME" != "0" ] && [ "$REVOCATION_TIME" != "null" ]; then
        echo "Status: REVOKED"
        echo "Revocation Time: $(date -d @$REVOCATION_TIME 2>/dev/null || echo $REVOCATION_TIME)"
    else
        echo "Status: ACTIVE"
        
        # Check if certificate is expired
        if [ -n "$EXPIRATION" ] && [ "$EXPIRATION" != "null" ]; then
            EXPIRATION_TS=$(date -d "$EXPIRATION" +%s 2>/dev/null)
            CURRENT_TS=$(date +%s)
            if [ $EXPIRATION_TS -lt $CURRENT_TS ] 2>/dev/null; then
                echo "Warning: Certificate has EXPIRED"
            fi
        fi
    fi
    ;;
    
  env)
    echo "=== Current Environment Configuration ==="
    echo "BASE_NAME:    ${BASE_NAME}"
    echo "CLIENT_NAME:  ${CLIENT_NAME}"
    echo "VENDOR_NAME:  ${VENDOR_NAME}"
    echo "PKI_PATH:     ${PKI_PATH}"
    echo ""
    echo "To override, set environment variables:"
    echo "  export BASE_NAME='different-base'"
    echo "  export CLIENT_NAME='different-client'"
    echo "  export VENDOR_NAME='different-vendor'"
    echo "  $0 list"
    ;;
    
  help|*)
    echo "PKI Certificate Management Tool"
    echo "PKI Path: $PKI_PATH"
    echo "Usage: $0 {list|view|revoke|crl|issue|export-pfx|search|cleanup|status|env} [argument]"
    echo ""
    echo "Commands:"
    echo "  list                    - List all issued certificates"
    echo "  view <serial>           - View certificate details"
    echo "  revoke <serial>         - Revoke a certificate"
    echo "  crl                     - Show Certificate Revocation List"
    echo "  issue                   - Interactively issue a new certificate"
    echo "  export-pfx <name>       - Export certificate for Adobe Acrobat"
    echo "  search <pattern>        - Search certificates by common name"
    echo "  cleanup                 - Revoke all expired certificates"
    echo "  status <serial>         - Check certificate status"
    echo "  env                     - Show current environment configuration"
    echo ""
    echo "Environment Variables:"
    echo "  BASE_NAME    - Base name (default: jimsnet)"
    echo "  CLIENT_NAME  - Client name (default: abc)"
    echo "  VENDOR_NAME  - Vendor name (default: vendor1)"
    echo ""
    echo "Examples:"
    echo "  $0 list"
    echo "  $0 view 00:11:22:33:44:55:66:77:88:99:aa:bb:cc:dd:ee:ff"
    echo "  $0 revoke 00:11:22:33:44:55:66:77:88:99:aa:bb:cc:dd:ee:ff"
    echo "  $0 issue"
    echo "  $0 search john"
    echo "  $0 status 00:11:22:33:44:55:66:77:88:99:aa:bb:cc:dd:ee:ff"
    echo "  $0 export-pfx jimmy"
    echo "  $0 env"
    ;;
esac
