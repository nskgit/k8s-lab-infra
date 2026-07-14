# Where we are — resume pointer for the next session

**Last updated:** 2026-07-14 — **PHASE 8 COMPLETE.** The entire platform is
GitOps-managed by Argo CD with auto-sync + selfHeal live (drift-undo
validated). Git push = deployment. **Next: user picks** — Block 11 (CI/CD),
Phase 9 (wave-1 apps), or smaller items below.

## ⏰ MORNING CUTOVER — repo split staged 2026-07-15 night, 2 user steps left

Everything is prepped and validated; local repo `~/workspace/k8s-lab-gitops`
(remote set, commit `5b09ebc`) is ready to push. Argo Secret
`repo-k8s-lab-gitops` already in cluster. USER does (60s total):
1. github.com/new → create PRIVATE repo `k8s-lab-gitops` (no README/license).
2. Repo → Settings → Deploy keys → Add: paste
   `~/.k8s-lab-secrets/argocd/argocd-gitops-deploy.key.pub`
   (title `argocd-readonly`, do NOT allow write).
Then Claude finishes: push new repo → kubectl apply
`~/workspace/k8s-lab-gitops/bootstrap/root-app.yaml` → fleet re-points
(15/15, no freeze window — old tree still exists in infra repo during
cutover) → push held infra cleanup commit → delete old
`repo-k8s-lab-infra` secret → final docs/memory sweep.

**New session opener:**
> Read `docs/CURRENT-STATE.md` and `docs/PHASES-COMPLETED.md` §Phase 8.
> Phases 0-5a, 6, 7(+7b), 8 are complete. Pick up from "Next options".
> HARD RULE: never execute anything without explicit Approve — propose
> each step with AskUserQuestion buttons (see memory feedback-execution-style).

---

## Overall arc

| # | Phase | State |
|---|---|---|
| 0-4 | Foundation, TF, kubeadm, CCM, CSI | ✅ |
| 5a | 8 idempotent Ansible roles | ✅ |
| 5b | Workers → instance pool | ⏳ deferred (Phase 15 dep) |
| 6 | Istio + Gateway API + real domain (+SNI 2nd domain, internal gw) | ✅ |
| 7 / 7b | kube-prometheus-stack, metrics-server, Kiali, Loki, Fluent Bit | ✅ |
| **8** | **Argo CD — full platform GitOps** | ✅ **done 2026-07-14** |
| Block 11 | CI/CD (PR → plan → gated apply) | ⏭️ top candidate |
| 9-15 | Apps, promotion, chaos/rebuild, runner, DR, stretch | ⏳ |

## Phase 8 end state (what the next session inherits)

- **Argo fleet = platform-root + 14 children** (app-of-apps over
  `gitops/applications/`): 9 Phase 8 adoptions (istio-base, istiod,
  istio-ingressgateway, istio-internal-gateway, kube-prometheus-stack,
  loki, fluent-bit, metrics-server, podinfo) + 5 coverage-gap closers
  added 2026-07-15 (namespaces, gateways, observability-extras,
  demo-extras, blog).
- **2026-07-15 restructure**: `k8s/` renamed to `gitops/` with standard
  layout (bootstrap/ · applications/ · platform/ · workloads/);
  exercises moved out to `exercises/`. StorageClass stays Ansible-owned
  (oci-csi role); Kiali stays the Helm exception.
- **automated + selfHeal everywhere**; prune TRUE on 7 ordinary apps,
  FALSE on CRD carriers (istio-base, kps) + platform-root (finalizer
  cascade guard). No root/child policy precedence — disjoint object sets.
- **Kiali NOT adopted** (random signing_key = non-deterministic render)
  — stays Helm-managed, the sole helm release left.
- **ccm-csi + CNI stay Ansible-owned** (GitOps horizon / rebuild
  deadlock; patterns A/B/C recorded — B = Phase 15 stretch).
- Argo: controller limit 1Gi (512Mi OOM lesson), repo-server 512Mi,
  annotation tracking, v1/Endpoints UN-excluded (kps scrape Endpoints
  managed; rebuild-complete), read-only SSH deploy key for the private
  repo (`~/.k8s-lab-secrets/argocd/`).
- CLI: `ARGOCD_OPTS='--core'` + kube-context ns=argocd (port-forward
  gRPC is flaky); big-app diffs via REST API classifier (LEARNING-LOG §11).
- Rebuild story: TF → Ansible (installs Argo per D4) → `kubectl apply
  -f gitops/bootstrap/root-app.yaml` → platform cascades by sync-wave.
- **Who-manages-the-root**: root-app.yaml changes need a manual kubectl
  apply (or move it into its own watched dir for self-management).

## Live cluster (unchanged from Phase 7 state plus Argo)

3 nodes Ready v1.33.13 · 2 gateways (public LB + internal NodePort-only)
· 2 domains (pldisturbme.site DNS still pending; test via --resolve) ·
6 public hostnames + intranet · echo 90/10 canary · blog stack (WordPress
+ Adminer + MariaDB no-sidecar) · full observability in one Grafana
(metrics + mesh + logs) · Alertmanager on null-receiver (Slack designed,
needs webhook) · cert lab-CA wildcard expires 2027-07-12.

## Learning queue — now phase-mapped (run on user's "go"; do NOT drop from status)

| Tag | Item | Phase home | State |
|---|---|---|---|
| P9-0a | Demo A — GitOps rolling update (podinfo tag bump) | Phase 9 pre-work | ready anytime |
| P9-0b | Demo B — git-driven canary (echo 90/10→50/50 via commit) | Phase 9 pre-work | ready — prereq done 2026-07-15 |
| P9 | Demo C — Argo Rollouts (automated canary; top of the A→B→C ladder) | Phase 9 proper | with Phase 9 |
| B11-0a | Gitops repo split | Block 11 step 0 | DECIDED+staged; morning cutover (see banner) |
| B11-0b | Demo D — TF workspaces (zero-cost, env:/ prefixes) | Block 11 pre-work | ready anytime |
| B11/12+14 | Fully-automated multi-env (CI matrix per env root; DR = capstone) | Block 11/12 + Phase 14 | follows D |

## Next options

1. **Block 11 — CI/CD workflows** (top candidate; the deferred
   industry-standard session): PR checks + tf plan/ansible --check on
   PR + gated apply; dynamic inventory; Makefile; cp IP pin D9;
   security gates adopted 2026-07-14: tflint · tfsec · gitleaks · Dependabot
   (full bucketing in execution plan §Block 11 addendum).
2. **Phase 9 — wave-1 apps**: OCIR robot users, shared chart
   (Deployment/Service/HTTPRoute/DestinationRule/ServiceMonitor
   templates — rules already captured in plan row 7/9), CI → dev.
3. Small: Slack webhook (AM wiring ready) · cert-manager HTTP-01 ·
   Istio Grafana dashboards · tracing (Tempo, better at Phase 9) ·
   Kiali adoption via pinned signing_key if ever wanted.

## Standing invariants

- Execution rule: EVERYTHING gated (Approve / I'll do it buttons).
- Commit cadence: per logical unit, detailed messages with lessons.
- `source ~/.k8s-lab-secrets/state-backend.env` before ANY terraform.
- Never `helm uninstall` an adopted release; never prune CRD carriers.
- Secrets never in git (deploy key, grafana pwd, DB creds, lab CA).

## Sanity check on arrival

```bash
kubectl -n argocd get applications          # 15/15 Synced/Healthy
kubectl get nodes                            # 3 Ready
for h in echo blog grafana; do curl -s --cacert ~/.k8s-lab-secrets/lab-ca/lab-root-ca.crt \
  -o /dev/null -w "$h %{http_code}\n" https://$h.satheshkumarnapoleon.site/; done
cd ~/workspace/k8s-lab-infra/ansible && source ~/.k8s-lab-secrets/state-backend.env && \
  ansible-playbook site.yml --check --diff 2>&1 | tail -4   # changed=0
```
