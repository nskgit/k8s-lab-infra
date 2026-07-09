# Phases 4–15 — Execution Plan (post-audit)

Produced 2026-07-09 from a 4-auditor review of the master plan against everything learned in
Phases 0–3 (18 critical / 29 important / 15 minor findings). This is the working plan for the
rest of the lab. The master plan (`PROJECT-PLAN-v3.md`) stays the architecture reference; this
doc is the ordered, de-risked execution path.

---

## 0. Direct answers to the three standing questions

### Q1 — "I want to run an app and use the cloud controller to provision a Block Volume; PV/PVC in real time"

That is exactly Phase 4, and it works — with one **hard economic fact discovered in audit**:

- OCI's Always-Free block-storage allowance is **200 GB total, boot volumes included**. Our 4
  instances × 50 GB boots consume **all 200 GB — free PVC headroom is 0 GB**.
- OCI's **minimum block volume is 50 GB** — the CSI driver rounds every PVC request up to 50 GB
  (hard-coded in the driver). The master plan's "~12 GB free-tier PVC headroom" was wrong twice:
  the headroom doesn't exist, and even if it did it's below the 50 GB floor.
- Consequence: on a never-upgraded Always-Free tenancy, the first PVC **fails (stuck Pending,
  service-limit error)**. On a PAYG-upgraded tenancy it provisions and bills ~$1.28/mo
  (50 GB, Lower-Cost tier) or ~$2.13/mo (Balanced).

**Storage strategy (new):**
- **`local-path-provisioner`** (rancher, tiny, arm64-fine) becomes the **cluster-default
  StorageClass** — Prometheus, Loki, Grafana, dev Postgres/Redis all land on worker boot
  volumes (~47 GB each of slack) at $0.
- **`oci-bv`** (custom StorageClass: `vpusPerGB: "0"`, `attachment-type: "paravirtualized"`,
  `WaitForFirstConsumer`, `reclaimPolicy: Delete`, NOT default) is used **deliberately** where
  real Block Volumes are the learning objective: the Phase-4 demo and, later, prod Postgres.
- The Phase-4 exercise (§Phase 4 below) does the full real-time flow you asked for: PVC →
  CCM/CSI provisions a real 50 GB BV in OCI (visible in console) → attach → write data → kill
  pod → data survives → cordon node → volume detaches/re-attaches on the other worker → data
  survives → expand online → delete → volume TERMINATED in OCI.

### Q2 — "Post manually executing Istio, will it be automated as part of infra provisioning using TF & Ansible?"

**No — and by design it never will be.** The three-layer ownership model (locked decisions
#14/#15) after Round 2:

| Layer | Owns | Istio's piece |
|---|---|---|
| **Terraform** | Cloud substrate | The LB, its 80/443 listeners → NodePorts 30080/30443, NSG rules |
| **Ansible** | OS → *cluster exists and is schedulable* + Argo bootstrap | Nothing of Istio |
| **Argo CD** | Everything in-cluster above the scheduling substrate | **Istio itself** (base → istiod → gateway charts + Gateway API CRDs), reconciled continuously from the gitops repo `platform/` |

The Phase 6 manual Helm install is a deliberate throwaway learning step. Its values files are
written straight into the gitops repo layout, so Phase 8 adoption is a rename, not a rewrite.
After Phase 8, a full rebuild = TF (cloud) → Ansible (cluster + CCM/CSI + Argo bootstrap) →
Argo syncs Istio + monitoring + logging + apps. **No human helm/kubectl anywhere.**

**One amendment from the audit (critical):** the master plan had `ccm-csi` becoming an Argo app
at Phase 8. That deadlocks every rebuild: fresh nodes carry the `uninitialized` taint until CCM
runs, and Argo's own Deployments can't schedule on tainted nodes — Argo can't install the very
thing that unblocks Argo. **CCM + CSI move permanently into the Ansible layer** (they are part
of "cluster exists and is schedulable"). Argo's platform scope = istio · monitoring · logging.

### Q3 — "How about observability and log parsers post manual install — how auto-provisioned?"

Same GitOps answer as Istio for the metrics stack: manual Helm at Phase 7 → Argo app at
Phase 8 → auto-restored on any rebuild.

**But the audit confirmed a real gap: the master plan has NO logging stack at all** — no
Loki/Fluent Bit/ELK anywhere in 15 phases; `kubectl logs` was the only log access, gone on every
pod restart. **New Phase 7b adds it:**

- **Loki** (`SingleBinary` mode, 1 replica, filesystem storage on a 5 Gi local-path PVC, 72 h
  retention, all caches/canary/gateway disabled — the chart defaults would never fit 8 GB nodes)
- **Fluent Bit** DaemonSet as the log collector/**parser** — the load-bearing config detail is
  the **CRI multiline parser** (containerd writes `<rfc3339> stdout F msg` format; a docker/JSON
  parser silently mangles every line). Plus a control-plane toleration so cp's
  apiserver/etcd/scheduler logs are collected too. (Promtail is deprecated/EOL — not used.)
- **Grafana** gets Loki as a second datasource (one values entry in kube-prometheus-stack).
- Phase 8 commits all of it to gitops `platform/logging/` and adopts it as an Argo app —
  identical automation story to Istio and monitoring.

---

## 1. Cross-cutting decisions (review these first)

| # | Decision | Rationale |
|---|---|---|
| D1 | **Upgrade tenancy to PAYG before Phase 4/5** (stay within free limits = still $0; set an OCI Budget alert on the compartment) | Changes PVC failure mode from hard-block to small bill; largely fixes A1 "Out of host capacity" (the destroy→rebuild gamble); hard prerequisite for Phase 14 anyway |
| D2 | **local-path default SC + oci-bv deliberate** | See Q1. Steady-state storage spend ≈ $1.3–2.1/mo (demo vol) → ~$4–7/mo when prod Postgres arrives |
| D3 | **CCM + CSI owned by Ansible, not Argo** | Rebuild deadlock (Q2). Amends locked decisions #14/#15 |
| D4 | **Bootstrap secrets owned by Ansible `argo-bootstrap` role** (OCIR pull secrets, Argo repo creds, app secrets from an encrypted vars file). Sealed Secrets stays at Phase 15 as a learning topic, not a dependency | Multiple pre-15 needs (Phases 7/8/9) currently violate the "nothing hand-applied" rule; this closes them with zero new cluster components |
| D5 | **Commit + push the repo to GitHub THIS WEEK** — the repo has zero commits; the only copy of all Phase 0–3 work is one laptop disk | Backup first, CI plumbing second |
| D6 | **`providerID` via kubelet `--provider-id` flag at registration** (from IMDS: `curl -H 'Authorization: Bearer Oracle' http://169.254.169.254/opc/v2/instance/id`), rendered into Init/Join configs by Ansible and into pool cloud-init later | Kills the manual patch step permanently; providerID is set-once — patch-after-join races the CCM; required for autoscaled nodes that have no Ansible run |
| D7 | **Make `k8s-lab-apps` public** → free native `ubuntu-24.04-arm` GitHub runners (no QEMU) | It's a portfolio piece; QEMU-emulated npm/pip builds are 3–20× slower |
| D8 | **Reserved public IPs (bastion + LB) move to the `bootstrap` root at Phase 5** — outside the destroy blast radius | Otherwise every rebuild changes both IPs → all nip.io hostnames, `~/.ssh/config`, CI config break; Phase 12's "one pipeline run restores everything" is unmeetable |
| D9 | **Pin cp's private IP (e.g. 10.0.1.10) at the Phase-5 first rebuild** (in-place now would force instance replacement) + template every kubeadm file from TF outputs | 10.0.1.209 is hardcoded in 4 load-bearing places; DHCP gives a different IP on rebuild |
| D10 | **Wave-2 runs dev-only by default**; "stretch 20 services" is dropped/reworded to dev-only scale-to-zero | Capacity math: wave-1+2 × dev+prod at even tiny requests oversubscribes 1.9 allocatable CPU. Feasible only with aggressive request-tuning; dev-only is the honest default |
| D11 | **DR = ephemeral drills, never standing** (~$2–3/drill vs ~$70/mo standing) | Always-Free A1 is home-region-only — the whole DR region is paid |

---

## 2. Phase-by-phase

### Phase 4 — CSI + StorageClasses + real PV/PVC exercise  🚧 NEXT

Pre-reqs: D1 decided (PAYG or accept the demo PVC may fail on free tier); 1-min pre-flight —
all 3 nodes show `spec.providerID` AND the CCM-stamped compartment annotation:
`kubectl get nodes -o custom-columns=NAME:.metadata.name,PID:.spec.providerID,COMP:'.metadata.annotations.oci\.oraclecloud\.com/compartment-id'`
(if the annotation is missing, bounce the CCM pod before installing CSI — attaches fail
confusingly without it).

1. **VolumeSnapshot CRDs first** (kubeadm doesn't ship them; without them the CSI controller's
   bundled snapshot containers crashloop): apply the 3 CRDs from
   `kubernetes-csi/external-snapshotter` release v6.3.x (matches the bundled snapshotter).
2. **Second config secret** — CSI does NOT read the CCM's secret. Same YAML, different envelope:
   `kubectl -n kube-system create secret generic oci-volume-provisioner --from-file=config.yaml=cloud-provider.yaml`
3. Apply `oci-csi-node-rbac.yaml`, `oci-csi-controller-driver.yaml`, `oci-csi-node-driver.yaml`
   (v1.33.2 release assets — same `releases/download/` URL pattern as CCM). Optional trim:
   delete the FSS + Lustre provisioner containers and the dangling `imagePullSecrets:
   image-pull-secret` entry from the controller manifest (BV-only lab, saves cp memory).
4. **Author our own StorageClasses in git** (skip the upstream storage-class.yaml entirely):
   - `oci-bv`: provisioner `blockvolume.csi.oraclecloud.com`, params `vpusPerGB: "0"`
     (Lower-Cost; the unset default is Balanced = +67% cost, and the tier is immutable
     post-provision), `attachment-type: "paravirtualized"` (avoids host iscsid dependency on
     A1.Flex), `volumeBindingMode: WaitForFirstConsumer` (volumes are AD-local), 
     `allowVolumeExpansion: true`, `reclaimPolicy: Delete`. NOT default.
   - Install `local-path-provisioner` and mark IT default.
5. **The real-time exercise** (gate — reworded from "PVC Bound", which never fires on a bare
   WFFC PVC): 1-replica Postgres StatefulSet with a 50 Gi volumeClaimTemplate,
   `storageClassName: oci-bv` → watch PVC Pending→Bound as the pod schedules → verify the
   volume + paravirtualized attachment in OCI console/CLI → `psql` insert rows → kill pod →
   rows survive → **cordon the worker, delete pod, watch the volume detach/re-attach to the
   other worker (~1–2 min), rows survive** → patch PVC to 51 Gi (online expand) → teardown,
   confirm volume reaches TERMINATED (proves reclaim + nothing left billing).
6. NSG note: Phase 4 needs **zero** NSG changes (iSCSI would ride link-local via the
   hypervisor; paravirtualized is hypervisor-internal; controller API calls ride cp egress).

Cost while the demo volume lives: ~$1.28/mo. Delete it after the gate if you want $0.

### Phase 5 — Round 2 codify (split into 5a / 5b)

**Step 0 (before any CI): repo hygiene**
- `git add -A && git commit` + create GitHub repo + push (D5).
- **Fix the dual-provider bug**: every module binds to implicit `hashicorp/oci` (8.21.0!) while
  the root configures `oracle/oci` (6.37) — works locally only via ambient `~/.oci/config`;
  breaks headless CI. Add `versions.tf` with `required_providers { oci = { source = "oracle/oci" } }`
  to all 4 modules + bootstrap, `terraform init -upgrade`, possibly
  `terraform state replace-provider`, verify no-op plan. Commit the lock file.
- Delete stale `terraform/primary/errored.tfstate` (a wrong `state push` would resurrect the
  duplicated-resources era) after verifying remote state lists ~47 resources.
- Add missing TF outputs the Ansible CCM role needs: `compartment_ocid`, `vcn_id`,
  `public_subnet_id`.
- Move reserved IPs to bootstrap (D8); pin cp private IP (D9) — lands with the first rebuild.
- Split tfvars: non-secret values → committed `ci.auto.tfvars`; secrets → `TF_VAR_*` from
  Actions secrets; `backend.hcl` rendered in-workflow from a repo variable.

**5a — Ansible codify against current named instances + graduation #1**
Roles (versions single-sourced in `group_vars/all.yml` — k8s, containerd, calico-operator,
ccm/csi tags all in one file):
`common` (modules/sysctl/swap/firewalld) · `containerd` (Docker repo, SystemdCgroup) ·
`kubernetes-packages` (pinned 1.33.x) · `kubeadm-cp` (Jinja2 ClusterConfiguration — node-ip,
**provider-id from IMDS**, bind-address 0.0.0.0 for KCM/scheduler [Phase 7 dep], idempotency
guard on /etc/kubernetes/admin.conf) · `cni-calico` (operator + Installation CR: VXLAN,
`bgp: Disabled`, canReach) · `oci-ccm` + `oci-csi` (secrets templated from TF outputs + vendored
release manifests) · `kubeadm-worker` (Jinja2 JoinConfiguration, node-ip + provider-id) ·
`argo-bootstrap` (Phase 8+: Argo install + root-app + bootstrap secrets per D4).

CI workflow (Phase A, hosted runner): workflow-level env
`AWS_REQUEST_CHECKSUM_CALCULATION=WHEN_REQUIRED` + `AWS_RESPONSE_CHECKSUM_VALIDATION=WHEN_REQUIRED`
(on EVERY job incl. destroy — missing them on destroy silently corrupts state mid-rehearsal);
secrets: backend keypair, OCI API key material (write `~/.oci/config` in a setup step),
SSH key via ssh-agent; Ansible over ProxyJump with `StrictHostKeyChecking=accept-new`;
`concurrency` group serializing runs; plan job uploads `tfplan.bin`, apply job gated by a
GitHub Environment required-reviewer (= the "reviewed plan" golden rule); pinned terraform +
ansible-core versions. Invariant: `allow_bastion_public_ssh=true` stays on through Phase A.

Graduation gate #1 (pipeline-verified checklist, not vibes): nodes Ready · zero uninitialized
taints · Calico healthy · CoreDNS resolves from a worker pod · smoke PVC binds · LB health
green · admin.conf fetched and published (kubeconfig survives rebuild).
**Honest scope note:** graduation #1 restores infra+cluster+CNI+CCM/CSI. It does NOT restore
Istio/monitoring (don't exist yet), PVC *data* (gone until Phase 14 backups), or anything
manual. Phases 6–7 then live in a known unprotected window until Argo lands at 8.

**5b — Workers → instance pool + graduation #2**
Design fixes from audit (the memory's original design had 3 conflicts):
- **Join-command vending via Object Storage**: cloud-init retry-loops fetching
  `kubeadm join ...` from a well-known object written by the `kubeadm-cp` role → fresh tokens
  every rebuild, and autoscaled nodes join unattended forever (prerequisite for Phase 15 CA).
  cloud-init owns worker join; the `kubeadm-worker` role is demoted to verify/repair.
- **LB registration via the pool's native `load_balancers` attachment block** — kills the
  for_each-on-unknown-IPs trap structurally; build the 443 backend set the same way.
- **Ansible inventory** switches to the `oracle.oci` dynamic-inventory plugin filtered by
  freeform tag (role=worker); `terraform output` keeps feeding bastion/cp only.

### Phase 6 — Istio + Gateway API + LB 443

1. **Install Gateway API CRDs explicitly** (K8s 1.33 does not ship them; Istio does not install
   them) — standard channel v1.2+, from a manifest that gets a gitops home.
2. Helm istio base → istiod → gateway (Istio ≥ 1.26 for K8s 1.33 support), with values
   committed to the gitops layout from day one:
   - **gateway Service MUST be pinned NodePort** `{http2: 30080, https: 30443}` — the chart
     default is `type: LoadBalancer`, which would make our live CCM silently provision a
     **second, billed OCI LB** that then fails health checks (securityListManagementMode: None).
     Gate check: `kubectl get svc -n istio-system` shows NodePort AND no new LB in OCI console.
   - Sizing overrides (defaults would eat the cluster): istiod `200m/512Mi`, **global proxy
     `25m/64Mi`** (the injected default 100m/128Mi × every pod is the single biggest capacity
     multiplier), 1 replica each.
3. **Gateway resources in manual mode**: set `spec.addresses` to the istio-ingressgateway
   Service hostname — otherwise Istio's automated-deployment mode spins up a per-Gateway
   LoadBalancer Service = second-LB trap again.
4. **LB 443 in Terraform** — audit confirmed the Phase-1 "needs a cert" comment wrong: Istio
   terminates TLS at 30443, so the LB gets a **TCP (L4 passthrough) listener on 443** — no LB
   certificate, no new NSG rules (all already present). New backend set 30443 + listener,
   mirroring the HTTP path. Fix the stale module comment.
5. **TLS decision (was entirely missing)**: lab CA — one self-signed root + wildcard cert for
   `*.nip.io` hosts as a k8s TLS Secret referenced by the Gateway listener; `curl --cacert`
   for gates. (Let's Encrypt on nip.io is rate-limit-unreliable — nip.io isn't on the PSL.)
6. Health checks: keep TCP on 30080/30443 (an HTTP GET / check would 404 against Envoy and
   take BOTH backends down). Optional proper path: status-port 15021 pinned to 30021 + NSG pair.
7. Known limitation to note: TCP-443 passthrough means no client IP on HTTPS (X-Forwarded-For
   only on the HTTP:80 L7 path). PROXY protocol v2 or the free Network LB are Phase-15 options.

### Phase 7 — Observability (metrics) + 7b (logging)

1. **bind-address fix** (NSG rules alone are NOT sufficient — kubeadm binds KCM :10257 and
   scheduler :10259 to 127.0.0.1; Prometheus would get connection-refused through any NSG):
   live-edit the two static-pod manifests on cp to `--bind-address=0.0.0.0` AND bake the same
   into the git ClusterConfiguration + Ansible role (else the Phase-12 rebuild silently
   regresses the scrapes). Correction: etcd plaintext metrics port is **2381** (not 2379).
2. NSG additions (4 rules): node-exporter 9100 worker→cp + worker→worker; KCM 10257 worker→cp;
   scheduler 10259 worker→cp. (kubeEtcd/kubeProxy ServiceMonitors stay disabled.)
3. kube-prometheus-stack, sized: retention 5d/6GB, scrapeInterval 60s, Prometheus
   requests 250m/750Mi + 1.5Gi limit, storage on **local-path 8Gi**, single replicas, Grafana
   persistence OFF (dashboards as ConfigMaps → clean rebuilds), Alertmanager → **Slack webhook
   over 443 or SMTP 587** (OCI blocks outbound port 25 tenancy-wide — email on 25 times out).
4. **Istio telemetry wiring** (Kiali is empty without it — stock kube-prometheus-stack scrapes
   no Istio): apply Istio's ServiceMonitor (istiod :15014) + PodMonitor (Envoy :15090), set
   Prometheus selectors to `{}`; Kiali with `auth.strategy: anonymous` +
   `prometheus.url: http://prometheus-operated.monitoring.svc:9090`.
5. **metrics-server** (~50m/100Mi, `--kubelet-insecure-tls` for the lab) — absent from the
   master plan but required by Phase-15 HPA and by `kubectl top` for all the sizing work.
6. **7b logging** — Loki SingleBinary + Fluent Bit with CRI parser + cp toleration + Grafana
   datasource (full spec in §0/Q3). ~0.35 CPU / ~600Mi total. No NSG changes (in-cluster VXLAN).

### Phase 8 — Argo CD + adoption

1. Trimmed install: dex/notifications off, single replicas, access via port-forward over the
   SSH tunnel (not the LB). ~1–1.2 Gi footprint.
2. **Before adopting anything**: `application.resourceTrackingMethod: annotation` in argocd-cm
   (default label-based tracking collides with chart-set instance labels inside immutable
   selectors).
3. Adoption mechanics per app: pin the EXACT chart version + values file from the manual
   install so the first sync is a **no-op diff**; kube-prometheus-stack needs
   `ServerSideApply=true` (its CRDs blow the 262 KB client-side-apply annotation limit) +
   the standard webhook-caBundle ignoreDifferences; Istio = three Applications (base → istiod →
   gateway) with sync-waves; Gateway API CRDs + local-path + metrics-server + logging as small
   apps. **Set explicit sync-waves/retries now** — incremental adoption won't surface cold-start
   ordering, but Phase 12's from-scratch sync will.
4. After each app is Synced/Healthy: delete the `sh.helm.release.v1.*` Secrets only (never
   `helm uninstall` — it deletes the live resources).
5. Bootstrap secrets per D4: `argo-bootstrap` role owns Argo repo creds + OCIR pull secrets +
   app secrets. **ccm-csi is NOT adopted** (Ansible-owned, D3).

### Phase 9 — Wave-1 services → CI → dev

1. **OCIR pull auth (confirmed hard gap — first Deployment would ImagePullBackOff with 401)**:
   bootstrap TF adds two robot users + auth tokens (OCI caps auth tokens at **2 per user** —
   don't burn your human user's slots): `ocir-puller` (policy: `read repos`) and `ocir-pusher`
   for Actions (`use repos`). Cluster side: one dockerconfigjson Secret per app namespace
   (username `<tenancy-namespace>/<robot-user>`; verify format with a manual `crane pull`
   first), wired as `imagePullSecrets` on the ServiceAccount the shared chart creates —
   distributed by `argo-bootstrap` (D4).
2. **Capacity discipline from day one** (audit: even wave-1 × 2 envs oversubscribes CPU at
   "tiny" 50-100m requests): app containers request **10–25m** / 128Mi with limits 200–500m
   (CPU is compressible; memory is the real wall), Istio proxy override already at 25m/64Mi
   (Phase 6), **one shared Postgres StatefulSet per env** (not per-service), no sidecar on DB
   pods, LimitRange in every app namespace encoding the defaults, dev quotas sized to include
   sidecar requests (~300m/1.5Gi per dev ns).
3. CI: public repo + `runs-on: ubuntu-24.04-arm` (native, no QEMU), plain single-arch build,
   `cache: type=gha`, push to OCIR, bump `envs/dev/<svc>.values.yaml` via a fine-grained PAT
   scoped `contents:write` to the gitops repo only (default GITHUB_TOKEN can't write
   cross-repo). Install `gh` CLI locally for the setup.
4. Shared chart includes DB migration/seed Jobs (Helm hooks) — this is also what makes
   Phase 12's restored-from-empty apps converge Healthy instead of Degraded.
5. Hostnames templated from the LB output at promotion time — never hardcoded in gitops values.

### Phase 10 — First promotion PR → prod
As planned (copy tested tag `envs/dev` → `envs/prod`, review, merge, Argo syncs prod). No
audit changes beyond the templated-hostname rule above.

### Phase 11 — Wave-2
- Extend bootstrap `ocir_repo_names` with the 5 wave-2 names and re-apply (least-privilege
  pusher can't auto-create repos — first push fails otherwise).
- **Dev-only by default** (D10); promote 1–2 representative services to prod at most; re-run
  the requests-vs-allocatable tally as the phase gate.

### Phase 12 — Validation + teardown → rebuild (DR rehearsal)
Ordered runbook (each item a pipeline step, not tribal knowledge):
1. **Pre-destroy**: delete app namespaces/PVCs and WAIT for volumes to actually delete
   (`oci bv volume list` shows only 4 boot volumes) — CSI volumes are NOT in TF state;
   `terraform destroy` orphans them (billing + they can block the rebuild's boot-volume quota).
2. `terraform destroy` → pipeline rebuild → Ansible → Argo restores platform + apps →
   seed Jobs make apps Healthy on empty DBs. Expectation set honestly: **PVC data is lost by
   design until Phase 14 backups.**
3. **Docker Hub trap**: a cold rebuild pulls every third-party image through ONE NAT IP —
   unauthenticated Hub limits (~10 pulls/IP/hr) turn the rehearsal into hours of
   ImagePullBackOff. Prerequisite: mirror all platform/app base images into OCIR
   (one-time crane/skopeo sync job) and point values at OCIR paths. Also removes the external
   dependency from the DR story entirely.
4. Post-rebuild: re-fetch kubeconfig (new cluster CA every rebuild), verify reserved IPs
   survived (D8), post-rehearsal orphaned-volume sweep.
5. k6 + chaos (pod kills, CPU stress, worker reboot) as planned.

### Phase 13 — Self-hosted runner + close bastion
- **Preferred placement change**: use the second Always-Free E2.1.Micro as a dedicated
  `ci-runner` instance in the private worker subnet (NAT egress; its own `nsg-runner`:
  443-out + 22-out to nodes) instead of the bastion — the bastion stays a pure jump host and
  closing public SSH doesn't couple to CI availability. (If bastion is used anyway: it needs a
  new `bastion_out_https` 443 egress rule — it currently has NO internet egress at all — and
  1–2 GB swap; it's 1 GB RAM x86.)
- Runner scope: terraform/ansible/promotion jobs ONLY (x86, 1 GB — image builds stay on hosted
  ARM runners).
- Then flip `allow_bastion_public_ssh=false`.

### Phase 14 — DR (ephemeral drills)
- Hard prerequisite: PAYG (D1). Always-Free A1 + LB + block storage are all home-region-only —
  a standing DR replica ≈ **$70/mo**. Drills ≈ $2–3 each: apply `dr/` (10.1.0.0/16) → restore
  Postgres from cross-region Object Storage backups (pg_dump CronJob ships them) → validate →
  **destroy same day**. OCI Budget alert on the compartment before the first drill.
- Re-add the 4 cp-self NSG rules only if going multi-cp (existing memory note).
- Per-region OCIR + ApplicationSets as planned.

### Phase 15 — Stretch
- **HPA**: metrics-server already in (Phase 7). Optional upgrade path: kubelet
  `serverTLSBootstrap: true` + CSR approval instead of `--kubelet-insecure-tls` (good material).
- **Cluster Autoscaler drill** (pool from 5b): run BEFORE wave-2 is resident or with dev scaled
  to zero — with ~10 GB of standing requests one node can never hold everything, so CA would
  never scale down and the drill demonstrates nothing. Forcing function = a stress Deployment
  with large requests. Expect OCI capacity-error backoff as part of the learning. Join-on-boot
  via the Object Storage vending (5b) is the actual prerequisite.
- **Harbor: dropped** (needs 1.5–2.5 GB + several 50 GB paid PVCs; duplicates OCIR learning).
  At most an afternoon spin-up/tear-down drill.
- **`type: LoadBalancer` demo**: pre-write NSG rules (CCM manages none with
  securityListManagementMode: None), attach via the `oci-network-security-groups` annotation,
  create → verify → **delete within the hour** (second LB bills ~$9/mo while alive).
- OCIR retention job (immutable SHA tags accumulate forever; Always-Free Object Storage is
  20 GB shared with tfstate): scheduled cleanup keeping last-N tags + anything referenced in
  gitops envs/.

---

## 3. Standing cost picture (post-D1 PAYG, disciplined)

| Item | When | ~Cost |
|---|---|---|
| Everything Phase 0–3 built | now | $0 (Always Free) |
| Phase 4 demo Block Volume (50 GB, lower-cost) | while it lives | $1.28/mo |
| Prod Postgres + optional second BV | Phase 9+ | $1.3–2.6/mo |
| Second LB / Harbor / standing DR | — | avoided by design |
| DR drill | per drill | $2–3 |
| OCIR + Object Storage | steady | ~$0 with retention job |

---

## 4. Master-plan deltas applied (see PROJECT-PLAN-v3.md)

1. Locked decision #8 rewritten — the "~12 GB free-tier PVC headroom" was wrong (200 GB already
   consumed by boots; 50 GB volume minimum). New storage strategy per D2.
2. Locked decision #14 amended — platform Argo apps = istio · monitoring · **logging**;
   **ccm-csi moved to the Ansible layer** (rebuild deadlock).
3. Locked decision #15 refined — Ansible owns "cluster exists **and is schedulable**"
   (containerd, kubeadm, Calico, CCM+CSI) + Argo bootstrap.
4. Locked decision #22 extended — + Loki/Fluent Bit logging, + metrics-server.
5. Phase table rows 4–15 updated to match this document.
