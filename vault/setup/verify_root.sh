# Verify Root CA is accessible
vault read jimsnet-customer_abc/cert/ca

# Check if Root CA has issuers
vault list jimsnet-customer_abc/issuers
