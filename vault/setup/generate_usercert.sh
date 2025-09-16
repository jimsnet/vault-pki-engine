# alt_names="jane.smith@zorro.com"


vault write jimsnet_abc_vendor1/issue/digital_signing \
    common_name="Jane Smith" \
    ttl=2160h \
    format=pem > jimsnet_abc_vendor1_janesmith.crt
