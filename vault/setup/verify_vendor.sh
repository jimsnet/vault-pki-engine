# Verify the setup
echo "=== Verification ==="
echo "Issuers:"
vault list jimsnet_abc_vendor1/issuers
echo ""
echo "Issuer config:"
vault read jimsnet_abc_vendor1/config/issuers
echo ""
echo "Role config:"
vault read jimsnet_abc_vendor1/roles/digital_signing

# Test certificate issuance
#vault write jimsnet_abc_vendor1/issue/digital_signing \
#    common_name="Test User" \
#    ttl=24h
