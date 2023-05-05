openssl genrsa -out auth.rsa 4096
kubectl create secret generic authelia-secrets --dry-run=client -o yaml \
  --from-literal=authelia-storage-password=(pwgen -s 96 -1) \
  --from-literal=authelia-redis-password=(pwgen -s 96 -1) \
  --from-literal=authelia-jwt-token=(pwgen -s 128 -1) \
  --from-literal=authelia-session-encryption-key=(pwgen -s 128 -1) \
  --from-literal=authelia-storage-encryption-key=(pwgen -s 128 -1) \
  --from-literal=authelia-oidc-hmac-secret=(pwgen -s 32 -1) \
  --from-file=authelia-oidc-hmac-private-key=auth.rsa > secrets.yaml
sops --encrypt --encrypted-regex '^(data|stringData)$' secrets.yaml > secrets.sops.yaml
rm secrets.yaml
kubectl create secret generic authelia-oidc --dry-run=client -o yaml --from-file=configuration.oidc.yaml=oidc.yaml > configuration.oidc.yaml
sops --encrypt --encrypted-regex '^(data|stringData)$' configuration.oidc.yaml > configuration.oidc.sops.yaml
rm configuration.oidc.yaml

oidc.yaml:

``` yaml
---
identity_providers:
  oidc:
    clients:
    - id: grafana
      description: Grafana
      secret: $plaintext$replaceme
      sector_identifier: 'home.tremoureux.fr'
      consent_mode: 'implicit'
      public: false
      authorization_policy: 'two_factor'
      redirect_uris:
      - 'https://grafana.home.tremoureux.fr/login/generic_oauth'
      scopes:
      - 'openid'
      - 'profile'
      - 'email'
      - 'groups'
      grant_types:
      - 'refresh_token'
      - 'authorization_code'
      response_types:
      - 'code'
      userinfo_signing_algorithm: none
    - id: gitea
      description: Gitea
      secret: $plaintext$replaceme
      sector_identifier: 'home.tremoureux.fr'
      consent_mode: 'implicit'
      public: false
      authorization_policy: 'two_factor'
      redirect_uris:
      - 'https://git.home.tremoureux.fr/user/oauth2/authelia/callback'
      scopes:
      - 'openid'
      - 'email'
      - 'profile'
      - 'groups'
      grant_types:
      - 'refresh_token'
      - 'authorization_code'
      response_types:
      - 'code'
      userinfo_signing_algorithm: none
    - id: nextcloud
      description: Nextcloud
      secret: $plaintext$replaceme
      sector_identifier: 'home.tremoureux.fr'
      consent_mode: 'implicit'
      public: false
      authorization_policy: 'two_factor'
      redirect_uris:
      - 'https://nextcloud.home.tremoureux.fr/apps/oidc_login/oidc'
      scopes:
      - 'openid'
      - 'email'
      - 'profile'
      - 'groups'
      grant_types:
      - 'refresh_token'
      - 'authorization_code'
      response_types:
      - 'code'
      userinfo_signing_algorithm: none

```

