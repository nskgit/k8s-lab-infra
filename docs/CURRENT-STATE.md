# Where we are — resume pointer for the next session

**Last updated:** 2026-07-09 end-of-session — Phase 4 complete → Phase 5 next.

Read this file FIRST if you're a new session or coming back after a break.
This is the single anchor point. The full plan is in the other docs; this file
tells you exactly what to do next.

---

## How to open a new Claude Code session from here

Claude Code sessions have no cross-session chat memory — each new session starts
fresh. But what survives:

- Everything on disk (this repo, `~/.k8s-lab-secrets/`, `~/.ssh/config`, `~/.oci/`)
- All `memory/*.md` files at
  `~/.claude/projects/-Users-satheshkumarnapoleon-workspace-project/memory/` —
  they auto-load on every response, so you never "forget" them
- `MEMORY.md` in that same dir — the index of what's in memory

**To start a new session:**
1. Open Claude Code in this same working directory (`~/workspace/project` or the
   repo root — the memory system points at the project regardless).
2. As your first message, paste something like:

> Read `~/workspace/k8s-lab-infra/docs/CURRENT-STATE.md` and
> `~/workspace/k8s-lab-infra/docs/PHASES-4-15-EXECUTION-PLAN.md` §Phase 5.
> Phase 4 is done. Resume from Phase 5 Step 0 pre-work.

The memory files auto-load. The plan file (`PHASES-4-15-EXECUTION-PLAN.md`)
tells the new session exactly what Phase 5 needs. This file is the pointer.

---

## Overall arc

| # | Phase | State |
|---|---|---|
| 0-4 | Foundation, TF infra, kubeadm, CCM, CSI, PV/PVC exercise | ✅ **done** — see `PHASES-COMPLETED.md` |
| **5** | **Round 2 codify (Ansible + CI)** | 🚧 **next** |
| 6 | Istio + Gateway API + LB TCP:443 | ⏳ |
| 7 + 7b | kube-prometheus-stack + Loki/Fluent Bit | ⏳ |
| 8 | Argo CD adoption | ⏳ |
| 9-11 | Wave-1/2 apps + promotion | ⏳ |
| 12 | k6 + chaos + teardown/rebuild rehearsal | ⏳ |
| 13-15 | ci-runner, DR drills, stretch | ⏳ |

**Done: 5 phases. Remaining: 11.** Realistic remaining effort: a day or two.

---

## Phase 5 — do these first (in order)

Full spec is in `docs/PHASES-4-15-EXECUTION-PLAN.md §Phase 5`. Below is the
pre-work sequence — get these four done BEFORE writing Ansible roles.

### 1. `git commit` + push to GitHub (blocker for any of the others)

The repo has ZERO commits. Everything lives on one laptop right now.
Everything Phase 0-4 built is a laptop disk failure away from oblivion.

- `git add -A && git commit -m "phase 0-4"`
- Create the `k8s-lab-infra` repo on GitHub (private is fine)
- `git remote add origin <url> && git push -u origin master`
- `gh` CLI is not installed on the Mac — do it via web UI, or `brew install gh`

### 2. Fix the dual-Terraform-provider bug

Every module binds to implicit `hashicorp/oci` 8.21.0 instead of `oracle/oci`
6.37 (the root's real provider). Works locally by accident because ambient
`~/.oci/config` auto-configures both; breaks headless CI.

Add `versions.tf` to all four modules (`network`, `cluster-node`, `lb`,
`iam-ccm`) and to `bootstrap/`:

```
terraform {
  required_providers {
    oci = {
      source  = "oracle/oci"
      version = "~> 6.0"
    }
  }
}
```

Then `terraform init -upgrade` and confirm `terraform providers` shows a single
namespace. `terraform plan` on `primary/` should be a no-op.

### 3. Delete stale `terraform/primary/errored.tfstate`

The 108 KB file left from the chunked-encoding incident on Day 1. Not in state,
gitignored, but a wrong `terraform state push` would resurrect the duplicated-
resources era. Confirm remote state has ~50 resources first, then:

```
rm -v ~/workspace/k8s-lab-infra/terraform/primary/errored.tfstate
```

### 4. Add missing Terraform outputs

Phase 5's Ansible CCM role needs three OCIDs from Terraform that aren't
currently in `primary/outputs.tf`:

```hcl
output "compartment_ocid"  { value = var.compartment_ocid }
output "vcn_id"            { value = module.network.vcn_id }
output "public_subnet_id"  { value = module.network.public_subnet_id }
```

The network module already exposes these — just need to re-expose from the
root so `terraform output -json` (which Ansible inventory reads) sees them.

---

## Phase 5 proper — the Ansible role plan (after pre-work)

Ordered role list (single-sourced version pins in `ansible/group_vars/all.yml`):

1. `common` — kernel modules, sysctls, swap off, firewalld off
2. `containerd` — Docker CE yum repo, `SystemdCgroup = true`
3. `kubernetes-packages` — 1.33.13 pinned, upstream repo, SELinux permissive
4. `kubeadm-cp` — Jinja2-templated `ClusterConfiguration.yaml`, guarded on
   existence of `/etc/kubernetes/admin.conf`
5. `cni-calico` — Tigera Operator + `Installation` CR (VXLAN, `bgp: Disabled`,
   `canReach: 10.0.0.1`) — the operator + CRs, no live `kubectl patch`
6. `oci-ccm` — templates the `cloud-provider.yaml` Secret from TF outputs,
   applies the CCM manifests from the OCI release URL matching K8s minor
7. `oci-csi` — mirror of the above; the second Secret name is
   `oci-volume-provisioner` with key `config.yaml`; snapshot CRDs first
8. `kubeadm-worker` — Jinja2 `JoinConfiguration.yaml`, uses IMDS at
   `http://169.254.169.254/opc/v2/instance/id` (with `Authorization: Bearer
   Oracle` header) to render `provider-id: oci://<ocid>` into kubelet extra
   args at registration time — no more manual patching
9. `argo-bootstrap` — Argo install + `root-app.yaml`; also owns bootstrap
   secrets (OCIR pull creds, Argo repo creds) — see D4 in the execution plan

### CI workflow specifics

- Workflow-level env on EVERY job (including destroy):
  `AWS_REQUEST_CHECKSUM_CALCULATION=WHEN_REQUIRED`
  `AWS_RESPONSE_CHECKSUM_VALIDATION=WHEN_REQUIRED`
  Missing them = silent state corruption. Details in
  `memory/project_tf_backend_oci_quirks.md`.
- OCI provider auth: write `~/.oci/config` in a setup step from Actions secrets
  (OCI_TENANCY_OCID, OCI_USER_OCID, OCI_FINGERPRINT, OCI_PRIVATE_KEY).
- SSH: load `k8s_lab_ed25519` via ssh-agent, use `ProxyJump` for Ansible.
- Concurrency group so applies serialize.
- Plan job uploads `tfplan.bin`, apply job in a GitHub Environment with
  required-reviewer approval (satisfies "reviewed plan before apply" rule).

---

## State of the cluster (as of end-of-session)

- 3 nodes Ready: cp (10.0.1.209), worker-1 (10.0.2.230), worker-2 (10.0.2.100)
- Calico VXLAN CNI, all 3 calico-node pods 1/1 Ready
- OCI CCM v1.33.2 running on cp; nodes have real InternalIPs, providerIDs,
  topology labels
- OCI CSI v1.33.2 installed (kube-system): controller 8/8 on cp, node driver
  3/3 across nodes; VolumeSnapshot CRDs (v6.3.4) present
- StorageClasses:
  - `local-path` (default) — free, node-local, boot-volume slack
  - `oci-bv` (explicit) — vpusPerGB "0", paravirtualized, WFFC, Delete
- No PVCs live (Phase 4 exercise volumes were deleted)
- Bastion: post-recovery, 1.5 GB swap, sshd healthy

---

## Access details

- kubectl from Mac: `ssh -N -L 6443:127.0.0.1:6443 k8s-cp` tunnel + `~/.kube/config`
- SSH short names via `~/.ssh/config`: `k8s-bastion`, `k8s-cp`,
  `k8s-worker-1`, `k8s-worker-2`. All use ControlMaster multiplexing +
  ServerAlive keepalives (added during bastion OOM recovery).
- Bastion public IP: 157.151.226.90 (reserved)
- LB public IP: 157.151.193.45 (Phase 5 D8 will move to bootstrap root so it
  survives destroy/rebuild)
- OCI CLI: `~/.oci/config` already configured, `us-ashburn-1` region

## Secrets (never in git)

- `~/.k8s-lab-secrets/state-backend.env` (mode 600) — MUST be sourced before
  any `terraform` command against `primary/`:
  ```
  source ~/.k8s-lab-secrets/state-backend.env
  ```
  Contains AWS-style Customer Secret Key + the two AWS SDK v2 checksum env vars.
- `~/.ssh/k8s_lab_ed25519` — private SSH key
- `~/.oci/config` + `~/.oci/oci_api_key.pem` — OCI CLI auth

---

## Amendments to the master plan (already applied to both copies)

See `docs/PROJECT-PLAN-v3.md` for the full details; summary of what's amended:

- **Decision #8** (storage) — rewritten. The "12 GB free PVC headroom" claim
  was wrong; strategy is local-path default + oci-bv explicit
- **Decision #14** (platform install) — ccm-csi moved OUT of Argo, INTO the
  Ansible layer (avoids rebuild deadlock)
- **Decision #15** (ownership layers) — Ansible now owns "cluster-exists AND
  schedulable" (containerd, kubeadm, Calico, CCM+CSI) + Argo bootstrap
- **Decision #22** (observability) — extended with logging (Loki + Fluent Bit
  at Phase 7b) and metrics-server (Phase 7)
- **Phase 4** — was "CCM + CSI + PVC"; is now CSI + StorageClass + PVC only
  (CCM was pulled forward to Phase 2)
- **Phase 13** — ci-runner NOT on bastion (memory-tight); use 2nd Always-Free
  E2.1.Micro in private worker subnet with own `nsg-runner`
- NSG matrix — added 3 rows for TCP 5473 (calico-typha hostNetwork)
- NSG matrix — added row for UDP 4789 worker→cp (was pruned, re-added)
- Operator notes §9 — 10 sub-sections capturing every non-obvious lesson

---

## Documentation layout (for orientation)

```
~/workspace/k8s-lab-infra/
├── docs/
│   ├── PROJECT-PLAN-v3.md          master plan + operator notes §9
│   ├── PHASES-4-15-EXECUTION-PLAN.md   per-phase action list (post-audit)
│   ├── PHASES-COMPLETED.md         high-level journal, phase-by-phase
│   ├── LEARNING-LOG.md             gotchas table — grep when things break
│   └── CURRENT-STATE.md            THIS FILE (resume pointer)
├── terraform/
│   ├── bootstrap/                  compartment, state bucket, OCIR
│   ├── modules/{network,cluster-node,iam-ccm,lb}
│   └── primary/                    root; state in Object Storage
├── kubeadm/
│   ├── ClusterConfiguration.yaml   used by kubeadm init
│   └── JoinConfiguration-worker.template.yaml
├── k8s/
│   ├── storage/oci-bv-storageclass.yaml    the deliberate paid SC
│   └── exercise/                    Phase 4 exercise + PV/PVC study samples
├── ansible/                         stub — populated at Phase 5
└── .github/workflows/               stub — populated at Phase 5
```

Memory files at `~/.claude/projects/-Users-satheshkumarnapoleon-workspace-project/memory/`
(13 files, indexed in `MEMORY.md`). Auto-loaded on every response.

---

## If you're the future me / a fresh session — quick sanity check on arrival

```bash
# Do the ~/.k8s-lab-secrets/state-backend.env + tunnel + config still exist?
ls -la ~/.k8s-lab-secrets/state-backend.env ~/.kube/config ~/.ssh/config
echo "---"
# Can we reach the cluster? (needs the tunnel running in another terminal)
ssh -N -L 6443:127.0.0.1:6443 k8s-cp &
sleep 3 && kubectl get nodes
echo "---"
# Confirm StorageClasses are still there
kubectl get sc
```

If all three succeed, we're where we left off. If not, `docs/PROJECT-PLAN-v3.md
§9` (operator notes) covers the recovery playbook for anything that might have
drifted.
