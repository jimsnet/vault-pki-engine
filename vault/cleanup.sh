docker compose down -v
rm -Rf ./data/*
rm -Rf ./setup/ROOT_CERT/*
rm -Rf ./setup/INT_CERTS/*
rm -Rf ./setup/USER_CERTS/*
echo "" > vault-keys.json
echo "Cleanup done."
