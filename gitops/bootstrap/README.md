# Argo CD (Phase 8) — GitOps adoption of the platform

Argo CD continuously reconciles the platform from this git repo. After
Phase 8, a full rebuild is: Terraform → Ansible → **Argo syncs the whole
platform** (no human helm/kubectl).

## Install

```bash
helm repo add argo https://argoproj.github.io/argo-helm
helm upgrade --install argocd argo/argo-cd --version <pin> -n argocd \
  --create-namespace -f gitops/bootstrap/argocd-values.yaml \
  --wait --disable-openapi-validation
```

Trimmed: no dex/notifications, single replicas. `argocd-cm` sets
`application.resourceTrackingMethod: annotation` — **the pre-adoption
must-do**: default label tracking collides with Helm-set
`app.kubernetes.io/instance` labels inside immutable selectors, breaking
adoption on "field is immutable".

## Repo credential — read-only SSH deploy key (NOT in git)

The repo is private, so Argo needs read access. We use a **read-only SSH
deploy key** scoped to this one repo (better than a PAT — repo-scoped,
read-only enforced by GitHub). Private key lives in
`~/.k8s-lab-secrets/argocd/` (mode 600), never committed. D4: the
`argo-bootstrap` Ansible role owns this on a rebuild.

```bash
# 1. generate the keypair
ssh-keygen -t ed25519 -N "" -C argocd-deploy \
  -f ~/.k8s-lab-secrets/argocd/argocd-repo-deploy.key

# 2. add the .pub to GitHub → repo Settings → Deploy keys
#    (title argocd-readonly; DO NOT allow write access)

# 3. create the Argo repository Secret from the private key
kubectl -n argocd create secret generic repo-k8s-lab-infra \
  --from-literal=type=git \
  --from-literal=url=git@github.com:nskgit/k8s-lab-infra.git \
  --from-file=sshPrivateKey=$HOME/.k8s-lab-secrets/argocd/argocd-repo-deploy.key \
  --dry-run=client -o yaml | kubectl apply -f -
kubectl -n argocd label secret repo-k8s-lab-infra \
  argocd.argoproj.io/secret-type=repository --overwrite
```

## CLI — use `--core` mode (no port-forward)

`argocd` CLI over a kubectl port-forward has flaky gRPC ("error dial
proxy"). `--core` talks straight to the k8s API via kubeconfig — cleaner.
It reads `argocd-cm` from the current kube-context namespace, so point
the context at `argocd` for CLI calls:

```bash
kubectl config set-context --current --namespace=argocd
export ARGOCD_OPTS='--core'
argocd app list
argocd app diff  <app>     # inspect BEFORE syncing
argocd app sync  <app>
# restore your namespace when done:
kubectl config set-context --current --namespace=default
```

(UI alternative: `kubectl -n argocd port-forward svc/argocd-server
8080:80` → http://localhost:8080, user admin, password from
`kubectl -n argocd get secret argocd-initial-admin-secret -o
jsonpath='{.data.password}' | base64 -d`.)

## Adoption pattern (adopt in place, zero disruption)

Each Application points at the SAME chart version + values file already
in git, so Argo's render matches what's running. The ONLY first-sync
change is Argo adding its `argocd.argoproj.io/tracking-id` annotation —
verified with `argocd app diff` (annotations-only). Resources are
adopted (`configured`), never recreated (pods keep their AGE/RESTARTS).

Order (safest first): **podinfo (raw manifests) ✅** → metrics-server →
Loki → Fluent Bit → Kiali → kube-prometheus-stack (needs
`ServerSideApply=true` — CRDs exceed the 262KB client-side-apply
annotation limit) → Istio (base → istiod → gateway, sync-waves).
After each is Synced/Healthy, delete only the `sh.helm.release.v1.*`
Secret so Helm stops co-owning the resources (**never `helm
uninstall` — it deletes the live resources**).

**ccm-csi is NOT adopted** — Ansible-owned (D3: rebuild deadlock — fresh
nodes carry the uninitialized taint until CCM runs; Argo's own pods
can't schedule on tainted nodes).

## Applications

`gitops/applications/*.yaml` — one Argo Application per component;
`gitops/bootstrap/root-app.yaml` (app-of-apps) watches that directory, so
the whole platform is one declarative tree. Sync-waves: namespaces -1 →
istio-base 0 → istiod 1 → gateway charts 2 → Gateway objects 3.

**Deliberately NOT Argo-managed** (the complete list):
- **ccm-csi + CNI** — Ansible-owned (D3 rebuild deadlock, see above).
- **oci-bv StorageClass** — applied by the `oci-csi` Ansible role from
  `gitops/platform/storage/` (part of the CSI layer, same D3 logic).
- **Kiali** — Helm-managed exception: its chart bakes a random
  `signing_key` into the ConfigMap per render (non-deterministic →
  GitOps-incompatible, LEARNING-LOG §11).
- **argocd namespace + Argo itself** — the argo-bootstrap Ansible layer
  (something must exist before the first Application can).
- **blog-db-credentials Secret** — in-cluster only, never in git;
  recreate by hand/Ansible before the blog app syncs on a rebuild.

## Aborting a bad adoption (IMPORTANT)

Every Application carries `resources-finalizer.argocd.argoproj.io`.
After a first sync has added tracking annotations, a plain
`kubectl delete application <app>` CASCADE-DELETES the adopted live
resources (for `gateways` that's the ingress; for `blog` the DB and its
PVC). To back out an adoption WITHOUT touching live resources:

```bash
argocd app delete <app> --cascade=false
# or: kubectl -n argocd patch application <app> --type=json \
#   -p='[{"op":"remove","path":"/metadata/finalizers"}]' && kubectl -n argocd delete application <app>
```
