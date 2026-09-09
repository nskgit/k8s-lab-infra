# Where we are — resume pointer for the next session

**Last updated:** 2026-09-09 — **Block 11 (CI/CD) reached its first
fully-green, fully-automated run.** `terraform-apply -> ansible-configure
(incl. argo-bootstrap) -> smoke-test` all ran for real and passed in the
same CD run for the first time in this project's history: nodes Ready,
all 16 Argo Applications Synced/Healthy, public URLs 2xx/3xx. Getting
here required fixing several real, previously-unexercised bugs — see
"What changed today" below. `docs/LEARNING-LOG.md` has the incident
write-ups; this file is just the resume pointer.

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
| **Block 11** | **CI/CD (PR → plan → gated apply → smoke-test)** | ✅ **first fully-green run 2026-09-09** — hardening items remain, see below |
| Edge | Public DNS steering → API Gateway → LB → Istio | ✅ live 2026-09-09 (not in original phase plan — built on explicit request) |
| 9-15 | Apps, promotion, chaos/rebuild, runner, DR, stretch | ⏳ |

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

## Next options (in rough priority order)

1. **Production approval gate** (`feat/prod-gates`, pushed but no PR yet):
   a `production` GitHub Environment with a required reviewer gating
   `terraform-apply`, plus CD applying the exact plan a PR reviewer saw
   (uploaded encrypted from `infra-ci.yml`, tree-hash-verified against the
   merge commit) instead of re-planning. Needs the operator's go-ahead on
   4 repo settings (environment, branch protection, a new
   `TFPLAN_PASSPHRASE` secret, and — already done — the Actions
   PR-creation permission) before the PR can be opened for real.
2. **Fresh-tenancy / upgrade-safety hardening** — two deep audits done
   2026-09-09 found real gaps, none yet fixed: hardcoded control-plane
   private IP (breaks a fresh cluster), `argo-bootstrap`'s secrets created
   before their target namespaces exist on a truly fresh cluster, no
   Kubernetes upgrade path at all (`kubeadm upgrade` + drain/cordon +
   version-skew checks), no etcd/PVC backup (MariaDB is the one thing
   that would actually lose data), HPAs fighting Argo's `selfHeal` on
   `spec.replicas`. A 5-agent parallel batch to fix the first few of
   these was started and hit a session token limit before landing
   anything — needs a clean retry.
3. **Edge follow-up**: replace the day-1 lab-wildcard cert on the API
   Gateway with a scheduled Let's-Encrypt-via-OCI-DNS-01 workflow
   (`edge_certificate_pem`/`key_pem` already isolated as their own
   Terraform variables specifically so this swap doesn't need a redesign).
   Also: delete the hand-made `lab-apigw`/`lab-apigw-private`/`steer-api`/
   `hc-apigw`/LB-listener-`h1` objects the new `modules/edge` replaces —
   deliberately deferred as a separate, reviewed cleanup step.
4. **Phase 9 proper / Demo C** (Argo Rollouts automated canary) — Phase
   9-lite (CI → OCIR → gitops → Argo, zero human steps) already complete
   since 2026-07-16; this is the next rung up.
5. **`k8s-lab-apps` round-out** — not touched this session; the original
   Block 11 scope called for auditing it the way §15 was found for
   infra/ansible (dependabot, CI parity). Unverified whether this is
   still needed.

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
