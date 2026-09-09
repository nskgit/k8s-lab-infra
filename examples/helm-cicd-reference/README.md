# Plain-Helm CI/CD — learning reference

A real, runnable, industry-standard CI/CD pipeline for `helm install` /
`upgrade` / `rollback`, built deliberately **outside** this project's
normal GitOps (Argo CD) path. Everything else in `k8s-lab-infra` and
`k8s-lab-gitops` is Argo-managed; this is the "how would you do it with
just Helm + a pipeline" answer, for interview prep and for understanding
the mechanics GitOps tools like Argo CD build on top of.

It is fully isolated: its own chart, its own namespace (`helm-demo`), its
own least-privilege identity. It cannot touch anything Argo manages.

Pipeline file: [`.github/workflows/helm-demo-cicd.yml`](../../.github/workflows/helm-demo-cicd.yml)
(kept in the normal `.github/workflows/` location so it's a *real*
workflow, not a static example — trigger it with `workflow_dispatch` any
time you want to watch the whole thing run).

## The flow, and why each stage exists

```
   PR / push                                   workflow_dispatch or merge
       │                                                   │
       ▼                                                   ▼
┌─────────────┐   ┌────────────────┐   ┌──────────────────┐
│    lint     │   │ security-scan  │   │ template-validate │   (all 3 run in parallel,
│ helm lint   │   │ Trivy (config  │   │ kubeconform vs    │    all 3 must pass)
│             │   │ + image) +     │   │ real K8s schema   │
│             │   │ gitleaks       │   │                   │
└──────┬──────┘   └───────┬────────┘   └─────────┬─────────┘
       └──────────────────┴──────────────────────┘
                           │  (skipped for pull_request — PRs only validate)
                           ▼
                  ┌──────────────────┐
                  │  deploy-staging  │  helm upgrade --install
                  │  --atomic        │  --atomic --cleanup-on-fail
                  │  + smoke test    │  using a namespace-scoped
                  └────────┬─────────┘  ServiceAccount, not cluster-admin
                           │
                           ▼
                ┌───────────────────────┐
                │  approve-production   │  ◄── human required-reviewer
                │  (GitHub Environment) │      gate, same pattern as the
                └───────────┬───────────┘      real infra-cd.yml
                            │
                            ▼
                  ┌───────────────────┐
                  │ deploy-production │  same --atomic upgrade, promoted
                  │  + smoke test     │
                  └─────────┬─────────┘
                            │  on failure
                            ▼
                ┌────────────────────────┐
                │  rollback-on-failure   │  explicit `helm rollback` —
                │  (second, explicit     │  catches what --atomic's own
                │   safety net)          │  readiness wait can't
                └────────────────────────┘
```

### Why two rollback layers, not one

`--atomic` is Helm's own, built-in safety net: if the release doesn't
reach `Ready` within `--timeout`, Helm reverts to the previous revision
automatically and the command exits non-zero. That's the first line of
defense, and it's sufficient for the most common failure (bad image tag,
crash-looping container, resource the cluster can't schedule).

It is **not** sufficient on its own. A release can finish "deployed" —
every pod technically `Ready` per Kubernetes' own probes — and still be
functionally broken: a config value that parses but is wrong, a
dependency that isn't reachable, a readiness probe that's too lenient to
catch the real problem. `--atomic` has already declared success by the
time that shows up. That's what the explicit `rollback-on-failure` job
and its smoke test are for: verify the thing actually *works*, not just
that Kubernetes considers it started, and roll back explicitly if it
doesn't.

This exact two-layer pattern (`--atomic` + explicit post-upgrade
verification + explicit `helm rollback`) is used for real in this
project's own Argo CD upgrade path —
[`ansible/roles/argo-bootstrap/tasks/main.yml`](../../ansible/roles/argo-bootstrap/tasks/main.yml)
— proven there first against a real chart version bump before this
reference pipeline copied the same idea for a from-scratch app deploy.

### The RBAC in `rbac/ci-deployer.yaml` — read this one closely

The single most common mistake in real "plain Helm CI/CD" pipelines: give
the pipeline a full cluster-admin kubeconfig because it's the path of
least resistance to get something working. `rbac/ci-deployer.yaml`
creates a `ServiceAccount` with a `Role` (not `ClusterRole`) scoped to
exactly the `helm-demo` namespace and exactly the resource kinds this
chart renders. Verified live, not just asserted:

```
$ kubectl -n helm-demo auth can-i create deployments   # yes
$ kubectl -n argocd get pods                            # Forbidden
$ kubectl get nodes                                     # Forbidden (cluster scope)
```

A leaked `HELM_DEMO_KUBECONFIG` secret can redeploy garbage into
`helm-demo`. It cannot read a single secret in `argocd`, cannot see a
node, cannot touch anything this pipeline doesn't own. That containment
is the actual security control — the workflow YAML is just the thing
that uses it correctly.

## DevSecOps checklist this pipeline actually implements

- [x] **Least-privilege deploy credential** — namespace-scoped
      `ServiceAccount`, not cluster-admin (see above).
- [x] **Shift security left** — Trivy (IaC misconfig on the *rendered*
      manifests, not just the templates — a `--set` override can
      introduce a misconfiguration a static scan of the chart alone
      would never see) + Trivy (image vulnerability scan on the actual
      image the chart ships) + gitleaks (secret scanning), all at PR
      time, before any cluster is touched.
- [x] **Schema validation before deploy** — `kubeconform` against the
      real Kubernetes API schema, the same role `terraform plan` plays
      for infra changes in this repo.
- [x] **Non-root container** — `nginx-unprivileged`, `runAsNonRoot: true`,
      all Linux capabilities dropped (`securityContext` in
      `chart/templates/deployment.yaml`). Checked live that the image
      actually runs as `uid=101`, not just set the flag and hoped.
- [x] **Staged promotion + human gate** — a required-reviewer GitHub
      Environment (`helm-demo-production`) between staging and
      production, identical in kind to the real infra pipeline's
      production gate.
- [x] **Atomic + explicit rollback** — two layers, see above.
- [x] **Bounded release history** — `--history-max 10` so `helm
      history`/rollback storage doesn't grow unbounded forever.
- [ ] **Not implemented, worth knowing about**: chart provenance/signing
      (`helm package --sign`), SBOM generation, network policies scoping
      the demo namespace's egress, and OPA/Conftest policy-as-code on the
      rendered manifests (this repo already does exactly that for
      Terraform plans — `policy/*.rego` — the same idea applies here, just
      not built for this reference). Flagged, not because they don't
      matter, but because a "good enough to understand the flow" resource
      shouldn't try to be everything at once.

## Try it yourself

```bash
# Watch the whole thing run, staging through the approval gate:
gh workflow run "helm-demo CI/CD (learning reference)" --repo nskgit/k8s-lab-infra

# See it live:
export KUBECONFIG=~/.kube/config-lab
kubectl -n helm-demo get pods,deploy,svc
helm -n helm-demo history helm-demo-staging      # revision history — this is what rollback targets

# Prove the rollback path for yourself, safely, in the same helm-demo
# namespace this pipeline already owns — install a good revision, then
# upgrade to a deliberately broken image tag and watch --atomic revert it:
helm upgrade --install rollback-proof examples/helm-cicd-reference/chart \
  -n helm-demo --wait --timeout 90s
helm upgrade rollback-proof examples/helm-cicd-reference/chart \
  -n helm-demo --set image.tag=this-tag-does-not-exist \
  --atomic --cleanup-on-fail --timeout 45s --wait   # fails, then auto-reverts

helm history rollback-proof -n helm-demo            # revision 3: "Rollback to 1"
kubectl -n helm-demo get pods -l app.kubernetes.io/instance=rollback-proof \
  -o jsonpath='{.items[0].spec.containers[0].image}{"\n"}'  # back to the working tag

helm uninstall rollback-proof -n helm-demo          # clean up when done
```

(If your local `helm` prints `Flag --atomic has been deprecated, use
--rollback-on-failure instead` — that's Helm v4's CLI; harmless, and
irrelevant to this pipeline either way, since it pins Helm v3.21.3.)
