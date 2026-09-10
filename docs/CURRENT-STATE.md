# Where we are — resume pointer for the next session

**Last updated:** 2026-09-10 — the full DR-capstone build (production
approval gate, fresh-tenancy fixes, the Helm upgrade+rollback pipeline,
a separate plain-Helm learning reference, and the zero-touch rebuild
pipeline itself) landed across PRs #26-#42 and is confirmed live. This
entry corrects several stale claims below it (the old "Next options"
list still said the production gate and edge cert work were pending —
they're done). See "What changed 2026-09-09 night → 2026-09-10" for the
detailed diff against the previous entry. `docs/LEARNING-LOG.md` has the
incident write-ups; this file is just the resume pointer.

**New session opener:**
> Read `docs/CURRENT-STATE.md` and `docs/PHASES-COMPLETED.md` §Phase 8.
> Phases 0-8 are complete; Block 11 (CI/CD) is now green end-to-end.
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
| 8 | Argo CD — full platform GitOps | ✅ |
| **Block 11** | **CI/CD (PR → plan → gated apply → smoke-test → rollback)** | ✅ first green 2026-09-09, DR-capstone hardening (secrets bootstrap, policy-as-code, branch protection, drift check) added 2026-09-09/10 — 3 known gaps remain, see below |
| Edge | Public DNS steering → API Gateway → LB → Istio | ✅ live 2026-09-09; hand-made objects deleted; LE cert rotation built + staging-proven, production swap not yet confirmed (see below) |
| Helm ops | Atomic+rollback upgrade pipeline for Argo CD's own Helm release | ✅ live 2026-09-09 (10.8.2→10.8.4 through the new pipeline) |
| 9-15 | Apps, promotion, chaos/rebuild, runner, DR, stretch | ⏳ |

## What changed 2026-09-09 night → 2026-09-10 (since the entry below)

This closes out the DR-capstone plan (`docs/` doesn't carry the plan doc
itself — it lived in Claude's plan-mode file — but the build is real and
live):

- **Production approval gate**: done. `production` GitHub Environment
  + required reviewer gates `terraform-apply`; CD reuses the exact
  PR-reviewed plan (tree-hash verified) instead of re-planning.
- **Fresh-tenancy hardening**: 2 of 5 audit findings fixed (hardcoded
  control-plane private IP; `argo-bootstrap` secrets now wait for their
  target namespaces to exist). **3 remain open**: no Kubernetes upgrade
  path (`kubeadm upgrade` + drain/cordon + version-skew checks), no
  etcd/PVC backup (MariaDB is the one thing that would actually lose
  data on a real loss), and HPA-managed Deployments (echo, podinfo, etc.)
  have no `ignoreDifferences` on `spec.replicas` so Argo's `selfHeal`
  can still fight the HPA's own scaling decisions.
- **Zero-touch rebuild pipeline** (the actual DR capstone): `argo-bootstrap`
  now materializes every bootstrap secret from CI secrets (repo deploy
  key, both TLS certs, grafana-admin, ocir-pull, a freshly-generated
  `blog-db-credentials`) instead of by hand. `infra-cd.yml` runs
  `terraform-apply → ansible-configure → smoke-test → rollback-on-failure`
  end to end; a failure after a successful `terraform apply` opens a
  revert PR (never auto-merged, by design — see `LEARNING-LOG.md` §15).
  Two pieces are **deliberately stubbed, not silently missing**: Argo
  per-app rollback (waiting on `smoke-test` to emit structured per-app
  health) and the D8 DNS-IP-sync step (see next bullet).
- **D8 DNS-sync bug found and fixed 2026-09-10**: the sync step compared
  the LB IP against the bare apex `satheshkumarnapoleon.site`, which has
  **zero A records** in the OCI DNS zone — it could never have detected
  a real IP change. Fixed to compare against `origin.<domain>` (the
  actual write-site per `terraform/modules/edge/main.tf`) and wired in
  the real `oci dns record rrset update` call (zone OCID now exposed as
  a new `dns_zone_id` terraform output). Written, not yet tested/merged.
- **CI/policy hardening**: Conftest/OPA (`policy/risky-attrs.rego`),
  ShellCheck, pip-audit, a nightly `drift-check.yml`, and branch
  protection on `main` (required status checks, admin-enforced, linear
  history, no force-push/delete) are all live. `k8s-lab-gitops` gained
  its own CI (`gitops-ci.yml`); `k8s-lab-apps` gained `dependabot.yml`.
- **Plain-Helm learning reference** (`examples/helm-cicd-reference/`) —
  a separate, isolated CI/CD pipeline using plain `helm upgrade --atomic`
  (not Argo/GitOps) built for interview-prep purposes. Least-privilege
  RBAC, Trivy+gitleaks+kubeconform, staged promotion with a real approval
  gate, atomic+explicit rollback. Proven live end to end including a
  real production approval traversal. Does not touch or replace the
  Argo-managed fleet.
- **Edge cert rotation status**: `edge-cert.yml`'s own bugs (missing
  `terraform` setup, missing OCI CLI) are fixed and the **staging** path
  is proven live. The **production** swap has not yet actually happened:
  first attempt hit a transient DNS negative-cache (self-resolving,
  unrelated to code); the next two attempts were dispatched with
  `gh workflow run --field staging=false`, which sends the value as a
  *string* — this workflow's `type: boolean` input didn't coerce it and
  both runs silently fell back to the `default: true` (staging), so the
  live gateway cert is still the original lab-CA wildcard. Fix identified
  but not yet run: dispatch via `echo '{"staging": false}' | gh workflow
  run "edge cert rotation" --json` to send a real JSON boolean.
- Hand-made API Gateway objects (`lab-apigw`, `lab-apigw-private`,
  `acme-api-gateway`) are confirmed **deleted** live — this cleanup, listed
  as still-pending in the old "Next options" below, is actually done.

## What changed today (2026-09-09) — for context on the fixes below

Starting point: the CD pipeline had never once gotten past the Ansible
config-management stage. In order, this session:

1. Migrated the Terraform state backend from an S3-compatible shim to
   the native `oci` backend (Terraform ≥1.12) — drops the AWS-shaped
   credential class entirely. `terraform.tfvars` (non-secret OCIDs/config)
   is now committed to git; only real secrets stay out.
2. Root-caused and fixed the CD SSH-key failure: GitHub Actions'
   `${{ secrets.X }}` interpolation strips a trailing newline that
   OpenSSH's OpenSSH-format key parser requires (`printf '%s'` →
   `printf '%s\n'`).
3. Built the `argo-bootstrap` Ansible role — the long-documented-but-never-
   built D4 gap (Argo CD install + every bootstrap secret + `root-app.yaml`,
   previously always done by hand on every rebuild). Found and fixed
   inside it: helm was never installed anywhere by code (only ever by
   hand); a controller-vs-runner path bug (manifests referenced by a
   controller-local path, but the commands run on the node over SSH); a
   stale chart-version pin that would have silently downgraded the whole
   GitOps control plane.
4. Built `terraform/modules/edge`: public DNS steering (FAILOVER) → API
   Gateway → the existing LB → Istio, replacing hand-made OCI objects,
   per explicit request. Adversarial review caught a real bug before
   merge (health check TLS/hostname mismatch that would have made the
   gateway path silently never activate) — fixed with a dedicated
   `edge-probe.<domain>` CNAME. Verified live end-to-end: public hostnames
   resolve through the real GoDaddy→OCI-DNS→steering→gateway→origin→Istio
   chain.
5. Fixed two independent bugs in `smoke-test`, both real and both never
   exercised before because nothing had gotten this far: a bare `ssh -J`
   doesn't reliably carry the identity file to this bastion (fixed with
   the same `ProxyCommand` pattern used elsewhere in this repo), and a
   GitHub Actions skip-propagation gotcha meant `smoke-test` silently
   never ran at all unless the same push also touched `terraform/**`.
6. Fixed the `rollback-on-failure` safety net: the repo setting "Allow
   GitHub Actions to create and approve pull requests" was off, so its
   revert-PR step always failed silently after a real failure.

Also merged (already-green, previously-idle) `k8s-lab-gitops` PRs: HPA
for demo services, SLO dashboards (per-service + fleet), a NaN-in-table
fix for the fleet dashboard, and a Grafana memory-limit fix (was
CrashLooping on OOM).

## Phase 8 end state (unchanged from before — see prior LEARNING-LOG entries for detail)

- Argo fleet = `platform-root` + 15 children (app-of-apps over
  `k8s-lab-gitops/applications/`). All 16 Applications Synced/Healthy as
  of the 2026-09-09 smoke-test run.
- `automated + selfHeal` everywhere; prune TRUE on ordinary apps, FALSE on
  CRD carriers + `platform-root`.
- Kiali stays Helm-managed (random `signing_key` = non-deterministic
  render) — the sole Helm-managed release left; everything else is Argo.
- CCM/CSI/CNI stay Ansible-owned (GitOps horizon / rebuild-ordering
  constraint).
- Rebuild story, now real rather than aspirational: `terraform apply` →
  `ansible-playbook site.yml` (installs k8s, CNI, CCM, CSI, Gateway API
  CRDs, **and now Argo CD + every bootstrap secret via `argo-bootstrap`**)
  → `root-app.yaml` applied by the same role → platform cascades by
  sync-wave → `smoke-test` verifies the whole thing. No manual step in
  that chain anymore except the PR-then-merge approval itself.

## Live cluster

3 nodes Ready v1.33.13 · public LB + internal NodePort-only gateway ·
edge: DNS steering (FAILOVER) → API Gateway → LB, live for grafana/echo/
blog/podinfo/db-admin/hello-api/httpbin (intranet deliberately excluded —
no LB listener) · echo 90/10 canary · blog stack (WordPress + Adminer +
MariaDB) · full observability in one Grafana (metrics + mesh + logs) +
new SLO dashboards (per-service + fleet: availability, latency
percentiles, error budget, burn rate) · cert lab-CA wildcard expires
2027-07-12, gateway uses the same wildcard as a stopgap pending a
Let's-Encrypt-via-OCI-DNS follow-up.

## Next options (in rough priority order) — updated 2026-09-10

1. **Finish the production LE cert swap**: dispatch `edge-cert.yml` with
   a real JSON boolean (see bullet above) and confirm live that the
   gateway actually serves a Let's-Encrypt cert, not just that the run
   goes green.
2. **Commit + test the D8 DNS-sync fix** (written, not yet merged) —
   verify `terraform output -raw dns_zone_id` resolves post-merge and the
   `oci dns record rrset update` call is correct against the live zone
   before trusting it to run unattended on a real IP change.
3. **Remaining fresh-tenancy gaps** (3 of the original 5, see above):
   Kubernetes upgrade path, etcd/PVC backup, HPA-vs-selfHeal
   `ignoreDifferences`. None started.
4. **Argo per-app rollback**: extend `smoke-test` to emit structured
   per-app Synced/Healthy results (not just a single pass/fail), then
   wire `rollback-on-failure` to call the per-app rollback instead of its
   current stub.
5. **Full destroy-and-rebuild drill**: the one thing that would actually
   *prove* the zero-touch pipeline end to end. Deliberately not attempted
   yet — this lab has no second environment to rehearse against, so this
   needs a joint, scheduled decision before running it for real (not
   something to do unattended).
6. **Phase 9 proper / Demo C** (Argo Rollouts automated canary) — Phase
   9-lite (CI → OCIR → gitops → Argo, zero human steps) already complete
   since 2026-07-16; this is the next rung up.
7. **`k8s-lab-apps` round-out** — `dependabot.yml` added 2026-09-09;
   unverified whether further CI parity work is still needed.

## Standing invariants

- Execution rule: EVERYTHING gated (Approve / I'll do it buttons) for
  anything live/destructive; PR review + merge is the code-change gate.
- Commit cadence: per logical unit, detailed messages with the WHY and
  the evidence, not a diff narration.
- Secrets never in git. Non-secret config (OCIDs, domain names, zone IDs)
  is fine committed — see `terraform/primary/terraform.tfvars`.
- Never `helm uninstall` an adopted release; never prune CRD carriers.

## Sanity check on arrival

```bash
export KUBECONFIG=~/.kube/config-lab
# If the apiserver refuses connection, the SSH tunnel isn't up:
#   ssh -f -N -L 6443:127.0.0.1:6443 -o ExitOnForwardFailure=yes k8s-cp
kubectl get nodes                                    # 3 Ready
kubectl -n argocd get applications                    # 16/16 Synced/Healthy
for h in echo blog grafana; do curl -sk -o /dev/null -w "$h %{http_code}\n" \
  "https://${h}.satheshkumarnapoleon.site/"; done     # via the edge/DNS-steering path now, not a direct LB IP
gh run list --repo nskgit/k8s-lab-infra --workflow "infra CD" --limit 1   # should be the latest, green
```
