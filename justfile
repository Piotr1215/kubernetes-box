set export
set shell := ["bash", "-uc"]

yaml    := justfile_directory() + "/yaml"
scripts := justfile_directory() + "/scripts"

browse      := if os() == "linux" { "xdg-open "} else { "open" }
copy        := if os() == "linux" { "xsel -ib"} else { "pbcopy" }

argocd_port  := "30950"
cluster_name := "control-plane"

export gcp_provider_version     := "v0.15.0"

# this list of available targets
# targets marked with * are main targets
default:
  @just --list --unsorted

# * setup kind cluster with GCP official provider and ArgoCD
setup_infra: setup_kind setup_uxp setup_gcp setup_argo 

# setup kind cluster
setup_kind:
  #!/usr/bin/env bash
  set -euo pipefail

  echo "Creating kind cluster - {{cluster_name}}"
  envsubst < kind-config.yaml | kind create cluster --config - --wait 3m
  kind get kubeconfig --name {{cluster_name}}
  kubectl config use-context kind-{{cluster_name}}

# setup universal crossplane
setup_uxp:
  echo "Installing UXP"
  kubectl create namespace upbound-system
  up uxp install
  kubectl wait --for condition=Available=True --timeout=300s deployment/xgql --namespace upbound-system

# setup GCP official provider
setup_gcp:
  @echo "Setting up GCP official provider"
  @kubectl config use-context kind-control-plane
  @envsubst < {{yaml}}/gcp-provider.yaml | kubectl apply -f - 
  @kubectl wait --for condition=healthy --timeout=300s provider/provider-gcp

# setup ArgoCD and patch server service to nodePort 30950
setup_argo:
  @echo "Installing ArgoCD"
  @kubectl create namespace argocd
  @kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml 
  @kubectl wait --for condition=Available=True --timeout=300s deployment/argocd-server --namespace argocd
  @kubectl patch svc argocd-server -n argocd -p '{"spec": {"type": "NodePort"}}'
  @kubectl patch svc argocd-server -n argocd --type merge --type='json' -p='[{"op": "replace", "path": "/spec/ports/0/nodePort", "value": {{argocd_port}}}]'

# copy ArgoCD server secret to clipboard and launch browser without port forwarding
launch_argo:
  @kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d | {{copy}}
  @nohup {{browse}} http://localhost:{{argocd_port}} >/dev/null 2>&1 &

# bootstrap ArgoCD apps
bootstrap_apps:
  @kubectl apply -f bootstrap.yaml

# * delete KIND cluster
teardown:
  @echo "Delete KIND cluster"
  @kind delete clusters control-plane

_create_repo_secret:
  @echo "Creating repo secret"
  @kubectl apply -f ./secrets/repo-deploy-secret.yaml

