# Learning log — Phase 0 + Phase 1

Quick-reference of every command actually used, with its use case. Grouped by tool.

---

## 1. Bash / repo scaffolding

| Command | Use case |
|---|---|
| `mkdir -p ~/workspace/k8s-lab-infra && cd $_` | Create the repo directory |
| `git init` | Initialize a local git repo (no remote yet — GitHub wiring is Phase 5+) |
| `mkdir -p terraform/{bootstrap,modules/{network,cluster-node,lb,iam-ccm},primary,dr}` | Create the whole Terraform tree in one shot with brace expansion |
| `find . -type d -not -path './.git*' \| sort` | Verify the tree exists without noise from `.git/` internals |
| `cat > <file> <<'EOF' ... EOF` | Write a multi-line file from the shell; single quotes around `EOF` prevent `$VAR` expansion |

## 2. SSH — keys, config, ProxyJump, tunnels

| Command | Use case |
|---|---|
| `ssh-keygen -t ed25519 -f ~/.ssh/k8s_lab_ed25519 -C k8s-lab` | Generate a dedicated ed25519 keypair for this lab (not reusing `id_rsa`) |
| `cat ~/.ssh/k8s_lab_ed25519.pub` | Get the public key content to paste into `terraform.tfvars` |
| `ssh k8s-bastion` | Interactive shell on the bastion (uses `~/.ssh/config`) |
| `ssh k8s-cp` | Interactive shell on the control plane via ProxyJump through bastion |
| `ssh k8s-worker-1`, `ssh k8s-worker-2` | Same, into either worker |
| `ssh k8s-cp hostname` | One-shot command — quick way to prove the connection works |
| `ssh -N -L 6443:127.0.0.1:6443 k8s-cp` | (Phase 2+) Local port tunnel — Mac's :6443 → cp's :6443 via SSH tunnel. `-N` = no shell, just hold the tunnel |
| `ssh-add ~/.ssh/k8s_lab_ed25519` | Load a key into `ssh-agent` (needed only if you set a passphrase) |
| `ssh-add -l` | List identities currently loaded in `ssh-agent` |
| `ssh-add -d <keyfile>` | Remove a specific key from `ssh-agent` |
| `ssh-add -D` | Remove ALL keys from `ssh-agent` |

**Key `~/.ssh/config` idioms:**
- `IdentityFile ~/.ssh/k8s_lab_ed25519` — which key to use
- `IdentitiesOnly yes` — try ONLY that key (don't offer every key in the agent; avoids `MaxAuthTries` at the bastion)
- `ProxyJump k8s-bastion` — go through this host first
- `chmod 600 ~/.ssh/config` — SSH refuses group/world-readable configs

**Gotchas discovered:**
- `ssh -i <key> -J bastion cp` may **not** propagate `-i` to the jump host on macOS — bastion tries default keys and fails. Fix with `~/.ssh/config` (each host gets its own `IdentityFile`).
- `ssh -N -L ... bastion cp` (missing `-J`) opens a tunnel to **bastion's loopback**, not cp's. Always include `-J`. In config, `ProxyJump` handles this.

## 3. OCI CLI — auth, discovery, cleanup

### Authentication and hygiene

| Command | Use case |
|---|---|
| `oci setup repair-file-permissions --file ~/.oci/config` | Tighten mode on OCI config so CLI stops warning |
| `oci iam compartment list` | Sanity-check that CLI auth works against your tenancy |
| `export SUPPRESS_LABEL_WARNING=True OCI_CLI_SUPPRESS_FILE_PERMISSIONS_WARNING=True` | Silence noisy CLI warnings in scripts |

### Discovery / read

| Command | Use case |
|---|---|
| `oci iam compartment list --all --query "data[?name=='k8s-lab']"` | Find a compartment by name (JMESPath filter) |
| `oci network vcn list --compartment-id $CID` | List VCNs in a compartment |
| `oci network subnet list --compartment-id $CID --vcn-id $VID` | List subnets inside a specific VCN |
| `oci network nsg list --compartment-id $CID --vcn-id $VID` | List NSGs inside a VCN |
| `oci network route-table list --compartment-id $CID --vcn-id $VID` | List route tables in a VCN (includes default) |
| `oci network internet-gateway list --compartment-id $CID --vcn-id $VID` | List IGWs in a VCN (same pattern for `nat-gateway`, `service-gateway`) |
| `oci compute instance list --compartment-id $CID --lifecycle-state RUNNING` | Filter running instances only |
| `oci lb load-balancer list --compartment-id $CID` | List LBs |
| `oci network public-ip list --compartment-id $CID --scope REGION` | List reserved public IPs in region |
| `oci iam policy list --compartment-id $CID` | List IAM policies in a compartment |
| `oci iam dynamic-group list --compartment-id $TID` | List dynamic groups (always live at TENANCY root — use `$TID`) |
| `oci os bucket list --compartment-id $CID --namespace <ns>` | List Object Storage buckets |
| `oci os object list --bucket-name <b> --namespace <ns> --prefix <p>` | List objects with a prefix — used to check the tfstate file |
| `oci artifacts container repository list --compartment-id $CID` | List OCIR repos |
| `oci bv boot-volume list --compartment-id $CID --availability-domain "<AD>"` | List boot volumes (orphaned ones bill for storage) |

### Delete / cleanup

| Command | Use case |
|---|---|
| `oci compute instance terminate --instance-id $I --force --preserve-boot-volume false` | Terminate an instance + auto-delete its boot volume |
| `oci lb load-balancer delete --load-balancer-id $L --force` | Delete an LB (returns work request; runs async) |
| `oci network subnet delete --subnet-id $S --force --wait-for-state TERMINATED` | Delete a subnet and block until it's gone (needs all VNICs detached first) |
| `oci network nsg delete --nsg-id $N --force` | Delete an NSG |
| `oci network route-table delete --rt-id $R --force` | Delete a non-default route table (VCN's default gets skipped by OCI automatically) |
| `oci network internet-gateway delete --ig-id $G --force` | Delete an IGW (same pattern for NAT/service gateway) |
| `oci network vcn delete --vcn-id $V --force --wait-for-state TERMINATED` | Delete a VCN (everything inside must be gone first) |
| `oci network public-ip delete --public-ip-id $P --force` | Delete a reserved public IP |
| `oci iam policy delete --policy-id $P --force` | Delete an IAM policy |
| `oci iam dynamic-group delete --dynamic-group-id $D --force` | Delete a dynamic group |
| `oci bv boot-volume delete --boot-volume-id $B --force` | Delete an orphaned boot volume |

**Dependency order for full VCN teardown:** instances → LBs → subnets → NSGs → non-default route tables → gateways (IGW, NAT, SGW) → VCN.

## 4. Terraform

### Everyday commands

| Command | Use case |
|---|---|
| `terraform fmt -recursive -check -diff` | Check formatting across the tree, print diffs, exit non-zero if anything's off |
| `terraform fmt -recursive` | Actually apply formatting fixes |
| `terraform validate` | Syntax + type checks (no cloud calls) |
| `terraform init` | Download providers, configure backend, prepare `.terraform/` |
| `terraform init -backend=false` | Init without configuring backend (validate-only) |
| `terraform init -reconfigure -backend-config=backend.hcl` | Re-init when you change backend settings |
| `terraform init -backend-config=backend.hcl -migrate-state` | Move local state up to the remote backend on first switch |
| `terraform plan -var-file=terraform.tfvars` | Refresh state + show diff. No changes |
| `terraform plan -var-file=terraform.tfvars -out=tfplan.bin` | Save the plan to disk so `apply tfplan.bin` runs it exactly |
| `terraform plan -refresh=false` | Skip refresh (fast; state may be stale) |
| `terraform plan -refresh-only` | Only refresh — no config diff |
| `terraform apply -var-file=terraform.tfvars` | Plan + prompt yes/no + apply |
| `terraform apply -auto-approve -var-file=terraform.tfvars` | Same, no prompt (used in CI) |
| `terraform apply tfplan.bin` | Apply exactly what's in the saved plan file |
| `terraform apply -target=module.iam_ccm.oci_identity_policy.ccm_csi -var-file=terraform.tfvars` | Apply only a specific resource + its dependencies (used to test state backend before full apply) |
| `terraform apply -var-file=terraform.tfvars <<< "yes"` | Answer the interactive prompt from a script |
| `terraform output` | Show output block from last apply |
| `terraform output -raw <name>` | Print raw output value (no quotes, no formatting) — used to fetch sensitive values into env files |
| `terraform state list` | List all resources currently tracked in state |
| `terraform state show <resource>` | Show current attributes of one state resource |
| `terraform show -json` | Full state as JSON — pipeable to `jq` |
| `terraform state pull > snapshot.json` | Download current backend state to a local file |
| `terraform state rm <resource>` | Remove a resource from state without destroying it in the cloud |
| `terraform import <resource> <cloud-id>` | Adopt an existing cloud resource into state |
| `terraform force-unlock <lock-id>` | Break a stuck state lock (last resort) |

### Backend / state locking

| Command | Use case |
|---|---|
| `source ~/.k8s-lab-secrets/state-backend.env` | Load AWS-style creds + AWS SDK checksum env vars into shell before any Terraform op on `primary/` |

**Env file (`~/.k8s-lab-secrets/state-backend.env`) must contain:**
```
export AWS_ACCESS_KEY_ID=...
export AWS_SECRET_ACCESS_KEY=...
export AWS_REQUEST_CHECKSUM_CALCULATION=WHEN_REQUIRED
export AWS_RESPONSE_CHECKSUM_VALIDATION=WHEN_REQUIRED
```

The last two are **mandatory** — without them, OCI's S3-compat rejects PUTs with `501 NotImplemented: AWS chunked encoding not supported`, and state saves silently fail mid-apply → duplicated resources on re-run.

### `backend.hcl` (in `terraform/primary/`)

```hcl
bucket    = "k8s-lab-tfstate"
key       = "primary/terraform.tfstate"
region    = "us-ashburn-1"
endpoints = { s3 = "https://<namespace>.compat.objectstorage.us-ashburn-1.oraclecloud.com" }
use_path_style              = true
use_lockfile                = true        # verified atomic against OCI (412 on conflict)
skip_region_validation      = true
skip_credentials_validation = true
skip_metadata_api_check     = true
skip_requesting_account_id  = true
skip_s3_checksum            = true
```

### Local override to plan without a remote backend

```
cat > terraform/primary/override.tf <<'EOF'
terraform { backend "local" {} }
EOF
terraform init -reconfigure
```

`override.tf` is gitignored via the `.gitignore` in the repo root. Remove it and `-reconfigure` back to `backend.hcl` before real applies.

## 5. Debugging gotchas we hit (won't forget)

| Symptom | Root cause | Fix |
|---|---|---|
| `plan` fails: `Attempt to index null value` on `data.oci_core_images.ol_x86.images[0].id` | Image data source used the k8s-lab compartment OCID (placeholder before bootstrap-apply) — OCI returns empty | Use `var.tenancy_ocid` for platform image lookups |
| `plan` fails: `for_each` on `oci_load_balancer_backend` — "keys derived from resource attributes" | `for_each = toset(worker_ips_list)` — IPs known only after apply | Change to `map(string)` keyed by static worker name; iterate `for_each = var.backend_ips` |
| `apply` fails: OCIR `400-BAD_REQUEST, Setting isImmutable is not currently supported` | OCI API in us-ashburn-1 rejects `isImmutable` on create | Drop `is_immutable` from `oci_artifacts_container_repository`. Enforce tag immutability at CI in Phase 9 |
| `apply` fails: `securityRules[0].description size must be between 1 and 255` | NSG rule description too long | Shorten descriptions to ≤ 255 bytes (careful: `↔` and other UTF-8 chars are multi-byte) |
| `plan/apply` fails: `501 NotImplemented: AWS chunked encoding not supported` | AWS SDK v2 default checksum triggers chunked-encoding PUT which OCI rejects | Export `AWS_REQUEST_CHECKSUM_CALCULATION=WHEN_REQUIRED` + `AWS_RESPONSE_CHECKSUM_VALIDATION=WHEN_REQUIRED` |
| `apply` fails mid-way, next `apply` recreates everything | State PUT failed silently earlier due to chunked-encoding; state bucket empty | Same env-var fix as above; then clean up any duplicates via `oci` CLI |
| SSH: `Permission denied (publickey)` at bastion | `-i <key>` on outer command doesn't reach jump host on macOS SSH | Use `~/.ssh/config` with `IdentityFile` + `IdentitiesOnly yes` per host |
| SSH: silent tunnel that goes nowhere useful | Missing `-J`; `-L 6443:127.0.0.1:6443 opc@bastion` tunnels to bastion's loopback, not cp's | Always use `-J bastion` or (better) `ProxyJump` in config |
| `kubeadm init` fails: `unknown field "cloudProvider"` in KubeletConfiguration | `--cloud-provider` is a kubelet CLI flag, not a config-file field | Put it in `nodeRegistration.kubeletExtraArgs` (Init/JoinConfiguration) |
| apiserver CrashLoopBackOff: `Error: unknown flag: --cloud-provider` | Flag removed from kube-apiserver in K8s 1.29+ (deprecated 1.24) | Only `controllerManager.extraArgs` + kubelet keep `cloud-provider: external` |
| Node INTERNAL-IP `<none>`; typha endpoints empty; calico-node `[FATAL] Typha discovery failed`; `kubectl logs/exec` broken | With `cloud-provider=external`, kubelet doesn't set node addresses — no CCM + no `--node-ip` = addressless node; hostNetwork pods inherit "no IP" | Add `node-ip` to kubeletExtraArgs; live-fix via `/var/lib/kubelet/kubeadm-flags.env` + kubelet restart. Install CCM right after CNI |
| calico-node readiness fails: `BIRD is not ready` | Tigera operator defaults `bgp: Enabled` even for VXLAN pools | `kubectl patch installation default --type=merge -p '{"spec":{"calicoNetwork":{"bgp":"Disabled"}}}'` |
| OCI CCM: `Failed to map providerID to instanceID, and error by node name` | CCM's name→instance lookup failed despite matching VNIC hostname label | Patch providerID manually: `kubectl patch node <n> -p '{"spec":{"providerID":"oci://<instance-ocid>"}}'` — CCM initializes the node seconds later |
| OCI CCM manifest downloads are 14-byte 404 pages | `raw.githubusercontent.com/.../manifests/...` paths don't exist for release tags | Use `github.com/oracle/oci-cloud-controller-manager/releases/download/<tag>/<file>`; pick tag matching K8s minor |
| Cluster DNS times out silently from worker pods (external + internal) | `cp_in_vxlan_workers` NSG rule missing → workers can't reach CoreDNS pod IPs on cp | Any non-hostNetwork pod that lands on cp (kubeadm CoreDNS, Calico Deployments) needs `worker → cp UDP 4789`; ensure the rule is present |
| busybox `nslookup kubernetes.default` returns NXDOMAIN even with DNS working | busybox nslookup doesn't append `search` paths for the initial query; CoreDNS only serves `.cluster.local` | Use the FQDN `kubernetes.default.svc.cluster.local`, or `curl` instead — real client libraries honor `resolv.conf` search paths correctly |
| `calico-node` on one node stuck 0/1 Ready for hours; felix logs `Failed to connect to typha endpoint … i/o timeout`; other nodes fine | `calico-typha` runs with `hostNetwork: true`, so its "pod IPs" are node IPs. felix discovers typha endpoints directly and connects on TCP 5473 — that's node→node traffic, which the initial NSG matrix didn't include | Add NSG rules for TCP 5473: worker→cp, worker→worker, and cp→worker (defensive). Verify with `ssh <node> 'timeout 3 bash -c "</dev/tcp/<typha-node-ip>/5473" && echo OPEN \|\| echo BLOCKED'` |
| Bastion SSH suddenly hangs on banner exchange; TCP :22 accepts but no session opens; other things (kubectl tunnel, ssh through proxy) all fail | E2.1.Micro is ~500 MB RAM + ~500 MB default swap. Many concurrent `ssh k8s-*` from Mac + kubectl tunnel + shell sessions = each forks its own sshd child (~25 MB RSS); memory + swap saturates and sshd stops accepting new sessions | Hard RESET via `oci compute instance action --action RESET` (soft reset hangs in STOPPING). Add 1 GB `/swapfile2` persisted in fstab. **Fix the cause**: add `Host k8s-*` block in `~/.ssh/config` with `ControlMaster auto` + `ControlPath ~/.ssh/cm/%r@%h:%p` + `ControlPersist 10m` — every `ssh k8s-*` now shares ONE bastion sshd child |
| Netshoot debug pod as the standard troubleshooting workflow | Container-level tooling (busybox `nslookup`, `ping`) is limited; kubectl exec into a purpose-built debug pod is what production teams do | `kubectl run debug --image=nicolaka/netshoot --restart=Never --overrides='{"spec":{"nodeName":"<target>"}}' --command -- sleep infinity` → `kubectl exec -it debug -- bash` → inside: `dig`, `nc`, `curl`, `tcpdump`, `mtr`, `nslookup` — all pre-installed |
| Deployment vs StatefulSet — which to use with persistent storage | Deployment pods have no stable identity → K8s can't map replica ↔ PVC; the `volumeClaimTemplate` field is StatefulSet-exclusive | Singleton stateful workload → StatefulSet with `replicas: 1` (not Deployment with a PVC). RollingUpdate + shared RWO PVC on a Deployment = silent deadlock — new pod stays Pending because old still holds the volume. If you MUST use a Deployment, `strategy: Recreate` + a pre-created PVC works |
| App writing "files" / needing storage — what strategy | Most "I need to store a file" instincts are actually one of: (a) a log — belongs on stdout, (b) a durable artifact — belongs in Object Storage, (c) ephemeral scratch — belongs in emptyDir. Genuine persistent local storage = only databases and TSDBs | Decision tree in `docs/PROJECT-PLAN-v3.md §9` + memory `project_app_storage_strategy.md`. Rule of thumb: if reaching for a PVC on a Deployment, one of five questions redirects you (log → stdout / durable → Object Storage / ephemeral → emptyDir / database → StatefulSet / working around statefulness → rethink) |
| PV/PVC/StorageClass concepts vs what Phase 4 Chunk C showed | Chunk C hid the PV creation inside the StatefulSet + StorageClass conspiracy — the PV existed but you didn't hand-write it | Study `k8s/exercise/pv-pvc-sc-dynamic.yaml` (SC + PVC only, PV auto-created) and `pv-pvc-sc-static.yaml` (all three explicit, PV points at a pre-existing BV OCID). Static is for adopting existing volumes; dynamic is for 99% of workloads |

## 6. Repo file layout (for orientation)

```
k8s-lab-infra/
├── terraform/
│   ├── bootstrap/     one-time: compartment + state bucket + OCIR repos
│   ├── modules/       reusable: network, cluster-node, lb, iam-ccm
│   ├── primary/       root: wires modules, one state file in Object Storage
│   └── dr/            (Phase 14 stub)
├── ansible/           (Phase 5 stub)
├── kubeadm/           (Phase 2 stub)
└── docs/              plan + this learning log
```

Local secrets (never committed): `~/.k8s-lab-secrets/state-backend.env` (AWS-style creds + checksum env vars), `~/.ssh/k8s_lab_ed25519`.
