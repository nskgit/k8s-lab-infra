# Where we are — resume pointer for the next session

**Last updated:** 2026-09-08 — **INCIDENT + RECOVERY** (LEARNING-LOG §15).
A rename-triggered `terraform apply` on `primary/` silently wiped all 3
boot volumes (root cause: unpinned "latest image" data source drift —
see §15, unrelated to the rename itself). Full Ansible+Argo rebuild
recovered **15/16** apps Synced/Healthy; only `hello-api` is down,
waiting on a fresh OCIR auth token from the operator (old one was never
recoverable — OCI shows it once, at creation). Fixes already made as
file edits (NOT yet re-tested against the live cluster — pending
Approve): `cluster-node` module now freezes `source_details` via
`lifecycle.ignore_changes`; `site.yml` role order fixed (oci-ccm before
cni-calico; oci-csi moved after workers join); new `gateway-api` role
closes the last manual-step gap. **The repo/resource rename to
"platform-engine" is PAUSED** — only the OCI compartment/tf-vars layer
was touched before the incident; no repo consolidation, no doc rewrite,
no visibility change yet. **Next: resume Block 11** (CD half — B11-2
plan job onward) extended to close the gaps above and bring CI to
`k8s-lab-gitops` (currently zero CI) and round out `k8s-lab-apps`, per
explicit user ask 2026-09-08 — see "Next options" §1.

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
| P9-0a | Demo A — GitOps rolling update | Phase 9 pre-work | ✅ 2026-07-16 (via stage-4 bot, own service) |
| P9-0b | Demo B — git-driven canary | Phase 9 pre-work | ✅ 2026-07-16 (90/10→50/50→revert; 15/15 measured; zero pod churn) |
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
1. **Block 11 IN PROGRESS (started 2026-07-16 evening)** — B11-1 ✅:
   infra-ci.yml 5 jobs GREEN on main (fmt/validate/tflint · Trivy IaC ·
   gitleaks · actionlint · ansible-lint@production); dependabot live,
   flood tamed (grouped actions PR #12 merged; oci majors ignored —
   6->8 = scheduled migration); ansible-lint 32->0 with live changed=0
   re-verified. CI SECRETS IN PLACE (5): AWS_* state keys,
   OCI_CONFIG_FILE_CONTENT, OCI_PRIVATE_KEY_PEM, SSH_PRIVATE_KEY.
   gh CLI authed — assistant can watch private-repo runs.
   **RESUME AT B11-2**: write the plan job (runner ~/.oci setup with
   key_file rewrite, backend init + AWS checksum env vars, plan both
   roots, PR comment + tfplan.bin artifact on main). Then B11-3
   dispatch-gated apply + nightly drift; B11-4 oracle.oci dynamic
   inventory (decided) + ansible leg; B11-5 verify stage + docs.
   Lessons so far: LEARNING-LOG §14. Was: **Block 11** (the deferred
   industry-standard session): PR checks + tf plan/ansible --check on
   PR + gated apply; dynamic inventory; Makefile; cp IP pin D9;
   security gates adopted 2026-07-14: tflint · tfsec · gitleaks · Dependabot
   (full bucketing in execution plan §Block 11 addendum).
   **EXPANDED SCOPE 2026-09-08** (post-incident, explicit user ask —
   "build CI/CD for all the gaps, automate fully for all repos"):
   - B11-2's plan job must add a **risky-attribute guard**: grep the
     plan JSON for non-ForceNew-but-actually-destructive fields
     (`source_details`, instance `metadata`) and fail/require manual
     sign-off even when Terraform's own destroy/ForceNew count is zero
     — directly born from §15 (a "0 destroy" plan still wiped 3 boot
     volumes).
   - `ansible/site.yml`'s B11-4 CD leg should run `--check --diff` and
     assert `changed=0` post-apply as a matter of course — it would
     have caught the wipe (bare-OS node ≠ changed=0) before anyone
     needed to notice manually.
   - `k8s-lab-gitops` has **zero CI today** — needs manifest/kustomize
     validation, kubeconform/kubeval against installed CRDs (so a
     Gateway-API-shaped gap like §15 fails CI, not a live sync), and a
     lint gate, mirroring infra-ci.yml's style.
   - `k8s-lab-apps` has `hello-api-ci.yml` only — round out to match
     the "fully automated, no manual steps" bar (audit for other
     manual gaps the way §15 was found for infra/ansible).
   - Terraform *apply* itself stays dispatch-gated / human-approved
     per the project's standing execution rule — "full automation" here
     means removing manual steps from build/validate/deploy-of-manifests,
     not removing the human from an infra-destructive `apply`.
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
kubectl -n argocd get applications          # 15/16 Synced/Healthy (hello-api pending OCIR token, §15)
kubectl get nodes                            # 3 Ready
for h in echo blog grafana; do curl -s --cacert ~/.k8s-lab-secrets/lab-ca/lab-root-ca.crt \
  -o /dev/null -w "$h %{http_code}\n" https://$h.satheshkumarnapoleon.site/; done
cd ~/workspace/k8s-lab-infra/ansible && source ~/.k8s-lab-secrets/state-backend.env && \
  ansible-playbook site.yml --check --diff 2>&1 | tail -4   # changed=0
```
