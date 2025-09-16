storage "file" {
  path = "/bitnami/vault/data"
}

listener "tcp" {
  address = "0.0.0.0:8200"
  tls_disable = "true"
}

api_addr = "http://localhost:8200"
cluster_addr = "https://localhost:8201"
ui = true


