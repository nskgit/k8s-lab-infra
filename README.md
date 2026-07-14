# k8s-lab-infra

Terraform + (later) Ansible for a self-managed Kubernetes cluster on OCI Always Free.

Full master plan and architecture diagrams live in `docs/`. Practical operator quick-reference
(commands used, gotchas discovered) lives in [`docs/LEARNING-LOG.md`](docs/LEARNING-LOG.md).

## Prerequisites (one time)

- Terraform 1.11+, OCI CLI, `oci` CLI authenticated (`~/.oci/config`)
- SSH keypair at `~/.ssh/k8s_lab_ed25519` (public key trusted by all lab instances)
- Local secrets file at `~/.k8s-lab-secrets/state-backend.env` (mode 600) containing:
  ```
  export AWS_ACCESS_KEY_ID=...              # OCI Customer Secret Key ID   (bootstrap output)
  export AWS_SECRET_ACCESS_KEY=...          # OCI Customer Secret Key value (bootstrap output)
  export AWS_REQUEST_CHECKSUM_CALCULATION=WHEN_REQUIRED     # MANDATORY — see docs/PROJECT-PLAN-v3.md §9.1
  export AWS_RESPONSE_CHECKSUM_VALIDATION=WHEN_REQUIRED     # MANDATORY
  ```

## Layout

- `terraform/bootstrap/` — one-time setup: dedicated `k8s-lab` compartment, remote-state
  Object Storage bucket, OCIR repos. Applied once, local state, single operator.
- `terraform/modules/` — reusable modules: `network`, `cluster-node`, `lb`, `iam-ccm`.
- `terraform/primary/` — root module for the primary region. Remote state in
  `k8s-lab-tfstate` bucket, consumes `bootstrap`'s outputs.
- `terraform/dr/` — stub for the future DR region (Phase 14).
- `ansible/` — OS-to-cluster bootstrap roles (Phase 5a; 8 idempotent roles).
- `docs/round1-artifacts/kubeadm/` — Round-1 manual kubeadm configs (Phase 2,
  historical reference; live config is templated by the `kubeadm-cp` Ansible role).
- GitOps content moved to its OWN repo 2026-07-15 (Block 11 step 0):
  **github.com/nskgit/k8s-lab-gitops** — bootstrap/, applications/,
  platform/, workloads/. This repo = cloud + cluster substrate only.
- `exercises/` — standalone practice manifests (not deployed by anything).
- `.github/workflows/` — CI (Block 11, upcoming).

## Typical operator flow

```bash
# always source secrets first (in every fresh shell)
source ~/.k8s-lab-secrets/state-backend.env

# work in the primary root
cd terraform/primary

# review, then apply
terraform plan  -var-file=terraform.tfvars
terraform apply -var-file=terraform.tfvars
```

Bootstrap is applied separately (its own root, local state):
```bash
cd terraform/bootstrap
terraform apply -var-file=terraform.tfvars
```

## SSH access to nodes

`~/.ssh/config` block after `terraform apply` — replace IPs from `terraform output`:
```
Host k8s-bastion
  HostName <bastion_public_ip>
  User opc
  IdentityFile ~/.ssh/k8s_lab_ed25519
  IdentitiesOnly yes

Host k8s-cp
  HostName <control_plane_private_ip>
  User opc
  IdentityFile ~/.ssh/k8s_lab_ed25519
  IdentitiesOnly yes
  ProxyJump k8s-bastion

# same pattern for k8s-worker-1, k8s-worker-2
```

Then: `ssh k8s-bastion`, `ssh k8s-cp`, `ssh k8s-worker-1`, `ssh k8s-worker-2`.

## Status

- Phase 0 (Mac toolchain, SSH key, OCI auth): **complete**
- Phase 1 (Terraform modules + primary applied): **complete**
- Phase 2 (Round 1 manual kubeadm bootstrap): **next**
