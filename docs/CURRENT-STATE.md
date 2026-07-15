# Where we are — resume pointer for the next session

**Last updated:** 2026-07-16 — **PHASE 9-LITE COMPLETE** (on top of 8/8.5 + repo split). The entire platform is
GitOps-managed by Argo CD with auto-sync + selfHeal live (drift-undo
validated). Git push = deployment. **Next: user picks** — Block 11 (CI/CD),
Phase 9 (wave-1 apps), or smaller items below.

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
| B11-0a | Gitops repo split | Block 11 step 0 | ✅ DONE 2026-07-16 — Argo now reads nskgit/k8s-lab-gitops |
| B11-0b | Demo D — TF workspaces (zero-cost, env:/ prefixes) | Block 11 pre-work | ready anytime |
| B11/12+14 | Fully-automated multi-env (CI matrix per env root; DR = capstone) | Block 11/12 + Phase 14 | follows D |

## Next options

0. **Phase 9-lite COMPLETE 2026-07-16** — full code→cluster loop live:
   apps CI (5 jobs, 6-run/5-catch journey, LEARNING-LOG §13) → OCIR
   (hello-api:git-sha) → gitops → Argo → hello-api serving at
   hello-api.satheshkumarnapoleon.site (probes, mesh, 4 scrape targets).
   Fleet 16/16. **STAGE 4 LIVE 2026-07-16 evening**: bump-gitops bot
   (fine-grained PAT) — merge in apps repo → ~6 min later serving on
   cluster, zero human steps (first bot commit: gitops@1d84663; live
   flip fb02ff8→4c9637e observed = Demo A completed via automation).
   HYGIENE: confirm OCIR auth token rotation done (was exposed).
1. **Block 11 — CI/CD workflows** (the deferred
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
kubectl -n argocd get applications          # 16/16 Synced/Healthy
kubectl get nodes                            # 3 Ready
for h in echo blog grafana; do curl -s --cacert ~/.k8s-lab-secrets/lab-ca/lab-root-ca.crt \
  -o /dev/null -w "$h %{http_code}\n" https://$h.satheshkumarnapoleon.site/; done
cd ~/workspace/k8s-lab-infra/ansible && source ~/.k8s-lab-secrets/state-backend.env && \
  ansible-playbook site.yml --check --diff 2>&1 | tail -4   # changed=0
```
