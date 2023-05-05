# kubectl create secret generic grafana-secrets --from-env-file=oidc.kv --dry-run=client -o yaml > oidc.yaml
grafana_id=grafana
grafana_secret=changeme
auth_url=https://auth.home.tremoureux.fr/api/oidc/authorization
token_url=https://auth.home.tremoureux.fr/api/oidc/token
api_url=https://auth.home.tremoureux.fr/api/oidc/userinfo
