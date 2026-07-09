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

## Phase 5 — ROUND 2 codify: Ansible from CI, destroy → rebuild via pipeline

_TBD_

## Phase 6 — Istio + Gateway API, LB wiring, nip.io hosts

_TBD_

## Phase 7 — kube-prometheus-stack + Kiali + Alertmanager

_TBD_

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
