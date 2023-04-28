kubectl apply --server-side --kustomize ~/Git/homelab/k8s/bootstrap/flux/
cat ~/.age | kubectl create secret generic sops-age --namespace=flux-system --from-file=age.agekey=/dev/stdin
sops -d ssh.yaml | kubectl apply -f -
kubectl apply -f ~/Git/homelab/k8s/flux/vars/cluster-settings.yaml
kubectl apply --server-side --kustomize ~/Git/homelab/k8s/flux/config

# Génération du ssh.yaml:

Générer un clé SSH
Suivre : https://github.com/onedr0p/flux-cluster-template/issues/324
