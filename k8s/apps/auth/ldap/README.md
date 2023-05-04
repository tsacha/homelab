kubectl create secret generic lldap-secrets --dry-run=client -o yaml \
        --from-literal=lldap-jwt-secret=(pwgen -s 40 -1 -y -B) \
        --from-literal=lldap-bind-dn=cn=admin,ou=people,dc=tremoureux,dc=fr \
        --from-literal=lldap-bind-password=(pwgen -s 40 -1 -y -B) \
        --from-literal=lldap-base-dn=dc=tremoureux,dc=fr | sops --output-type=yaml -e /dev/stdin > secrets.sops.yaml

kubectl apply -f storage.yaml
kubectl apply -f deployment.yaml
kubectl apply -f ingress.yaml
