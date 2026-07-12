# Where we are — resume pointer for the next session

**Last updated:** 2026-07-11 midday — Phase 7 metrics **effectively complete**
(pre-work + kube-prometheus-stack + metrics-server + Grafana walkthrough +
Alertmanager design walkthrough all done). **Resume with Phase 7b (Loki +
Fluent Bit logging)** — see "Where we paused" below.

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

> Read `docs/CURRENT-STATE.md`, `docs/PHASES-4-15-EXECUTION-PLAN.md` §Phase 7b,
> and `docs/LEARNING-LOG.md` section 7. Phase 5a complete, Phase 7 metrics
> complete (kps + metrics-server + AM/Grafana walkthroughs). Resume with
> Phase 7b: Loki + Fluent Bit logging.

---

## Overall arc

| # | Phase | State |
|---|---|---|
| 0-4 | Foundation, TF infra, kubeadm, CCM, CSI, PV/PVC exercise | ✅ done |
| **5a** | **Round 2 codify — 8 Ansible roles fully idempotent against live cluster** | ✅ **done** |
| 5b | Workers → instance pool + join-vending | ⏳ deferred (no immediate consumer; Phase 15 dep) |
| **7 pre-work** | **bind-address=0.0.0.0 + 4 NSG rules** | ✅ **done** |
| **7 install** | **kube-prometheus-stack + metrics-server + AM walkthrough + Grafana tour** | ✅ **done** |
| **7b** | **Loki + Fluent Bit + Grafana Loki datasource** | ⏭️ **RESUME HERE** |
| 6 | Istio + Gateway API + LB TCP:443 | ⏳ after 7b |
| 8 | Argo CD adoption of platform | ⏳ |
| Block 11 | CI workflow (industry-standard PR→plan→apply) | ⏳ deferred |
| 9-11 | Wave-1/2 apps + promotion | ⏳ |
| 12 | k6 + chaos + teardown/rebuild rehearsal | ⏳ |
| 13-15 | ci-runner, DR drills, stretch | ⏳ |

---

## Where we paused (2026-07-11 midday)

**Phase 7 metrics is done end-to-end.** kube-prometheus-stack chart
`87.12.3` and metrics-server both installed, verified, and committed.
Grafana and Alertmanager walkthroughs complete. Slack webhook wiring
teed up (Secret + `api_url_file` pattern, values.yaml diff prepared in
chat) but not applied — parked until a webhook URL is available.

Live cluster state:
- 3 nodes Ready v1.33.13; all workloads healthy.
- `monitoring/` namespace: 8 kps pods Running + `metrics-server` in
  `kube-system` Running. `kubectl top nodes/pods` works.
- Prometheus `/targets`: all 11 scrape jobs UP. KCM + scheduler + cp
  node-exporter all healthy → Phase 7 pre-work acceptance test passed.
- Alertmanager: currently null-receiver (alerts fire but don't leave the
  pod). `Watchdog` canary firing as designed.
- Grafana: 27 dashboards auto-loaded via ConfigMap sidecar; admin
  password in `~/.k8s-lab-secrets/grafana-admin-password`.

### Resume steps for the NEXT session — Phase 7b (Loki + Fluent Bit)

Phase 7b design (from `docs/PHASES-4-15-EXECUTION-PLAN.md §Phase 7b`):

- **Loki**: `SingleBinary` mode, 1 replica, filesystem storage on 5 Gi
  local-path PVC, 72h retention, all caches/canary/gateway disabled
  (chart defaults would never fit our 8 GiB nodes).
- **Fluent Bit** DaemonSet as the log collector/parser — the
  load-bearing config detail is the **CRI multiline parser** (containerd
  writes `<rfc3339> stdout F msg` format; docker/JSON parser silently
  mangles every line). Plus a control-plane toleration so cp's
  apiserver/etcd/scheduler logs are collected.
- **Grafana Loki datasource**: one values entry in kube-prometheus-stack
  OR a labeled ConfigMap (`grafana_datasource: "1"`) picked up by the
  Grafana sidecar we set up in Phase 7.
- Total budget: ~0.35 CPU / ~600 MiB across all three components.
- **No NSG changes** — traffic is all in-cluster VXLAN.

Rough shape of the resume commands:

```bash
# 0. sanity
kubectl get nodes
kubectl -n monitoring get pods            # kps still healthy?
kubectl top nodes                         # metrics-server still healthy?

# 1. new values files (design first in chat, then write to k8s/observability/)
#   loki-values.yaml
#   fluent-bit-values.yaml

# 2. helm repos
helm repo add grafana https://grafana.github.io/helm-charts
helm repo add fluent  https://fluent.github.io/helm-charts
helm repo update

# 3. install Loki (SingleBinary sizing) — pinned chart
helm search repo grafana/loki --versions | head -3
export LOKI_VERSION=<pin>
helm upgrade --install loki grafana/loki \
  --version "$LOKI_VERSION" -n monitoring \
  -f ~/workspace/k8s-lab-infra/k8s/observability/loki-values.yaml \
  --wait --timeout 8m --disable-openapi-validation

# 4. install Fluent Bit (with CRI multiline parser + cp toleration)
helm search repo fluent/fluent-bit --versions | head -3
export FB_VERSION=<pin>
helm upgrade --install fluent-bit fluent/fluent-bit \
  --version "$FB_VERSION" -n monitoring \
  -f ~/workspace/k8s-lab-infra/k8s/observability/fluent-bit-values.yaml \
  --wait --timeout 5m --disable-openapi-validation

# 5. wire Loki datasource into Grafana
#    (label a ConfigMap grafana_datasource=1 → sidecar picks it up automatically)

# 6. verify: Grafana → Explore → Loki datasource → LogQL like:
#    {namespace="kube-system"} |= "error"
```

### After 7b lands

Phase 7 metrics + logging both complete. Next options (user choice):
- **Phase 6** — Istio + Gateway API + LB TCP:443 (real TF changes)
- **Phase 8** — Argo CD adoption of the whole observability platform
- **P7-5b** — wire Slack to Alertmanager (5 min if webhook available)

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
| `123b8cc` | Docs refresh (Phase 5a/7 pre-work full write-up in CURRENT-STATE / PHASES-COMPLETED / LEARNING-LOG); k8s/observability/kps-values.yaml |
| `dd14a27` | Phase 7 install: fix `cpu: null` → memory-only limit; kps landed clean (chart 87.12.3) |
| `7e9f9bb` | Phase 7: metrics-server values + install (kubectl top works, HPA prereq) |

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
  providerIDs, topology labels
- OCI CSI v1.33.2: controller 8/8 on cp, node driver 3/3; VolumeSnapshot
  CRDs (v6.3.4)
- StorageClasses: `local-path` (default), `oci-bv` (explicit)
- **PVCs live now**: 1× Prometheus (8Gi local-path), 1× Alertmanager
  (1Gi local-path) — from Phase 7 install
- **KCM :10257 + scheduler :10259 bind 0.0.0.0** (Phase 7 pre-work)
- **Phase 7 observability stack running in `monitoring/` namespace**:
  Prometheus (kps-prometheus-0), Alertmanager (kps-alertmanager-0),
  Grafana (3 containers), Prometheus operator, kube-state-metrics,
  node-exporter DS (3 pods including cp), plus metrics-server in
  `kube-system`. All targets UP; 27 dashboards loaded; `Watchdog`
  canary firing to null-receiver as designed.
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
- `~/.k8s-lab-secrets/grafana-admin-password` (mode 600) — created
  Phase 7. `admin` + this password logs into Grafana at port-forward
  `svc/kps-grafana 3000:80` → http://localhost:3000
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
│   ├── observability/
│   │   ├── kps-values.yaml                 Phase 7 metrics stack (kps 87.12.3)
│   │   └── metrics-server-values.yaml      Phase 7 metrics-server
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
