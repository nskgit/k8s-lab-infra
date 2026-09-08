# .github/workflows

- `infra-ci.yml` — static checks (fmt/validate/tflint, Trivy IaC, gitleaks,
  actionlint, ansible-lint + syntax-check, shellcheck, pip-audit) on every
  PR and push to main, plus a PR-only `terraform-plan` job: real plan +
  the `policy/*.rego` risky-attribute check (warn-only here), posted as a
  PR comment. Zero cloud credentials except in `terraform-plan`.
- `infra-cd.yml` — merge-triggered CD. The PR review + merge in
  `infra-ci.yml` **is** the approval gate; there is no separate manual
  dispatch step. Re-plans and re-runs the risky-attribute policy check as
  a **hard fail** gate right before `terraform apply` (a merge-time
  finding means something changed that nobody reviewed). Then: Ansible
  configuration management (OS/runtime/k8s packages, CNI, CCM, CSI,
  Gateway API CRDs, and `argo-bootstrap` — Argo CD install + all bootstrap
  secrets + `root-app.yaml`) → smoke-test (nodes Ready, Argo Apps
  Healthy, public URLs 2xx/3xx) → on failure, a bot-opened (never
  auto-merged) revert PR for the terraform layer, or a per-app
  `argocd app rollback` for the Argo layer.
- `drift-check.yml` — nightly scheduled `terraform plan`, read-only.
  Flags out-of-band drift; no chat/alerting wired up yet (a workflow
  annotation is the only signal today).

Full design rationale, the secrets each of these needs, and the open
decisions/limitations: `docs/LEARNING-LOG.md` §15 and the plan doc from
that build (kept out of the repo — see chat history if you need it
again).
