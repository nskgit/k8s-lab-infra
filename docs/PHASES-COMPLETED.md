# Phases journal — what was done, at a high level

One-line-per-step summary of each phase as it's completed. Fill in the "TBD" sections
as we progress. For details, see `docs/PROJECT-PLAN-v3.md` and `docs/LEARNING-LOG.md`.

---

## Phase 0 + Phase 1 — bootstrap the lab and stand up cloud infra ✅

1. **Installed toolchain** — Terraform, OCI CLI, Ansible, kubectl, git; generated a dedicated SSH keypair for the lab.
2. **Set up the repo** — `git init` locally and scaffolded the Terraform tree.
3. **Wrote the `bootstrap/` root** — creates a dedicated OCI compartment, an Object Storage bucket for remote Terraform state, and OCIR container registries for future app images.
4. **Wrote 4 reusable Terraform modules** — `network` (VCN, subnets, gateways, NSGs), `cluster-node` (bastion + control-plane + worker), `iam-ccm` (Instance-Principals dynamic group + policy), and `lb` (public load balancer → worker NodePort).
5. **Wrote the `primary/` root** — wires the four modules together and publishes outputs (public IPs, SSH commands).
6. **Applied `bootstrap/`** — compartment, state bucket, and OCIR repos live in OCI.
7. **Wired the remote state backend** — pointed `primary/` at the Object Storage bucket and migrated state up.
8. **Applied `primary/`** — real infra live: VCN, IAM, bastion + control-plane + 2 workers, public LB.
9. **Wired SSH access** — `~/.ssh/config` with ProxyJump through the bastion; verified shell access into all 4 nodes.

---

## Phase 2 — Round 1 manual kubeadm bootstrap ✅

1. **Prepped the OS on all 3 K8s nodes** — kernel modules (`overlay`, `br_netfilter`), IP-forward/bridge sysctls, swap off, firewalld off. NSGs are the firewall now.
2. **Installed containerd** (v2.2.5 from Docker's yum repo — OL9 doesn't ship the `containerd.io` package name) with `SystemdCgroup = true` to match kubelet.
3. **Installed kubeadm/kubelet/kubectl v1.33.13** from the upstream Kubernetes yum repo; kubelet enabled but crash-loops until it gets a cluster config.
4. **Authored `kubeadm/ClusterConfiguration.yaml`** in git — declarative bootstrap config: podSubnet 10.244.0.0/16, serviceSubnet 10.96.0.0/16, apiserver cert SANs include 127.0.0.1 (for the SSH-tunnel access pattern), kubelet `--cloud-provider=external` and **`--node-ip`** (non-obvious but load-bearing with cloud-provider=external).
5. **`kubeadm init` on cp** — bootstrapped etcd + kube-apiserver + kube-controller-manager + kube-scheduler as static pods; installed CoreDNS + kube-proxy addons.
6. **Installed Calico VXLAN CNI** via the Tigera Operator — one `Installation` CR with `encapsulation: VXLAN`, `bgp: Disabled` (VXLAN doesn't need BIRD), autodetect interface via `canReach: 10.0.0.1`.
7. **Installed OCI Cloud Controller Manager (v1.33.2)** — pulled forward from the master plan's Phase 4 because `cloud-provider=external` is half-plumbed without a CCM. Manually patched `providerID` on each node to unblock CCM's node initialization (its name→instance lookup was unreliable).
8. **Joined worker-1 and worker-2** in parallel using a git-tracked `JoinConfiguration-worker.template.yaml`; ~30 seconds each end-to-end, no manual token-fiddling.
9. **kubectl from Mac** via `ssh -N -L 6443:127.0.0.1:6443 k8s-cp` + a kubeconfig with the `server:` URL rewritten to loopback (matches the cert SAN).
10. **Verified DNS end-to-end** — busybox pod on worker-1 resolves both `kubernetes.default.svc.cluster.local` (in-cluster) and `github.com` (forwarded upstream via OCI VCN resolver). Found and fixed a Terraform-side NSG gap along the way — added back `cp_in_vxlan_workers` (worker→cp UDP 4789), which had been pruned earlier on flawed reasoning.

Result: 3 nodes Ready, all core cluster components healthy, kubectl accessible from Mac.

## Phase 3 — Access: ProxyJump + kubectl SSH tunnel ✅ (rolled into Phase 2)

Wired inline as part of Phase 2 (`~/.ssh/config` with ProxyJump through bastion + `~/.kube/config` pointing at the SSH-tunneled loopback endpoint).

## Phase 4 — CSI driver + StorageClasses + first PVC ✅

(CCM was already installed in Phase 2.6b — Phase 4 is CSI-only.)

1. **Installed the VolumeSnapshot CRDs (v6.3.4)** — required before any CSI manifest because the OCI CSI controller bundles snapshot-controller + csi-snapshotter containers that crashloop without the CRDs; kubeadm clusters don't ship them (OKE does, silently).
2. **Created the CSI config secret** `oci-volume-provisioner` in kube-system (mirrors CCM's cloud-provider.yaml — Instance Principals + compartment/vcn/subnet).
3. **Applied OCI CSI v1.33.2** — RBAC + node driver (DaemonSet, 3/3) + controller driver (Deployment on cp, 8/8 containers including provisioner/attacher/resizer/snapshotter).
4. **Wrote and applied the custom `oci-bv` StorageClass** to `k8s/storage/oci-bv-storageclass.yaml` — `vpusPerGB: "0"` (Lower-Cost, ~$1.28/mo per 50 GB), `attachment-type: paravirtualized` (avoids host iscsid dependency on A1.Flex), `WaitForFirstConsumer`, `allowVolumeExpansion: true`, `reclaimPolicy: Delete`, **NOT default** (using it must be explicit).
5. **Installed `local-path-provisioner` v0.0.31** — marked as the cluster default StorageClass so Helm charts that omit `storageClassName` (kube-prometheus-stack, Loki, dev DBs) land on $0 boot-volume slack instead of accidentally minting paid 50 GB Block Volumes.
6. **Fixed a 10-hour latent Calico bug** — worker-2's `calico-node` had been stuck 0/1 Ready since Phase 2. Root cause: `calico-typha` runs `hostNetwork: true` so its "pod IPs" are node IPs, felix connects to it on TCP 5473 = node-to-node traffic, and our NSG matrix didn't include any 5473 rule. Added 3 Terraform-managed rules (`cp_in_typha_workers`, `workers_in_typha_self`, `workers_in_typha_cp`), matrix rows in both plan copies, memory note. calico-node self-recovered within minutes of apply.
7. **Recovered the bastion from OOM** — bastion (E2.1.Micro, ~500 MB RAM + 498 MB swap that was near-full) had sshd unable to complete banner exchange under memory thrash. Hard-RESET via OCI CLI (soft-reset hung in STOPPING because the OS was too thrashed to shut down gracefully), added 1 GB `/swapfile2` persisted in fstab, and rewrote `~/.ssh/config` on Mac with a shared `Host k8s-*` block using `ControlMaster auto` + `ControlPersist 10m` so every `ssh k8s-*` and kubectl tunnel now multiplexes through one bastion sshd child instead of forking a new one per session.
8. **Ran the Postgres StatefulSet exercise end-to-end** (`k8s/exercise/phase4-postgres.yaml`): 1-replica StatefulSet with `volumeClaimTemplate` on `oci-bv` → observed WaitForFirstConsumer (PVC Pending → Bound once pod scheduled) → verified real 50 GB Block Volume in OCI console → inserted rows via `psql` → killed the pod, rows survived (same-node) → **cordoned the current worker, deleted pod → CSI DetachVolume from worker A → AttachVolume to worker B → filesystem re-mounted → data intact on the other worker** → online expanded PVC 5 Gi → 60 Gi without downtime → deleted the StatefulSet + PVC → confirmed the Block Volume reached TERMINATED in OCI (reclaimPolicy: Delete works, no orphan billing).

**Learning captured about the CSI + StatefulSet model:** 1 PVC per replica via `volumeClaimTemplate` → 1 PV → 1 OCI Block Volume with stable identity that follows the pod across node moves. This is why StatefulSets (not Deployments) are the pattern for anything with durable state.

## Phase 5a — Round 2 codify: 8 Ansible roles, fully idempotent ✅

Completed 2026-07-09/10. Everything hand-executed in Phases 0–4 is now
declared in code. Repository first committed and pushed to GitHub
(`nskgit/k8s-lab-infra`) at the start of the phase — the "one laptop
away from oblivion" era ended.

**Pre-work** (`faa547a`):
1. **First commit + push to GitHub** — repo had zero commits before this.
2. **Dual Terraform provider bug fix** — every module implicitly bound
   to `hashicorp/oci` 8.21.0 while root used `oracle/oci` 6.37. Added
   `versions.tf` to all 4 modules; ran `terraform state replace-provider
   registry.terraform.io/hashicorp/oci registry.terraform.io/oracle/oci`
   to migrate ~40 module-owned state resources. `terraform providers`
   now shows a single namespace.
3. **Deleted stale `errored.tfstate`** (108 KB, 43 resources, Day 1
   chunked-encoding incident).
4. **Added 3 TF outputs** (`compartment_ocid`, `vcn_id`,
   `public_subnet_id`) that the Ansible CCM role reads.

**Scaffolding** (`d7c9dd2`):
5. `ansible/ansible.cfg` — `roles_path`, `inventory`, `pipelining`,
   `ControlMaster` (later fixed: `stdout_callback = default` +
   `result_format = yaml` because `community.general.yaml` callback was
   removed in v12).
6. `ansible/group_vars/all.yml` — single source of truth for every
   pinned version (k8s 1.33.13, containerd 2.2.5, Calico v3.28.2 +
   Tigera v1.34.5, OCI CCM/CSI v1.33.2, snapshotter CRDs v6.3.4). All
   values verified against the live cluster before pinning.
7. `ansible/inventory/hosts.ini` — static for 5a (dynamic inventory
   deferred to Block 11); ProxyJump via bastion reserved IP; 3 nodes
   grouped as `k8s_nodes` (parent of `control_plane` + `workers`).
8. `ansible/site.yml` — 3 plays ordered by D3/D15 ownership: play 1
   base OS + runtime + k8s pkgs on all nodes; play 2 kubeadm-cp →
   cni-calico → oci-ccm → oci-csi on cp (CCM before CSI so untaint
   happens first, then CSI controller can schedule); play 3
   kubeadm-worker on workers. 8 role stubs with header docs.

**Base roles** (`d5ec6ad`) — `common`, `containerd`, `kubernetes-packages`:
9. Kernel modules (`overlay`, `br_netfilter`) persisted via
   `/etc/modules-load.d/`, loaded via `community.general.modprobe`.
10. Sysctls via `ansible.posix.sysctl` writing to
    `/etc/sysctl.d/99-k8s.conf` — one loop, no duplicate writes to
    `/etc/sysctl.conf`.
11. Swap off (fstab regex commented `swap` entries; `swapoff -a`
    guarded by `swapon --show` output).
12. firewalld stopped + disabled + **masked** (mask survives `systemctl
    enable` scripts).
13. containerd installed from Docker CE repo (fetched Docker's official
    `docker-ce.repo` via `get_url` — matches `dnf config-manager --add-repo`
    output; simpler `yum_repository` produced format drift).
    `containerd config default | sed SystemdCgroup=true` written with
    trailing newline; handler restarts on config change.
14. `pkgs.k8s.io` v1.33 repo with **upstream-standard `exclude=` line +
    `disable_excludes: kubernetes` on install** (belt+suspenders vs.
    stray `dnf install kubelet`). kubelet/kubeadm/kubectl 1.33.13
    installed and versionlocked via `community.general.dnf_versionlock`.
    versionlock task guarded `when: not ansible_check_mode` (check mode
    can't simulate the plugin install prior task).

**kubeadm-cp + cni-calico** (`f2e7d1b`):
15. **kubeadm-cp** — templates `ClusterConfiguration.yaml` from Jinja2,
    pulling the OCI instance OCID from **IMDSv2** at run-time to inject
    `provider-id: oci://<ocid>` into kubelet extraArgs (D6 — kills the
    Phase 2 post-init `kubectl patch` step; providerID is set at
    kubelet-registration time, no CCM race window). Idempotency guard
    on `/etc/kubernetes/admin.conf` — every destructive task skips on
    an already-initialized cp. Fetches admin.conf to `~/.kube/config-lab`.
16. **cni-calico** — Tigera operator v1.34.5 downloaded from upstream
    (stat-guarded), applied with `--server-side --force-conflicts` (SSA
    ownership migration from Phase 2's `kubectl-create` field manager).
    Minimal templated `Installation` CR — operator's mutating admission
    fills defaults invisible to `kubectl apply` drift detection.
    `kubectl wait` for `installation/default` Ready.

**oci-ccm + oci-csi** (`4fdd8f5`):
17. **oci-ccm** — reads TF outputs via `delegate_to: localhost` shell
    (`become: false` to skip Mac sudo password prompt). Templates
    `oci-cloud-controller-manager` Secret with
    `useInstancePrincipals: true`. Downloads exactly 2 release
    manifests (`oci-cloud-controller-manager.yaml` +
    `oci-cloud-controller-manager-rbac.yaml`) — verified via
    `api.github.com/.../releases/tags/v1.33.2`; my earlier plan notes
    listed a nonexistent third file. Waits for DaemonSet rollout
    AND for every node's `spec.providerID` to be populated.
18. **oci-csi** — same TF-outputs pattern (defensive re-read). Applies
    VolumeSnapshot CRDs FIRST (without them the CSI controller's
    csi-snapshotter sidecars crashloop). Separate `oci-volume-provisioner`
    Secret (different envelope from CCM's — CSI does not read CCM's
    secret; upstream idiosyncrasy). oci-bv StorageClass copied from
    `k8s/storage/` (single source of truth). local-path v0.0.31
    installed + marked default via `kubectl annotate` guarded by a
    pre-check reading the current annotation (kubectl annotate always
    outputs "annotated" — output-based idempotency doesn't work).

**kubeadm-worker** (`af6a1dc`) — the last role:
19. **kubeadm-worker** — stat guard on
    `/etc/kubernetes/kubelet.conf` (all destructive tasks skip on
    joined workers). Mints a fresh 10-min token via
    `kubeadm token create --print-join-command --ttl 10m` **delegated
    to control-plane-1** every playbook run — nothing persisted.
    Parses stdout regex for token + `sha256:` hash. Jinja2
    `JoinConfiguration.yaml` with `providerID` from IMDSv2 same
    as cp. Waits for the node to reach Ready from cp's kubeconfig.

**Verification standard adopted throughout:** for every role block —
1. `ansible-playbook site.yml --check --diff` (dry-run against live
   cluster) → inspect changed tasks, fix any drift.
2. `ansible-playbook site.yml` (real apply) → takes ownership of any
   pre-existing manually-applied resources (SSA with `--force-conflicts`).
3. `ansible-playbook site.yml --check --diff` again → target
   `changed=0, failed=0`. The strongest possible proof of idempotency.

Every commit above passed the third check. Cluster remained Ready
v1.33.13 throughout.

**Deferred and tracked** (not part of 5a graduation, see
`CURRENT-STATE.md`):
- Phase 5b — workers → instance pool, join-command vending
- Block 11 — CI/CD workflow (industry-standard PR pipeline)
- Dynamic inventory swap
- `kubernetes.core.k8s` module vs `command: kubectl apply`
- `kubeadm-config` ConfigMap patch as Ansible task

## Phase 6 — Istio + Gateway API + LB 443 on the real domain ✅

Completed 2026-07-12 (commit `a5ee2be`). Ran AFTER Phase 7 metrics by
deliberate re-ordering — observability first meant every Istio component
landed with dashboards already watching.

**The path that now serves 5 public hostnames:**
GoDaddy DNS (`*` A-record) → OCI LB (80 HTTP-L7 / 443 TCP-L4 passthrough)
→ NodePort 30080/30443 → istio-ingressgateway Envoy (TLS terminates; lab
CA wildcard) → HTTPRoutes → Services → pods.

1. **Gateway API CRDs v1.2.1** (standard channel) — K8s doesn't ship
   them, Istio doesn't install them.
2. **LB 443 in Terraform** — `nodeport_https` var + backend set (TCP
   health check) + **TCP passthrough listener** (L4: LB never decrypts;
   no LB certificate — Envoy owns TLS). Fixed the stale Phase-1 comment
   claiming 443 needed a cert. Plan showed exactly +3.
3. **Real domain replaced nip.io**: `satheshkumarnapoleon.site` at
   GoDaddy, one `*` A-record → LB IP. GoDaddy DNS API is gated → no
   DNS-01/wildcard Let's Encrypt; upgrade = cert-manager HTTP-01 (post-
   ingress by definition) or DNS to Cloudflare.
4. **Lab CA**: 10-year root + 1-year wildcard (SANs `*.domain` + apex),
   keys in `~/.k8s-lab-secrets/lab-ca/` (600), Secret
   `istio-ingressgateway-tls-wildcard` (kubernetes.io/tls) in
   istio-system. Regen runbook in `k8s/istio/README.md`.
5. **Istio 1.30.2** Helm base → istiod → gateway: global proxy
   **25m/64Mi** (the capacity knob — default 100m/128Mi × every pod
   would eat a worker), gateway Service **pinned NodePort 30080/30443**
   (2nd-LB trap defused; gate check confirmed exactly one LB in OCI).
   Gotcha: gateway chart key is `replicaCount` (strict schema rejected
   `replicas:`).
6. **Gateway (manual mode)** — `spec.addresses` pinned to the existing
   istio-ingressgateway Service so Istio programs it rather than
   auto-deploying a per-Gateway LoadBalancer Service. Two listeners:
   HTTP:80 (allowedRoutes All) + HTTPS:443 Terminate with the wildcard
   Secret. Lesson captured: **Envoy is an empty shell until a Gateway
   programs it** — pre-Gateway the LB shows 502 (no healthy backends,
   nothing listens on pod:80); post-Gateway 404 (Envoy: no route); with
   routes 200. That 000/502/404/503/200 ladder is the ingress debugging
   taxonomy.
7. **echo demo** — namespace `demo` labeled istio-injection=enabled
   (pods 2/2; sidecar resources verified at 25m/64Mi), HTTPRoute binding
   both listeners. **XFF lesson live**: HTTP path shows client IP +
   hop chain (L7 LB injects); HTTPS path shows only a SNAT'd Calico
   VXLAN address (L4 passthrough — LB can't inject; PROXY protocol v2 /
   Network LB are the Phase 15 options).
8. **Expansion S1 — httpbin**: app #2 = one manifest, zero platform
   changes. Image lesson repeated: go-httpbin `2.15.0` tag doesn't
   exist (404 → 1/2 ImagePullBackOff with sidecar healthy); verify tags
   against the registry API before pinning (`2.23.1` used).
9. **Expansion S2 — Grafana route**: exposed the EXISTING kps Grafana at
   grafana.<domain> — HTTPRoute in `monitoring` (ownership: route lives
   with the app) + `grafana.ini server.root_url` (apps behind a TLS-
   terminating proxy must know their public URL — same lesson as
   WordPress below). Named compromise: admin UI on the PUBLIC gateway
   behind app login; prod = internal gateway on a private LB + SSO.
   Backends do NOT need sidecars to receive gateway traffic.
10. **Blog stack (host-an-app demo)** — `apps` ns (injected):
    - MariaDB **StatefulSet** + volumeClaimTemplate (2Gi local-path,
      Bound via WFFC), **sidecar.istio.io/inject: "false"** per the
      Phase 9 capacity rule (visible as 1/1 vs the apps' 2/2).
    - Credentials Secret created via CLI only — manifests reference by
      name; git never sees values (D4 formalizes at Phase 8).
    - WordPress + Adminer both connect via the `mariadb` Service VIP;
      WordPress needed WP_HOME/WP_SITEURL + X-Forwarded-Proto handling
      (third occurrence of the public-URL lesson). Live blog installed
      via browser wizard; Adminer shows the wp_* tables it created.
11. **Expansion S3 — canary**: echo-v2 with its OWN labels + Service
    (same-label pods would blend at the v1 Service level), HTTPRoute
    backendRefs weighted 90/10. Measured 56/4 at n=60 (binomial wobble
    expected). This is the primitive Argo Rollouts/Flagger automate.
12. **mTLS proven**: echo→httpbin `/headers` shows X-Forwarded-Client-
    Cert with SPIFFE identities (`spiffe://cluster.local/ns/demo/sa/
    default` both sides — dedicated per-workload ServiceAccounts are the
    prod upgrade enabling AuthorizationPolicy). Sidecars bypass
    kube-proxy east-west: Envoy targets pod IPs from istiod's endpoint
    push. Tooling lesson repeated: echo image has wget not curl.

Ordering note for the master-plan redo: **7 → 6 worked better than
6 → 7** (metrics watching the mesh install), but 6 → 7's Istio
telemetry items (ServiceMonitor/PodMonitor + Kiali) are still pending
either way — tracked for the Phase 8 window.

## Phase 7 — kube-prometheus-stack + Alertmanager + Grafana

**Pre-work complete** (`3c430d0`, 2026-07-10):

1. **KCM + scheduler bind-address = 0.0.0.0** (the kubespray-standard
   fix, done the kubeadm-documented way in three layers):
   - `kubeadm/ClusterConfiguration.yaml` + Ansible j2 template updated
     with `controllerManager.extraArgs: bind-address=0.0.0.0` and a new
     `scheduler.extraArgs` block → fresh rebuilds are born correct.
   - `kubeadm-config` ConfigMap in `kube-system` patched via a one-off
     Python script (pyyaml-based structural edit; scratchpad) → future
     `kubeadm upgrade` re-renders manifests WITH the flag instead of
     reverting it.
   - `kubeadm-cp` role has two idempotent `ansible.builtin.replace`
     tasks that flip the live static-pod manifests — config management
     executes the change, not a human in vi. Kubelet auto-restarted
     both pods (~20s KCM/scheduler blip on single cp; zero workload
     impact).
   - Verified: `ss -tlnp` shows `*:10257 kube-controller` and `*:10259
     kube-scheduler`; worker `curl -sk https://cp:10257/metrics` returns
     403 (TLS + RBAC authn active, anonymous rejected — production
     posture).

2. **4 NSG rules added** (`terraform plan` showed exactly `+4 add, 0
   change, 0 destroy`):
   - `cp_in_kcm_workers` — worker → cp:10257
   - `cp_in_scheduler_workers` — worker → cp:10259
   - `cp_in_node_exporter_workers` — worker → cp:9100 (node-exporter
     DaemonSet tolerates cp taint)
   - `workers_in_node_exporter_self` — worker → other-worker:9100
   - kubelet 10250 rules already existed from the original matrix.
   - etcd 2381 + kube-proxy 10249 stay closed (ServiceMonitors disabled
     by plan; NSG rule + values flip both trivially reversible).

3. **Bonus fix**: `cni-calico` role's tigera-operator manifest download
   is now stat-guarded — `get_url` in `--check` reported would-download
   without verifying bytes; every subsequent check falsely showed
   changed=1 without this guard.

4. `k8s/observability/kps-values.yaml` written (180 lines) with sizing,
   storage rationale, scrape target selection, Alertmanager routing
   tree (null-receiver for now; Slack webhook in P7-5), Grafana
   persistence off + ConfigMap sidecar loading, admin creds via
   pre-created Secret.

**Install complete** (2026-07-11, commits `dd14a27` + `7e9f9bb`):

- **`helm upgrade --install kps`** — chart `prometheus-community/kube-prometheus-stack` v87.12.3 into `monitoring/`.
  - Two install-time fixes needed:
    - **`--disable-openapi-validation`** — the apiserver OpenAPI schema
      fetch timed out through the SSH tunnel (schema is large in 1.33
      with all our CRDs; helm downloads it for client-side manifest
      validation on pre-install hooks). Server-side apply still
      validates on the API side, so no safety loss. A CI runner inside
      the cluster network wouldn't need this flag.
    - **`cpu: null` schema violation** — Prometheus CRD rejected
      `spec.resources.limits.cpu: "null"`. Correct K8s idiom for "no
      CPU limit" is to omit the field entirely from `limits`. Fixed
      in kps-values.yaml.
  - Also had to `helm uninstall kps --no-hooks` twice to clear stuck
    `pending-install` / `failed` release markers between retry attempts.
  - Result: 8 pods Running (Prometheus, Alertmanager, Grafana with 3
    containers, kube-state-metrics, operator, 3× node-exporter DS).

- **Verified scrape targets** end-to-end via
  `kubectl port-forward svc/kps-prometheus 9090:9090` + `curl /api/v1/targets`.
  ALL 11 scrape jobs `up`:
  - `kube-controller-manager` UP → **acceptance test for P7-1 bind-address + P7-2 NSG cp:10257 passed**
  - `kube-scheduler` UP → same, cp:10259
  - `node-exporter` 3/3 UP including cp (toleration + NSG cp:9100)
  - `kubelet` 9/9 UP (3 nodes × 3 endpoints: `/metrics`, `/metrics/cadvisor`, `/metrics/probes`)
  - `apiserver`, `coredns`, `kps-alertmanager`, `kps-grafana`,
    `kps-operator`, `kps-prometheus`, `kube-state-metrics` — all UP

- **metrics-server installed** (chart `metrics-server/metrics-server`,
  pinned) into `kube-system`. Values file at
  `k8s/observability/metrics-server-values.yaml`. Lab compromise
  documented: `--kubelet-insecure-tls` (production upgrade path is
  kubelet `serverTLSBootstrap: true` + CSR approver — noted for Phase 15).
  - APIService `v1beta1.metrics.k8s.io` = `Available: True`.
  - `/livez`, `/readyz`, `/readyz?verbose` all 200 OK (8 readiness sub-checks passing).
  - `/metrics` returns 403 for anonymous — proves TLS + RBAC end-to-end.
  - `kubectl top nodes` and `kubectl top pods -A --containers` work.

- **Grafana walkthrough** — port-forward `svc/kps-grafana 3000:80`
  → http://localhost:3000 → login `admin` + password from
  `~/.k8s-lab-secrets/grafana-admin-password`. 27 dashboards
  auto-loaded via the ConfigMap sidecar pattern (labels
  `grafana_dashboard: "1"`). "Kubernetes / Controller Manager" and
  "Kubernetes / Scheduler" dashboards populate → visual proof of
  Phase 7 pre-work end-to-end.

- **Alertmanager walkthrough** (P7-5) using live firing alerts:
  routing tree (root + child routes with matchers), grouping
  (`group_by`, `group_wait`, `group_interval`, `repeat_interval`),
  matchers (label-based routing), silences (mute mechanic, via UI
  and `amtool`), inhibition (critical → warning suppression by
  `equal:` labels), receiver types (null / Slack / PagerDuty / webhook).
  Real anti-affinity deadlock diagnosed in `default/nginx-anti-affinity`
  and fixed as a demonstration. Slack webhook wiring pattern (Secret +
  `api_url_file` production pattern) explained + values.yaml diff
  prepared, actual apply parked until a webhook URL is available.

Phase 7 metrics is **effectively complete**. Only Phase 7b (Loki +
Fluent Bit logging) remains before moving to Phase 6 (Istio) or Phase 8
(Argo adoption).

## Phase 8 — Argo CD + root-app; platform adopted as Argo apps

_TBD_

## Phase 9 — Wave-1 services → CI → dev

_TBD_

## Phase 10 — First promotion PR → prod

_TBD_

## Phase 11 — Wave-2 services

_TBD_

## Phase 12 — Validation: k6 load, chaos, full teardown → pipeline rebuild (DR rehearsal)

_TBD_

## Phase 13 — Phase B: self-hosted CI runner; close bastion public SSH

_TBD_

## Phase 14 — DR region: `dr/` root, ApplicationSets, cross-region backups

_TBD_

## Phase 15 — Stretch: HPA, Cluster Autoscaler, Sealed Secrets, Harbor, multi-arch

_TBD_
