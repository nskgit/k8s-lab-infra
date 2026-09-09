# .github/workflows

- `infra-ci.yml` — static checks (fmt/validate/tflint, Trivy IaC, gitleaks,
  actionlint, ansible-lint + syntax-check, shellcheck, pip-audit) on every
  PR, plus a PR-only `terraform-plan` job: real plan + the `policy/*.rego`
  risky-attribute check (warn-only here), posted as a PR comment, **and
  uploaded (encrypted) as the artifact CD applies after merge**. On push
  to main only gitleaks and Trivy/Checkov re-run (history scan + Security
  tab); the rest is byte-identical to the PR head thanks to branch
  protection's "require up to date". Zero cloud credentials except in
  `terraform-plan`.
- `infra-cd.yml` — merge-triggered CD with two separate gates:
  1. **merge** — branch protection on `main` (required checks + PR;
     `required_approving_review_count: 0` is the solo-maintainer
     compromise, since an author can't approve their own PR).
  2. **deploy** — the `approve` job targets the `production` GitHub
     Environment, whose required reviewer must approve in the Actions UI
     before anything mutates. One approval per run.
  Then `terraform-apply` applies **the exact plan the PR reviewer saw**
  (downloaded from the PR-time CI run, tree-hash-verified against the
  merge commit). Terraform refuses a stale saved plan, so drift between
  review and apply fails closed; `workflow_dispatch` with `force_replan`
  is the recovery. Only when no reviewed plan exists (Dependabot PR,
  expired artifact) does it re-plan — with the policy check as a **hard
  fail**. Then: Ansible configuration management (OS/runtime/k8s packages,
  CNI, CCM, CSI, Gateway API CRDs, and `argo-bootstrap` — helm + Argo CD
  install + all bootstrap secrets + `root-app.yaml`) → smoke-test (nodes
  Ready, Argo Apps Healthy, public URLs 2xx/3xx) → on failure, a
  bot-opened (never auto-merged) revert PR for the terraform layer, or a
  per-app `argocd app rollback` for the Argo layer.

  Repo settings this depends on (applied via `gh api`, not in code):
  branch protection on `main` (strict required status checks = every CI
  job, linear history, no force-push/delete, conversation resolution,
  enforced for admins) and the `production` environment (required
  reviewer = repo owner, protected branches only). Secrets: everything
  listed in `infra-cd.yml` plus `TFPLAN_PASSPHRASE` (symmetric key for
  the plan artifact).
- `drift-check.yml` — nightly scheduled `terraform plan`, read-only.
  Flags out-of-band drift; no chat/alerting wired up yet (a workflow
  annotation is the only signal today).

Full design rationale, the secrets each of these needs, and the open
decisions/limitations: `docs/LEARNING-LOG.md` §15 and the plan doc from
that build (kept out of the repo — see chat history if you need it
again).
