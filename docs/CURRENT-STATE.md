# Where we are — resume pointer for the next session

**Last updated:** 2026-07-10 end-of-day — Phase 5a complete + Phase 7 pre-work
(bind-address + NSG rules) applied. **Resume with the kube-prometheus-stack
helm install** (steps in "Where we paused" below).

Read this file FIRST if you're a new session or coming back after a break.
This is the single anchor point. Full plan is in `docs/PROJECT-PLAN-v3.md`
and `docs/PHASES-4-15-EXECUTION-PLAN.md`; this file tells you exactly what
to do next.

---

## How to open a new Claude Code session from here

Claude Code sessions have no cross-session chat memory — each new session
starts fresh. But what survives:

- Everything on disk (this repo, `~/.k8s-lab-secrets/`, `~/.ssh/config`, `~/.oci/`)
- All `memory/*.md` files at
  `~/.claude/projects/-Users-satheshkumarnapoleon-workspace-project/memory/` —
  auto-load on every response (indexed in `MEMORY.md` there)
- `~/.kube/config-lab` — admin.conf fetched from cp by Ansible

**To start a new session:**
1. Open Claude Code in `~/workspace/k8s-lab-infra`.
2. First message:

> Read `docs/CURRENT-STATE.md`, `docs/PHASES-4-15-EXECUTION-PLAN.md` §Phase 7,
> and `docs/LEARNING-LOG.md` section 7. Phase 5a is complete, Phase 7
> pre-work is done. Resume from the kube-prometheus-stack helm install
> (P7-3 step 1 through 6).

---

## Overall arc

| # | Phase | State |
|---|---|---|
| 0-4 | Foundation, TF infra, kubeadm, CCM, CSI, PV/PVC exercise | ✅ done |
| **5a** | **Round 2 codify — 8 Ansible roles fully idempotent against live cluster** | ✅ **done** |
| 5b | Workers → instance pool + join-vending | ⏳ deferred (no immediate consumer; Phase 15 dep) |
| **7 pre-work** | **bind-address=0.0.0.0 + 4 NSG rules** | ✅ **done** |
| **7 install** | **kube-prometheus-stack + metrics-server** | ⏭️ **RESUME HERE** |
| 7b | Loki + Fluent Bit + Grafana Loki datasource | ⏳ after 7 |
| 6 | Istio + Gateway API + LB TCP:443 | ⏳ after 7b |
| 8 | Argo CD adoption of platform | ⏳ |
| Block 11 | CI workflow (industry-standard PR→plan→apply) | ⏳ deferred |
| 9-11 | Wave-1/2 apps + promotion | ⏳ |
| 12 | k6 + chaos + teardown/rebuild rehearsal | ⏳ |
| 13-15 | ci-runner, DR drills, stretch | ⏳ |

---

## Where we paused (2026-07-10 evening)

**Phase 7 pre-work is complete and pushed** (commit `3c430d0`):
- KCM `:10257` and scheduler `:10259` bind `0.0.0.0` (verified via `ss` on
  cp; verified via worker `curl` returning 403 = TLS+RBAC authn active).
- `kubeadm-config` ConfigMap patched (via one-off Python script in
  scratchpad — not codified in Ansible; fresh rebuilds don't need it
  because kubeadm init regenerates the CM from our fixed template).
- 4 NSG rules added (workers → cp:10257, cp:10259, cp:9100; workers ↔
  workers:9100).
- Ansible roles updated: `kubeadm-cp` has idempotent `replace` tasks for
  both manifests; git ClusterConfiguration.yaml + j2 template both
  updated so rebuilds are born correct.
- Bonus fix: `cni-calico` role has a stat-guard on the tigera-operator
  manifest download (get_url in --check reported would-download without
  verifying bytes).

**Values file written and ready for tomorrow:** `k8s/observability/kps-values.yaml`
(180 lines). Includes sizing, storage note (local-path vs oci-bv), scrape
targets (kubelet/apiserver/coredns/KCM/scheduler/node-exporter/kube-state
ON; kubeEtcd/kubeProxy OFF), Grafana persistence off + ConfigMap sidecar
loading, Alertmanager with null-receiver for now (Slack webhook wired in
P7-5 as separate reviewable diff).

### Resume steps (run tomorrow morning from Mac)

Full commands with rationale live in the chat transcript, but here's the
minimum to re-orient:

```bash
# 0. sanity: cluster reachable, no drift
kubectl get nodes
cd ~/workspace/k8s-lab-infra/ansible && \
  source ~/.k8s-lab-secrets/state-backend.env && \
  ansible-playbook site.yml --check --diff | tail -6
# Expect: changed=0, failed=0 across all 3 nodes.

# 1. add helm repo
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update prometheus-community

# 2. pin chart version — pick latest 65.x from search output
helm search repo prometheus-community/kube-prometheus-stack --versions | head -3
export KPS_VERSION=<paste-latest-65.x>

# 3. namespace + admin secret (idempotent)
kubectl create ns monitoring --dry-run=client -o yaml | kubectl apply -f -
kubectl -n monitoring create secret generic grafana-admin \
  --from-literal=admin-user=admin \
  --from-literal=admin-password="$(openssl rand -base64 24)" \
  --dry-run=client -o yaml | kubectl apply -f -
kubectl -n monitoring get secret grafana-admin \
  -o jsonpath='{.data.admin-password}' | base64 -d > ~/.k8s-lab-secrets/grafana-admin-password
chmod 600 ~/.k8s-lab-secrets/grafana-admin-password

# 4. install (pinned, our values)
helm upgrade --install kps prometheus-community/kube-prometheus-stack \
  --version "$KPS_VERSION" \
  --namespace monitoring \
  -f ~/workspace/k8s-lab-infra/k8s/observability/kps-values.yaml \
  --wait --timeout 8m

# 5. verify pods + scrape targets (all 'up', especially KCM + scheduler)
kubectl -n monitoring get pods
kubectl -n monitoring port-forward svc/kps-kube-prometheus-prometheus 9090:9090 &
PF=$!
sleep 3
curl -s http://localhost:9090/api/v1/targets | \
  python3 -c 'import json,sys; d=json.load(sys.stdin); [print(f"{t[\"labels\"][\"job\"]:35s} {t[\"health\"]}") for t in d["data"]["activeTargets"]]' | sort -u
kill $PF
```

**After the install lands**: P7-4 (metrics-server), P7-5 (Alertmanager
Slack webhook + routing tree walkthrough), P7-6 (Grafana port-forward
access), then commit + push all Phase 7 additions.

---

## Phase 5a — what's on disk (all committed + pushed to `origin/main`)

Commits (in order):

| Commit | Content |
|---|---|
| `faa547a` | Phase 5 pre-work: initial push, oracle/oci provider fix, errored.tfstate deleted, 3 TF outputs added |
| `d7c9dd2` | Ansible scaffolding: ansible.cfg, group_vars/all.yml, inventory/hosts.ini, site.yml, 8 role stubs |
| `d5ec6ad` | Base roles: common, containerd, kubernetes-packages (idempotent, changed=0 on live cluster) |
| `f2e7d1b` | Phase 5a: kubeadm-cp + cni-calico roles (Jinja2 ClusterConfiguration, Tigera operator via SSA) |
| `4fdd8f5` | Phase 5a: oci-ccm + oci-csi roles (TF-outputs plumbing, snapshotter CRDs first, local-path default) |
| `af6a1dc` | Phase 5a: kubeadm-worker role (10-min token via delegate_to cp, IMDSv2 provider-id, stat guard) |
| `3c430d0` | Phase 7 pre-work: KCM/scheduler bind-address + 4 NSG rules + cni-calico stat-guard fix |

**Idempotency evidence**: after each block, `ansible-playbook site.yml
--check --diff` reports `changed=0, failed=0` on all 3 nodes. Real
apply → subsequent `--check` = zero drift.

---

## Deferred items (tracked, not lost)

- **Phase 5b — workers → instance pool + join-vending**. Autoscaling
  prereq (Phase 15). Live-cluster refactor (destroys named workers). Not
  needed for any immediate phase. Design in
  `docs/PHASES-4-15-EXECUTION-PLAN.md §Phase 5 part 5b`.

- **Block 11 — CI/CD workflow** (industry-standard PR-driven pipeline).
  User explicitly deferred to have a full design session when we get to
  it. Would include:
  - Dynamic inventory (`inventory/tf.py` reading `terraform output -json`,
    or `oracle.oci` plugin for 5b instance pool)
  - `Makefile` for both dev and CI (`make apply/check/rebuild/destroy`)
  - `.github/workflows/{ci,apply,rebuild}.yml`
  - Cloud-init boot-finished `wait_for` in site.yml pre_tasks
  - cp private IP pinning (D9 in the plan — defer real change to first
    rebuild rehearsal)
  - Environment-gated apply with required reviewer

- **`kubernetes.core.k8s` module swap**. Currently using
  `command: kubectl apply` in cni-calico/oci-ccm/oci-csi. Cleaner
  option = `kubernetes.core.k8s` (native check-mode + drift tracking).
  Requires `kubernetes` Python pkg on the target. Defensible trade-off
  either way.

- **`kubeadm-config` ConfigMap patch codified in Ansible**. Currently a
  one-off script. Not needed for fresh rebuilds. Small codification gap.

---

## State of the cluster (as of end-of-session)

- 3 nodes Ready v1.33.13: cp (10.0.1.209), worker-1 (10.0.2.230),
  worker-2 (10.0.2.100)
- Calico VXLAN CNI (iptables dataplane, BGP Disabled), all pods 1/1 Ready
- OCI CCM v1.33.2: DaemonSet 1/1 on cp; nodes have real InternalIPs,
  providerIDs (`oci://ocid1.instance.oc1.iad.*`), topology labels
- OCI CSI v1.33.2: controller 8/8 on cp, node driver 3/3; VolumeSnapshot
  CRDs (v6.3.4)
- StorageClasses: `local-path` (default), `oci-bv` (explicit)
- No PVCs live (Phase 4 exercise volumes were deleted)
- **KCM :10257 + scheduler :10259 now bind 0.0.0.0** (verified `ss` +
  worker `curl` returning 403)
- Bastion: 1.5 GB swap, sshd healthy, ControlMaster multiplexing on
  the Mac

---

## Access details

- kubectl from Mac: `ssh -N -L 6443:127.0.0.1:6443 k8s-cp` tunnel +
  `~/.kube/config`; alternate `KUBECONFIG=~/.kube/config-lab` uses the
  admin.conf that Ansible fetched from cp (server field is the private
  IP — for local use, either point kubectl through the tunnel or rewrite
  the server URL)
- SSH short names via `~/.ssh/config`: `k8s-bastion`, `k8s-cp`,
  `k8s-worker-1`, `k8s-worker-2` (ControlMaster multiplexing +
  ServerAlive keepalives)
- Bastion public IP: 157.151.226.90 (reserved)
- LB public IP: 157.151.193.45 (D8 plan: move to bootstrap so it
  survives destroy/rebuild)
- OCI CLI: `~/.oci/config` configured, `us-ashburn-1`

## Secrets (never in git)

- `~/.k8s-lab-secrets/state-backend.env` (mode 600) — MUST be sourced
  before any `terraform` command against `primary/`
- `~/.k8s-lab-secrets/grafana-admin-password` (mode 600) — created by
  P7-3 step 3 tomorrow
- `~/.ssh/k8s_lab_ed25519` — private SSH key
- `~/.oci/config` + `~/.oci/oci_api_key.pem` — OCI CLI auth

---

## Documentation layout

```
~/workspace/k8s-lab-infra/
├── docs/
│   ├── PROJECT-PLAN-v3.md          master plan + operator notes §9
│   ├── PHASES-4-15-EXECUTION-PLAN.md   per-phase action list
│   ├── PHASES-COMPLETED.md         high-level journal, phase-by-phase
│   ├── LEARNING-LOG.md             gotchas + commands (Sections 1–7)
│   └── CURRENT-STATE.md            THIS FILE (resume pointer)
├── terraform/
│   ├── bootstrap/                  compartment, state bucket, OCIR
│   ├── modules/{network,cluster-node,iam-ccm,lb}
│   └── primary/                    root; state in Object Storage
├── kubeadm/                        legacy manual configs (still git
│                                    source of truth for the shape)
├── k8s/
│   ├── storage/oci-bv-storageclass.yaml    deliberate paid SC
│   ├── observability/kps-values.yaml       Phase 7 helm values (NEW)
│   └── exercise/                    Phase 4 PV/PVC study samples
├── ansible/                        Phase 5a — 8 roles idempotent
│   ├── ansible.cfg
│   ├── group_vars/all.yml
│   ├── inventory/hosts.ini
│   ├── site.yml
│   └── roles/{common,containerd,kubernetes-packages,kubeadm-cp,
│              cni-calico,oci-ccm,oci-csi,kubeadm-worker}
└── .github/workflows/              stub — Block 11
```

Memory files at
`~/.claude/projects/-Users-satheshkumarnapoleon-workspace-project/memory/`
(auto-loaded on every response, indexed in `MEMORY.md`).

---

## If you're the future me — quick sanity check on arrival

```bash
# Are the local secrets + kubeconfig present?
ls -la ~/.k8s-lab-secrets/state-backend.env ~/.kube/config ~/.ssh/config
echo "---"
# Cluster reachable? (needs the SSH tunnel in another terminal)
ssh -N -L 6443:127.0.0.1:6443 k8s-cp &
sleep 3 && kubectl get nodes
echo "---"
# Ansible idempotency intact?
cd ~/workspace/k8s-lab-infra/ansible && \
  source ~/.k8s-lab-secrets/state-backend.env && \
  ansible-playbook site.yml --check --diff | tail -6
# Expect: 3 hosts, changed=0, failed=0
```

If all three succeed we're where we left off. Proceed to P7-3 in "Where
we paused" above.
