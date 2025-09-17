docker compose up -d
export VAULT_ADDR=http://localhost:8200
vault operator init -key-shares=1 -key-threshold=1 -format=json > vault-keys.json
unsealkey=$(jq -r '.unseal_keys_b64[0]' vault-keys.json)
curl -s --request POST --data "{\"key\": \"${unsealkey}\"}" http://localhost:8200/v1/sys/unseal | jq
root_token=$(jq -r '.root_token' vault-keys.json)
export VAULT_TOKEN=$root_token
vault login $root_token
