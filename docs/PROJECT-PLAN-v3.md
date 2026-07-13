# Kubernetes Hands-On Lab — Master Plan v3.0 (FINAL)

Self-managed Kubernetes on OCI: manual bootstrap first (interview-grade understanding),
then production-grade automation — Terraform modules, Ansible from CI, GitOps for
everything in-cluster. DR-ready by construction.
Diagrams: `network-architecture-v3.mermaid`, `cicd-pipeline-design-v3.mermaid`.

---

## 1. Locked decisions

| # | Area | Decision |
|---|------|----------|
| 1 | Cloud & budget | OCI Always Free (4 ARM OCPU / 24 GB); fallback paid A1 ~$30/mo |
| 2 | Cluster | Self-managed kubeadm: control-plane-1 (2 OCPU/8GB, **tainted** — kubeadm's default `node-role.kubernetes.io/control-plane:NoSchedule` stays) + worker-1/2 (1 OCPU/8GB). Schedulable capacity for workloads = workers only, 2 OCPU / 16 GB. |
| 3 | Subnet topology | **Control plane in its own private subnet**; workers in a second private subnet — cross-subnet traffic governed by NSGs |
| 4 | Firewalling | Security Lists kept near-empty; **all rules in NSGs** (per-vNIC) — nsg-lb, nsg-bastion, nsg-cp, nsg-workers |
| 5 | Bootstrap method | **Round 1: fully manual over SSH** → **Round 2: codified — Ansible from CI (OS→cluster), Argo CD (in-cluster)** |
| 6 | kubeadm config | Declarative ClusterConfiguration YAML in git; kubelet `cloud-provider: external` **from day one** |
| 7 | Cloud integration | **OCI CCM + CSI driver**: dynamic PVC → Block Volume; auth via Instance Principals (dynamic group + policy in TF, no keys on nodes) |
| 8 | Storage | **REWRITTEN 2026-07-09 (audit):** the "~12GB free PVC headroom" was wrong — 4×50GB boots consume the entire 200GB Always-Free block allowance, AND OCI's minimum block volume is 50GB (CSI rounds every PVC up). No free PVC path exists. New strategy: `local-path-provisioner` = default SC (Prometheus/Loki/dev DBs, $0 on boot-volume slack) + custom `oci-bv` SC (vpusPerGB "0", paravirtualized, WFFC, Delete) used deliberately for the Phase-4 demo + prod Postgres (~$1.28/mo per 50GB volume). See docs/PHASES-4-15-EXECUTION-PLAN.md §Phase 4 |
| 9 | Ingress | Terraform-managed public flexible LB → Istio ingress NodePorts 30080/30443 (CCM `type: LoadBalancer` = later demo only) |
| 10 | CPU architecture | arm64 end-to-end; multi-arch via buildx later |
| 11 | CNI | Calico **VXLAN mode** (4789/udp); pod 10.244.0.0/16, service 10.96.0.0/16 |
| 12 | DNS | CoreDNS (kubeadm addon), dissected in Round 1 |
| 13 | Mesh & routing | Istio (sidecar) implementing Gateway API; dev/prod host routing via the real domain `*.satheshkumarnapoleon.site`. **AMENDED 2026-07-12 (Phase 6 as-built): nip.io dropped** — a GoDaddy-registered domain with a `*` A-record → LB IP replaced it (survives LB IP changes with one DNS edit, works with a single wildcard cert, no PSL/rate-limit issues). GoDaddy has no usable DNS API → Let's Encrypt DNS-01/wildcard NOT automatable; upgrade path is cert-manager HTTP-01 per-host (needs working ingress first) or moving DNS to Cloudflare (registrar stays GoDaddy) |
| 14 | Platform install | Round 1: manual Helm (istio base→istiod→gateway; kube-prometheus-stack; logging; Argo) → Round 2: platform = Argo apps in gitops `platform/` = **istio · monitoring · logging**. **AMENDED 2026-07-09: ccm-csi is NOT an Argo app** — on a rebuild every node is uninitialized-tainted until CCM runs, and Argo's own Deployments can't schedule on tainted nodes (deadlock). CCM+CSI live in the Ansible layer |
| 15 | Ownership layers | **Terraform = cloud · Ansible = OS→cluster-exists-AND-schedulable (containerd, kubeadm, Calico, CCM+CSI) + Argo bootstrap + bootstrap secrets · Argo CD = everything above the scheduling substrate** |
| 16 | TF structure | **Reusable modules** (network, cluster-node, lb, iam-ccm); per-region root; all CIDRs/regions/names variables; per-region state keys |
| 17 | DR readiness | Primary VCN 10.0.0.0/16; **DR VCN reserved 10.1.0.0/16** (non-overlap → DRG peering); DR cluster = new Argo destination / ApplicationSets |
| 18 | Repos | 3: infra (TF+Ansible), apps (monorepo), gitops (source of truth) |
| 19 | Delivery | Pull-based GitOps; deployment/promotion = git commits; rollback = revert |
| 20 | Environments | dev + prod namespaces, day one; dev quota-capped; shared Helm chart + per-env values |
| 21 | Registry & CI | OCIR, immutable git-SHA tags; GitHub Actions — Phase A hosted runner via bastion ProxyJump → Phase B self-hosted runner in VCN |
| 22 | Observability | kube-prometheus-stack + Kiali; Alertmanager → Slack webhook or SMTP 587 (OCI blocks outbound 25). **EXTENDED 2026-07-09:** + logging = Loki (SingleBinary, local-path PVC) + Fluent Bit DaemonSet (CRI parser, cp toleration) as Phase 7b; + metrics-server (kubectl top now, HPA at Phase 15) |
| 23 | Human access | Bastion (reserved public IP) ProxyJump; kubectl via SSH tunnel (127.0.0.1 in cert SANs) |

## 2. Network & security borders

| Network | CIDR | Route 0.0.0.0/0 → |
|---|---|---|
| VCN (primary) | 10.0.0.0/16 | — |
| Public subnet | 10.0.0.0/24 | Internet GW |
| 🔒 Control-plane subnet | 10.0.1.0/24 | NAT GW |
| 🔒 Worker subnet | 10.0.2.0/24 | NAT GW |
| Pod overlay (Calico VXLAN) | 10.244.0.0/16 | — |
| Services | 10.96.0.0/16 | — |
| VCN (DR, reserved) | 10.1.0.0/16 | — |

Service Gateway: OCIR, Object Storage (tf state), Block Volume API (CSI).

**NSG matrix (Terraform-managed):**

| NSG | Direction | Rule | Source / Dest |
|---|---|---|---|
| nsg-lb | IN | 80, 443/tcp | 0.0.0.0/0 |
| nsg-lb | OUT | 30080, 30443/tcp | nsg-workers |
| nsg-bastion | IN | 22/tcp | your-IP/32 (+0.0.0.0/0 key-only, Phase A only) |
| nsg-bastion | OUT | 22/tcp | nsg-cp, nsg-workers |
| nsg-cp | IN | 22/tcp | nsg-bastion |
| nsg-cp | IN | 6443/tcp | nsg-bastion, nsg-workers |
| nsg-cp | IN | 10250/tcp | nsg-workers |
| nsg-cp | IN | 5473/tcp (Calico typha) | nsg-workers |
| nsg-cp | IN | 4789/udp (VXLAN) | nsg-workers |
| nsg-workers | IN | 22/tcp | nsg-bastion |
| nsg-workers | IN | 10250/tcp | nsg-cp, nsg-workers |
| nsg-workers | IN | 30080, 30443/tcp | nsg-lb |
| nsg-workers | IN | 5473/tcp (Calico typha) | nsg-cp, nsg-workers |
| nsg-workers | IN | 4789/udp (VXLAN) | nsg-cp, nsg-workers |
| nsg-cp, nsg-workers | OUT | all | via NAT GW / Service GW |
| nsg-bastion | OUT | (jump-host only — no internet egress) | — |

Why kubelet/API rules reference *node* NSGs even for pod traffic: Calico SNATs
pod-sourced traffic leaving the pod CIDR (natOutgoing), so e.g. Prometheus scraping a
kubelet arrives from the node's IP.

**Single-cluster pruning:** cp-self rules on 6443/2379-2380/10250/4789 are deliberately
absent — same-node traffic loopbacks and never traverses OCI NSGs, so they're pure
redundancy on a 1-cp topology. Re-add them (etcd Raft peers, apiserver cross-talk,
kubelet cross-scrape, VXLAN cp↔cp) when the multi-cp HA/DR strategy lands.

**Bastion is a pure jump host** — no internet egress rule. Only outbound path is
22/tcp to nsg-cp/nsg-workers (ProxyJump). Tool installs on the bastion must happen at
image-build time or via `scp` from Mac; Phase B self-hosted GitHub runner will need an
explicit 443/tcp egress rule added at that time.

**Worker → cp VXLAN reinstated** (was briefly pruned during Phase 1 design under the
mistaken assumption "nothing on cp has a pod IP"). CoreDNS, calico-typha,
calico-kube-controllers, calico-apiserver, and tigera-operator are all Deployments that
tolerate the control-plane taint and land on cp with real pod IPs. Any worker pod
resolving a Service via CoreDNS needs to reach those pod IPs — Calico encapsulates as
worker-node → cp-node UDP 4789. Blocking this rule silently breaks in-cluster DNS.

**Calico typha on 5473/tcp (added 2026-07-09 Phase 4):** calico-typha runs with
`hostNetwork: true` (Tigera Operator default), so its "pod IPs" are node IPs. felix on
each calico-node discovers typha's endpoint IPs directly (bypassing the Service) and
connects on TCP 5473 — that's straight node-to-node traffic. Three rules close the gap:
worker → cp (workers reaching cp's typha replica), worker → worker (reaching each
other's), and cp → workers (defensive if cp's local typha replica fails). Without them,
felix on any node whose typha replica lives elsewhere sits in 0/1 Ready with a felix log
"Failed to connect to typha endpoint … i/o timeout" — worker-2 was stuck in exactly this
state for 10 hours before we noticed.

## 3. Services, namespaces, quotas

Wave 1: storefront (Node.js) · catalog (FastAPI+Postgres) · cart (Go+Redis) ·
orders (FastAPI+Postgres) · auth (Node.js/JWT).
Wave 2: payments, inventory, profiles, recommendations, notifications.
Namespaces `<domain>-<env>`: web/shop/users(-dev,-prod), engage-* at wave 2;
platform: istio-system, monitoring, argocd. Dev namespaces quota-capped.

## 4. Promotion flow

merge → CI builds arm64 image (tag=SHA) → OCIR → CI bumps `envs/dev/<svc>.values.yaml`
→ Argo syncs **dev** → verify `dev.satheshkumarnapoleon.site` → **promotion PR** to `envs/prod/`
→ review → merge → Argo syncs **prod** at `prod.satheshkumarnapoleon.site`.
(AMENDED 2026-07-12: real domain replaces nip.io — the `*` A-record covers every
env/service hostname with zero per-host DNS work.)

## 5. Repo layouts

```
k8s-lab-infra/
├── terraform/
│   ├── modules/{network,cluster-node,lb,iam-ccm}/
│   ├── primary/           # root module, state key: primary
│   └── dr/                # future root — VCN 10.1.0.0/16, same modules
├── ansible/
│   ├── inventory/         # rendered from terraform output -json
│   ├── site.yml
│   └── roles/             # common · containerd · kubeadm-cp · kubeadm-worker · argo-bootstrap
├── kubeadm/ClusterConfiguration.yaml   # podSubnet, serviceSubnet, SANs, cloud-provider=external
└── .github/workflows/     # pr-checks.yml · apply-and-configure.yml (gated)

k8s-lab-apps/               # monorepo, path-filtered CI
└── services/{storefront,catalog,cart,orders,auth}/

k8s-lab-gitops/             # Argo CD watches this
├── platform/               # Argo apps: istio · monitoring · ccm-csi (upstream charts + values)
├── charts/app/             # shared Helm chart
├── envs/{dev,prod}/        # <service>.values.yaml
└── argocd/{root-app.yaml,apps/}
```

## 6. Phase roadmap

| Phase | Deliverable | Gate |
|---|---|---|
| 0 | Mac toolchain, SSH key, OCI auth. **Full tool list (as actually used through Phase 6; install ALL of these up front on a redo):** terraform, oci-cli, ansible-core (+ collections ansible.posix, community.general), kubectl, **helm** (Phase 6/7 installs), **istioctl** (`brew install istioctl` — Envoy/mesh debugging: proxy-status, proxy-config routes/clusters/endpoints/secrets, analyze; we initially skipped it and fell back to the raw :15000 admin API), git, openssl (lab CA), curl/dig | ✅ done (amended 2026-07-12 with the full as-used list) |
| 1 | Terraform modules: network (3 subnets, 2 route tables, 4 NSGs), iam-ccm, bastion+nodes, LB, OCIR | plan reviewed each step |
| 2 | **ROUND 1** manual bootstrap: kernel prep, containerd, kubeadm init (ClusterConfiguration, cloud-provider=external + node-ip), Calico VXLAN, **OCI CCM (pulled forward from Phase 4 — external cloud-provider is half-plumbed without it)**, joins, CoreDNS deep-dive | nodes Ready, DNS test |
| 3 | Access: ProxyJump config + kubectl tunnel | kubectl from Mac |
| 4 | CSI driver install (snapshot CRDs first; second secret `oci-volume-provisioner`); custom `oci-bv` SC (vpusPerGB 0, paravirtualized, WFFC) + local-path-provisioner as default SC; full PV/PVC exercise (provision → attach → kill pod → node move → expand → delete) | data survives pod kill + node move; volume visible then TERMINATED in OCI |
| 5 | **ROUND 2** in two parts. **5a**: git commit+push (step 0), fix module `required_providers` (dual-provider bug), TF outputs for CCM secret, reserved IPs → bootstrap root, Ansible roles (common · containerd · kubernetes-packages · kubeadm-cp · cni-calico · oci-ccm · oci-csi · kubeadm-worker · argo-bootstrap; provider-id from IMDS at registration), CI pipeline (checksum env vars on EVERY job, plan artifact + environment-gated apply); graduation #1. **5b**: workers → instance pool (join-command vending via Object Storage, LB via pool attachment block, dynamic inventory); graduation #2 | rebuilt from git, pipeline-verified checklist |
| 6 | ✅ **DONE 2026-07-12** (commit `a5ee2be`). As planned: Gateway API CRDs v1.2.1 standard channel; Istio 1.30.2 Helm base→istiod→gateway (NodePort 30080/30443 pinned — 2nd-LB trap confirmed defused, one LB in console; istiod 200m/512Mi, global proxy 25m/64Mi); Gateway manual mode (spec.addresses → existing Service); TF TCP-443 passthrough listener + backend set (no LB cert — Envoy terminates). **As-built deltas**: real domain `*.satheshkumarnapoleon.site` (GoDaddy `*` A-record) instead of nip.io; lab-CA wildcard cert (10y root + 1y wildcard, Secret istio-ingressgateway-tls-wildcard); gateway chart key is `replicaCount` NOT `replicas` (strict schema). Expansion proven: 5 hostnames (echo, httpbin, grafana, blog, db-admin), weighted 90/10 canary, mTLS XFCC evidence, MariaDB+WordPress+Adminer stack (DB sidecar-excluded per capacity rule) | ✅ curl both schemes on all 5 hosts; s_client serves our cert; NO new LB in OCI console; 56/4 split at n=60 |
| 7 | ✅ **DONE 2026-07-11→13.** kube-prometheus-stack 87.12.3 (5d/6GB, local-path 8Gi, KCM/scheduler `--bind-address=0.0.0.0` fix on cp + in git + kubeadm-config CM) + 4 NSG scrape rules + metrics-server + **Istio ServiceMonitor(15014)/PodMonitor(15090) + Kiali 2.28.0** (mesh graph) + **app-metrics demo (podinfo)**. Alertmanager routing walkthrough done (null-receiver; Slack wiring designed, needs webhook — port 25 blocked so 443/587 only). **7b**: Loki SingleBinary (local-path 5Gi, 72h, tsdb v13) + Fluent Bit (**multiline.parser cri** — load-bearing; cp toleration) + Loki Grafana datasource. **APP-METRICS RULE (for Phase 9):** developers INSTRUMENT apps to expose /metrics (client library); scraping is WIRED via ServiceMonitor/PodMonitor (Prometheus-Operator CRDs, often bundled in the app's own chart) — so the shared app chart templates a ServiceMonitor beside Deployment/Service/HTTPRoute/DestinationRule. 3rd-party apps → exporter sidecar. Loki has no UI; Grafana Explore is it (one pane for metrics+logs; ELK/Kibana rejected on RAM). | metrics+mesh+logs all in Grafana; Kiali graph live; logs queryable |
| 8 | Argo CD (trimmed: no dex, single replicas, port-forward access) + root-app; **adopt istio · monitoring · logging as Argo apps** (annotation tracking, ServerSideApply for kube-prometheus-stack, exact-version pins = no-op first sync, sync-waves; delete helm release secrets after); argo-bootstrap role owns bootstrap secrets (OCIR pull, Argo repo creds). ccm-csi stays Ansible-owned | Argo shows platform synced |
| 9 | OCIR pull auth (2 robot users + auth tokens in bootstrap TF — 2-token/user cap; dockerconfigjson via SA imagePullSecrets); wave-1 services → CI (public repo, native arm runners, no QEMU) → dev; capacity discipline (requests 10–25m, shared Postgres per env, LimitRange); migration/seed Jobs in shared chart; PAT for cross-repo gitops writes | flow works on dev URL |
| 10 | First promotion PR → prod (hostnames templated from LB output, never hardcoded) | prod serves traffic |
| 11 | Wave-2 services **dev-only by default** (capacity); extend bootstrap `ocir_repo_names` first; promote 1-2 representative services to prod at most | requests-vs-allocatable tally stays green |
| 12 | Validation: k6, pod kills, CPU stress, worker reboot; **teardown runbook**: PVC purge + volume-sweep BEFORE destroy (CSI volumes are NOT in TF state — destroy orphans them) → rebuild → Argo restores → seed Jobs converge. Prereq: platform images mirrored to OCIR (Docker Hub rate limits through 1 NAT IP). Data loss expected until Phase 14 | success criteria (with data-exclusion footnote) |
| 13 | Phase B: dedicated ci-runner on the 2nd free E2.1.Micro in private subnet (nsg-runner: 443 out) — bastion stays pure jump host; close bastion 0.0.0.0/0 | no inbound SSH from internet |
| 14 | **DR phase** (prereq: PAYG — Always-Free is home-region-only, standing DR ≈ $70/mo): **ephemeral drills** (~$2-3 each) — apply dr/ (10.1.0.0/16) → restore Postgres from cross-region Object Storage backups → validate → destroy same day; ApplicationSets; per-region OCIR; OCI Budget alert first | drill completes + teardown verified |
| 15 | Stretch: HPA (metrics-server done at 7), Cluster Autoscaler drill on pool (run before wave-2 resident; expect OCI capacity backoff), Sealed Secrets, multi-arch, `type: LoadBalancer` demo (create→verify→delete same hour; pre-written NSG rules), OCIR retention job. Harbor dropped | |

## 7. Success criteria

1. App reachable publicly on dev and prod hostnames via the LB
2. Grafana shows live cluster + app performance
3. Induced failures fire Alertmanager alerts you receive
4. Changes ship dev→prod purely through git, full audit trail
5. Stateful services run on dynamically provisioned OCI Block Volumes
6. **Full teardown → one pipeline run + Argo sync restores everything (DR rehearsal)**

## 8. Golden rules

- State bucket lives outside the stack; never commit/delete tfstate
- Image tags = immutable git SHAs (enforced at CI in Phase 9 — see §9 for why not at OCIR)
- No pipeline ever runs kubectl/helm at the cluster — only Argo CD applies
- After Round 1: nodes never configured from laptops; nothing in-cluster hand-applied — platform = Argo apps
- Every infra change is a reviewed plan before it is an apply
- All Terraform is modules + variables — a new region must never require copy-paste edits
- dev is quota-capped; prod changes land only via promotion PRs

## 9. Operator notes (OCI-specific quirks discovered during Phase 1)

Facts we learned the hard way; keeping them here so future us and CI runners don't relearn.

### 9.1 AWS SDK v2 checksum env vars are mandatory for Terraform's S3 backend against OCI

Terraform 1.11+ uses AWS SDK for Go v2 in its S3 backend. Since Jan 2025 the SDK's default is
to compute a CRC32 checksum on every `PutObject` and send the body with `Content-Encoding:
aws-chunked` + trailing checksum. OCI's S3-compat layer rejects that with `501 NotImplemented:
AWS chunked encoding not supported`. The failure is silent inside apply — state PUTs return
error but Terraform continues creating resources → state bucket stays empty → the next apply
duplicates everything.

Every shell that runs Terraform against `primary/` MUST have these exported:

```
export AWS_REQUEST_CHECKSUM_CALCULATION=WHEN_REQUIRED
export AWS_RESPONSE_CHECKSUM_VALIDATION=WHEN_REQUIRED
```

(They live in `~/.k8s-lab-secrets/state-backend.env` alongside the Customer Secret Key creds
that back the S3-compat auth.) `skip_s3_checksum = true` in `backend.hcl` is not sufficient —
that only strips explicit checksum headers on state uploads, not the SDK-level default.

### 9.2 `use_lockfile = true` works and is verified atomic

Given the env vars above, Terraform's native S3 lockfile mechanism (a `.tflock` object created
with `If-None-Match: *`) works correctly against OCI Object Storage. Verified empirically: a
planted fake `.tflock` triggers `412 PreconditionFailed` + correct lock-holder info from
`terraform plan`. No DynamoDB equivalent needed.

Phase 5 CI must set the same env vars in its GitHub Actions environment — otherwise runs will
silently corrupt state exactly like the first manual apply did.

### 9.3 OCIR `is_immutable = true` is rejected at CreateContainerRepository

The `oci_artifacts_container_repository` resource exposes `is_immutable`, but OCI's API in
`us-ashburn-1` returns `400-BAD_REQUEST, Setting isImmutable is not currently supported`. The
Golden Rule "immutable git-SHA tags" is instead enforced at CI level (Phase 9) — build
workflow refuses to re-push an existing tag. Optional post-create workaround via
`null_resource` + `local-exec` calling `oci artifacts container repository update
--is-immutable true` is possible (OCI accepts the setting on UPDATE) but deferred to Phase 15.

### 9.4 NSG rule description limit = 255 bytes (not chars)

OCI's `AddNetworkSecurityGroupSecurityRules` API rejects descriptions > 255 bytes. The check
is byte-length, so multi-byte UTF-8 characters (arrows `↔`, box drawing, emoji) count more
than one. Descriptions on `cp_out_all` and `workers_out_all` were compressed accordingly;
the full context lives in the section-header comments above each rule instead.

### 9.5 Platform image lookups must use `tenancy_ocid`, not the k8s-lab compartment

Oracle-published Oracle Linux platform images are tenancy-scoped. Querying
`data.oci_core_images` with a specific `compartment_id` works only if that compartment
exists. During plan-only review (placeholder compartment OCID pre-bootstrap-apply), the query
returns `null` and crashes at `.images[0].id`. Use `var.tenancy_ocid` for the two image data
sources in `primary/main.tf`.

### 9.6 `list(string)` for `for_each` needs static keys

Passing worker private IPs as a list and using `for_each = toset(list)` fails at plan time
with "keys derived from resource attributes cannot be determined until apply." Switch to
`map(string)` keyed by worker name (`worker-1`/`worker-2` — static) and iterate the map
directly. `each.value` becomes the runtime-unknown IP.

### 9.7 kubelet needs --node-ip when cloud-provider=external (Phase 2 hard lesson)

With `--cloud-provider=external`, kubelet does NOT set `node.status.addresses` — that's the
CCM's job. Without an explicit `--node-ip`, the node registers with **no InternalIP**, which
cascades: hostNetwork pods (etcd, apiserver, calico-typha) get no pod IP → the calico-typha
Service has empty endpoints → calico-node dies with `[FATAL] Typha discovery failed:
Kubernetes service missing IP or port` → felix readiness 503 forever. It also breaks
`kubectl logs/exec` (apiserver→kubelet falls back to node hostname, which the VCN resolver
can't resolve — the kubeadm preflight "hostname could not be reached" warning is NOT benign
in this setup).

Fix: `node-ip` in `kubeletExtraArgs` (InitConfiguration for cp, JoinConfiguration for
workers) — see kubeadm/ClusterConfiguration.yaml. Live fix on a running node: append
`--node-ip=<ip>` to KUBELET_KUBEADM_ARGS in `/var/lib/kubelet/kubeadm-flags.env` and
`systemctl restart kubelet`.

### 9.8 OCI CCM: node→instance mapping + install specifics

- The CCM maps a K8s node to an OCI instance by display name or VNIC hostname label. In our
  deployment the name lookup failed even with a matching hostname label ("Failed to map
  providerID to instanceID, and error by node name") — the reliable unblock is to patch the
  providerID explicitly on each node:
  `kubectl patch node <n> -p '{"spec":{"providerID":"oci://<instance-ocid>"}}'`
  CCM then initializes the node within seconds (addresses, topology labels, removes the
  `node.cloudprovider.kubernetes.io/uninitialized` taint).
- Manifests: fetch from `github.com/oracle/oci-cloud-controller-manager/releases/download/<tag>/`
  (the raw.githubusercontent paths 404). Pick the tag matching the K8s minor (v1.33.2 for
  K8s 1.33).
- Config: Secret `oci-cloud-controller-manager` in kube-system, key `cloud-provider.yaml`
  with `useInstancePrincipals: true`, compartment + vcn OCIDs, `loadBalancer.subnet1` (public
  subnet) and `securityListManagementMode: None` (NSGs are Terraform-managed).
- Calico note: with VXLAN encapsulation, set `Installation.spec.calicoNetwork.bgp: Disabled`
  — otherwise calico-node's readiness probe checks the BIRD BGP daemon that isn't running.

### 9.10 Bastion memory reality + SSH multiplexing (Phase 4 lesson, Phase 13 implication)

The bastion is `VM.Standard.E2.1.Micro` — nominally 1 GB RAM but actually reports **~500 MB**
usable. The stock OL9 image ships with a 498 MB `/.swapfile`. Combined ~1 GB working memory.

Every Mac-side `ssh k8s-*` command forks its own bastion sshd child (~25 MB RSS). Around
~5 concurrent tunnels + kubectl exec + a shell = ~125 MB of connection overhead alone → swap
fills → sshd stops accepting banner exchange → cluster becomes unreachable from Mac (all
tunnels ride the bastion).

**Fix on the bastion:** add `/swapfile2` (1 GB), persist in `/etc/fstab` → total swap ~1.5 GB.

**Fix on the Mac (`~/.ssh/config`):** shared `Host k8s-*` block with SSH ControlMaster
multiplexing (all `ssh k8s-*` commands share ONE bastion sshd child) and ServerAlive
keepalives (30 s ping so tunnels don't idle-drop). Force-close cached masters with
`ssh -O exit <host>`.

**Recovery when the bastion OOMs anyway:** OCI `SOFTRESET` hangs in `STOPPING` (too thrashed
to shut down gracefully); use hard `RESET`. Reserved public IP survives.

**Phase 13 implication (critical amendment):** the master plan's original "self-hosted CI
runner on the bastion" is not viable — 1 OCPU / ~500 MB / .NET runner idles at ~250 MB is
untenable. Use the second Always-Free E2.1.Micro as a dedicated `ci-runner` instance in the
private worker-side subnet (own `nsg-runner`: 443 out + 22 out to nodes). Bastion stays a
pure jump host.

### 9.9 A1.Flex free-tier ceiling caps total worker OCPUs

Always Free A1.Flex is 4 OCPU / 24 GB tenancy-wide. Control-plane at 2/8 leaves workers with
2 OCPU / 16 GB total — enough for the current 2 × (1 OCPU/8 GB), but Cluster Autoscaler
(Phase 15 stretch) cannot scale above `size = 2` inside free tier. Bastion cannot be A1.Flex
either — it uses the separate `VM.Standard.E2.1.Micro` Always-Free pool. See
`terraform/primary/main.tf` for the two image data sources this forces (ARM + x86).
