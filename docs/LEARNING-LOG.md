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

---

## 7. Phase 5a + Phase 7 — Ansible, Helm, remediation (2026-07-09/10)

### Ansible commands actually used

| Command | Use case |
|---|---|
| `ansible-galaxy collection list ansible.posix community.general` | Confirm collections are present before roles reference them |
| `ansible --version` | Verify ansible-core version + which `ansible.cfg` is loaded (the `config file =` line proves the working-dir config was picked up) |
| `ansible-playbook --syntax-check site.yml` | Parse-only: catches malformed YAML, wrong module names, unresolved role/group references. Fast pre-flight |
| `ansible-playbook site.yml --list-hosts` | Evaluates inventory + host patterns per play; shows exactly which hosts each play targets. Zero SSH |
| `ansible k8s_nodes -m ping` | End-to-end connectivity check via inventory. Not ICMP — Ansible's Python-availability check |
| `ansible-playbook site.yml --check --diff` | Dry-run against live cluster: evaluates every task, reports what would change, shows byte-level diffs for file operations. Zero writes |
| `ansible-playbook site.yml` | Real apply |
| `ansible-inventory --graph` | Visualize resolved inventory structure (useful when swapping to dynamic later) |

### The check → apply → check verification pattern

Adopted as the standard for every role block in Phase 5a:

1. **`--check --diff`** first — inspect what would change on the live
   cluster. Any `failed` task = stop and fix before applying. Genuine
   drift shown as file/manifest diffs.
2. **Real apply** — flips the drift. On resources originally created
   by Phase 2's `kubectl create -f`, server-side apply with
   `--force-conflicts` migrates field ownership from `kubectl-create`
   to the default `kubectl` manager (one-time takeover; subsequent
   applies are consistent).
3. **`--check --diff` again** — target `changed=0, failed=0`. The
   strongest possible proof of idempotency: a fresh rebuild would
   produce byte-identical state on second apply.

### Phase 5a-specific gotchas

| Symptom | Root cause | Fix |
|---|---|---|
| `ansible-playbook` errors immediately: `The 'community.general.yaml' callback plugin has been removed` | `stdout_callback = yaml` in ansible.cfg pointed at a callback removed in `community.general` v12.0.0 (we have 13.0.1) | `stdout_callback = default` + `result_format = yaml` — the modern way in ansible-core 2.13+ |
| Real apply fails: `Apply failed with 1 conflict: conflict with "kubectl-create" ... field manager` | Phase 2 manual setup did `kubectl create -f manifest.yaml` → field manager `kubectl-create`. Our role does `kubectl apply --server-side` → default manager `kubectl`. SSA refuses to overwrite fields owned by another manager | Add `--force-conflicts` to the kubectl-apply command. Takes ownership from the previous manager; subsequent applies are idempotent. Standard client-side → SSA migration |
| dnf install fails: `All matches were filtered out by exclude filtering for argument: kubelet-1.33.13-*` | pkgs.k8s.io repo file (kept from Phase 2 manual setup) has `exclude=kubelet kubeadm kubectl ...` — the upstream recommended pattern | Two-layer pinning: keep `exclude=` in the repo definition AND pass `disable_excludes: kubernetes` on the specific dnf install task. Belt+suspenders against stray `dnf install kubelet` |
| dnf_versionlock task fails: `plugin versionlock is required` | Chicken-and-egg in check mode: `dnf-plugin-versionlock` install task is marked "would install" but not actually installed, then next task tries to use it | Guard the versionlock task with `when: not ansible_check_mode`. On real apply the plugin lands first; check mode skips honestly ("would run if prerequisites were met") |
| `delegate_to: localhost` fails: `Task failed: Premature end of stream waiting for become success. >>> Standard Error sudo: a password is required` | Play sets `become: true` at play level; task inherits it; localhost is the Mac where `opc` doesn't exist and passwordless sudo isn't configured | Add `become: false` on the delegated task. Reading `terraform output -json` doesn't need root |
| `get_url` reports `HTTP Error 404: Not Found` on `cloud-controller-manager-role-bindings.yaml` | My earlier plan notes listed a nonexistent third CCM manifest. v1.33.2 ships only 2: `oci-cloud-controller-manager.yaml` + `-rbac.yaml` | Always verify release assets via `api.github.com/repos/oracle/oci-cloud-controller-manager/releases/tags/v<ver>` before hard-coding filenames |
| `kubectl annotate` shows changed every run | kubectl annotate always outputs "annotated" regardless of whether anything changed. Output-based `changed_when` idempotency doesn't work | Pre-check with a `kubectl get -o jsonpath='{.metadata.annotations.KEY}'` task registering current value; only run annotate if the read shows the annotation absent/different |
| `--check --diff` shows changed=1 forever for `get_url` even after real apply | `get_url` in check mode doesn't verify existing file bytes — just reports "would download" | Stat-guard: register a `stat: path=/tmp/X.yaml` task; add `when: not stat_result.stat.exists` on the `get_url` |
| `ansible.posix.sysctl` reports changed every run despite same values | Module writes to `/etc/sysctl.conf` by default; we ALSO wrote to `/etc/sysctl.d/99-k8s.conf` via `copy`. Two files, same content → module keeps trying to add to sysctl.conf | Pass `sysctl_file: /etc/sysctl.d/99-k8s.conf` explicitly. One module, one file, both writes-to-file and applies-to-kernel handled |
| SSA apply always shows `changed` in real apply (never `unchanged`) | kubectl `--server-side` output is always `X serverside-applied` for every object — no `unchanged` variant like client-side apply. Our `changed_when` regex catches it as changed | Cosmetic quirk only. Definitive idempotency proof = subsequent `--check --diff` which skips kubectl-apply tasks (guarded `when: not ansible_check_mode`) and reports 0 |

### Idempotency guards — the pattern that made every 5a role safe against the live cluster

- **kubeadm-cp**: `stat /etc/kubernetes/admin.conf` → every destructive
  task (`template`, `kubeadm init`) skips `when:
  admin_conf_stat.stat.exists`. Re-running the play against an
  initialized cp is a no-op.
- **kubeadm-worker**: `stat /etc/kubernetes/kubelet.conf` → every join
  task skips. Re-running against a joined worker is a no-op.
- **cni-calico / oci-ccm / oci-csi**: kubectl apply is idempotent
  server-side; `changed_when` parses `(created|configured|serverside-applied)$`;
  `when: not ansible_check_mode` skips them in dry-run because
  `ansible.builtin.command` can't dry-run without side effects.
- **All manifest downloads**: stat-guarded to prevent phantom get_url
  "changed" in check mode.

### Phase 7 pre-work gotchas

| Symptom | Root cause | Fix |
|---|---|---|
| Prometheus scrape targets for KCM `:10257` and scheduler `:10259` show `down` even with NSG rules open | kubeadm binds both to `127.0.0.1` by default. Kubespray sets `0.0.0.0` at cluster-creation for this exact reason | Layer-1 process bind (`bind-address: 0.0.0.0` in ClusterConfiguration.yaml + Ansible template + live manifest replace) AND layer-2 network (NSG rules cp → 10257/10259 from workers). Both required |
| `kubeadm upgrade` reverts a manually-patched manifest on the next release | kubeadm re-renders static-pod manifests from the `kubeadm-config` ConfigMap at upgrade time — NOT from the current manifest content | Update `kubeadm-config` ConfigMap in `kube-system` alongside the manifest edit. This is the kubeadm-documented "Reconfiguring a kubeadm cluster" procedure |
| `worker → cp:10257` returns exit code 000 from `curl` (no HTTP response) | NSG rule missing (before P7-2 apply) or bind-address still 127.0.0.1 | 403 is the desired outcome — proves the port is open AND TLS+RBAC authn is active (anonymous rejected). 000 means TCP itself failed |
| bind-address change appears to break kubelet/pods | Kubelet auto-restarts the static pod when its manifest changes; KCM/scheduler both restart | ~20s blip on single-cp; leader election handles it on multi-cp. Zero workload impact — none of KCM/scheduler are in the data path for pods |

### Command-line skeletons worth memorizing

```bash
# --check --diff, log to file for parsing
ansible-playbook site.yml --check --diff > /tmp/ansible-check.log 2>&1
grep -E 'PLAY RECAP|: ok=' /tmp/ansible-check.log | tail -6
grep -B1 '^changed:' /tmp/ansible-check.log | grep '^TASK' | sort -u

# Idempotent create-or-update (works for ns, secrets, etc.)
kubectl create ns X --dry-run=client -o yaml | kubectl apply -f -

# Structural YAML edit of a ConfigMap without kubectl edit
kubectl get cm X -o jsonpath='{.data.KEY}' > /tmp/current.yaml
# ... modify with python/yq ...
kubectl create cm X --from-file=KEY=/tmp/modified.yaml --dry-run=client -o yaml | kubectl apply -f -

# Verify listening interface (0.0.0.0 vs 127.0.0.1)
ssh k8s-cp 'sudo ss -tlnp | grep -E ":10257|:10259"'

# Reach a private port from a peer node with just curl (no cluster context)
ssh k8s-worker-1 'curl -sk -o /dev/null -w "%{http_code}\n" https://10.0.1.209:10257/metrics --max-time 5'
# 403 = port open + TLS active + RBAC rejected anonymous (desired)
# 000 = TCP failed (NSG or process not listening)
# 200 = whoops, no auth required (never expected here)
```

### Helm reference (learned this session, used in P7-3)

| Command | Use case |
|---|---|
| `helm repo add prometheus-community https://prometheus-community.github.io/helm-charts` | Add a chart repo (idempotent by name) |
| `helm repo update <repo>` | Refresh only the named repo (faster than `update` all) |
| `helm search repo <repo/chart> --versions \| head -3` | List available chart versions (top of list = latest) |
| `helm upgrade --install <release> <chart> --version <pin> -n <ns> -f <values.yaml> --wait --timeout 8m` | The one command for both first-time install and upgrade. `--wait` blocks until Deployments become Ready |
| `helm ls -A` | List all releases across namespaces |
| `helm get values <release> -n <ns>` | Show applied values (deep-merged) |
| `helm template <release> <chart> --version <pin> -f <values> -n <ns>` | Render manifests locally without touching the cluster — useful for reviewing what Argo will apply in Phase 8 adoption |

---

## 8. Phase 6 — Istio, Gateway API, TLS, real domain (2026-07-12)

### The ingress debugging ladder (memorize verbatim)

| Signal from `curl https://host/` | Broken layer | Meaning |
|---|---|---|
| `000` / timeout | Network | NSG, LB down, DNS, nothing listening |
| `502` from LB | LB → backend | All backends unhealthy (e.g. Envoy has no listener yet) |
| `404` from Envoy | Routing | Envoy + TLS fine; no HTTPRoute matches this Host |
| `503` | Backend | Route exists; Service has no ready endpoints |
| `302`/`200` | — | Working |

### Gotchas hit (symptom → cause → fix)

| Symptom | Root cause | Fix |
|---|---|---|
| Gateway chart install fails: `additional properties 'replicas' not allowed` | istio/gateway chart uses `replicaCount` and enforces a STRICT values schema (istiod uses `pilot.replicaCount` — Istio charts are non-uniform) | Rename the key. Strict schemas are a gift: typo caught at install, not silently ignored |
| Post-install: LB says 502, NodePort 30080 refuses connections, but Envoy pod Running + status port 15021 answers 200 | **The gateway Envoy opens NO traffic listeners until a Gateway CR is programmed** — it's an empty shell; only 15021/15090 listen | Not a fault. Apply the Gateway; istiod pushes listeners over xDS; LB health flips green in ~30s; 502→404 |
| `curl localhost:30080` on the node → 000 even when everything works | kube-proxy 1.29+ disables NodePorts on 127.0.0.1 (KEP-3453) | Test NodePorts against the node's real IP, never localhost |
| Pod stuck `1/2 ImagePullBackOff` | The `2/2` pattern in reverse: sidecar (container 2) healthy, app image tag `go-httpbin:2.15.0` doesn't exist | READY x/y tells you WHICH container is broken. Verify tags via registry API (`hub.docker.com/v2/repositories/<img>/tags`) before pinning |
| `kubectl exec ... -- curl` fails: executable not found (twice now: metrics-server, echo) | Distroless/minimal images ship no curl | Check first: `kubectl exec ... -- sh -c 'which curl wget'`; use wget if present; `kubectl debug --image=nicolaka/netshoot --target=<c>` if nothing is |
| WordPress/Grafana redirect loops or wrong URLs behind the gateway | App builds redirects from its own idea of its URL; Envoy terminates TLS and forwards plain HTTP | Every app behind a TLS-terminating proxy needs its public URL set (Grafana `server.root_url`, WordPress `WP_HOME`/`WP_SITEURL` + honor `X-Forwarded-Proto`) |
| HTTPS requests lose the client IP (XFF shows a 10.244.x.x address) | 443 is L4 passthrough — the LB never sees plaintext, cannot inject XFF; kube-proxy SNAT masks source | By design. L7 (80) path preserves client IP. Client IP on TLS = PROXY protocol v2 or OCI Network LB (Phase 15) |
| Let's Encrypt wildcard not automatable | GoDaddy DNS API gated behind 10+ domains/paid plan; cert-manager has no GoDaddy solver | Options: lab CA now + cert-manager HTTP-01 per-host later (needs live ingress first), or move DNS to Cloudflare (free; registrar stays GoDaddy) for DNS-01 |

### Design rules worth restating

- **Gateway = platform-owned (listeners/TLS/ports); HTTPRoute = app-owned, ships in the app's namespace.** backendRefs are namespace-local by default (ReferenceGrant otherwise) — the API pushes routes to live with their Services.
- **Gateway manual mode**: `spec.addresses` → existing Service, or Istio auto-deploys a per-Gateway LoadBalancer Service (2nd-LB trap, once per Gateway).
- **A route binds to every listener it satisfies** unless pinned with `parentRefs[].sectionName` (the HTTP→HTTPS redirect pattern).
- **Canary needs one Service per version** — same-label pods blend at the Service layer with no weight control. Weights live on backendRefs; Envoy applies per-request.
- **No sidecar on DB pods** (`sidecar.istio.io/inject: "false"`) — capacity + latency; PERMISSIVE mode makes mixed hops work.
- **Meshed east-west bypasses kube-proxy**: Envoy gets endpoints from istiod and picks pod IPs directly. mTLS identity = SPIFFE URI from the pod's ServiceAccount → dedicated SAs per workload are what make AuthorizationPolicy meaningful.

### Commands that earned their keep

```bash
# What cert is actually served through the LB (SNI-aware)
openssl s_client -connect host:443 -servername host </dev/null 2>/dev/null \
  | openssl x509 -noout -subject -issuer -dates

# Trusted round-trip with the lab CA
curl --cacert ~/.k8s-lab-secrets/lab-ca/lab-root-ca.crt https://host/

# Gateway/route state
kubectl get gatewayclass
kubectl -n istio-system get gateway lab-gateway            # PROGRAMMED=True
kubectl -n <ns> get httproute                              # per-app routes

# Weighted-split distribution test
for i in $(seq 1 60); do curl -s http://echo.<domain>/; done | grep -c echo-v2-

# mTLS proof — SPIFFE identities in the XFCC header
kubectl -n demo exec deploy/echo -c echo -- wget -qO- http://httpbin.demo.svc/headers

# Trust the lab CA on macOS (padlock goes green)
sudo security add-trusted-cert -d -r trustRoot \
  -k /Library/Keychains/System.keychain ~/.k8s-lab-secrets/lab-ca/lab-root-ca.crt
```

---

## 9. Envoy internals, native sidecars, multi-domain/multi-gateway (2026-07-12 PM)

### Native sidecar containers — where Envoy actually lives in the pod

Istio 1.30 on K8s 1.33 injects `istio-proxy` as an **init container with
`restartPolicy: Always`** (a "native sidecar", GA in K8s 1.33). So:

- `.spec.containers` = ONLY the app. `.spec.initContainers` =
  `istio-init` (run-once: writes the pod-netns iptables REDIRECT rules,
  needs NET_ADMIN, exits Completed) + `istio-proxy` (THE Envoy —
  runs for the pod's life despite being "init").
- READY `2/2` = app + native sidecar (run-once inits never count).
- Why native: proxy is Ready BEFORE the app's first instruction
  (kills the startup race / `sleep 5` hacks), proxy stops AFTER the app
  (no shutdown resets), and Jobs complete instead of hanging on a
  still-running sidecar.
- See both arrays at once (injection auditor — spot unmeshed pods):

```bash
kubectl -n <ns> get pods -o custom-columns='POD:.metadata.name,INIT:.spec.initContainers[*].name,APP:.spec.containers[*].name'
```

- Hardened variant: **istio-cni** replaces istio-init entirely
  (node-agent programs iptables; no NET_ADMIN in pods). Lab uses the
  default; name istio-cni as the upgrade.

### Inspecting a live Envoy — admin API :15000 (and istioctl)

Every istio-proxy serves an admin API on localhost:15000. Raw access:

```bash
kubectl -n <ns> exec <pod> -c istio-proxy -- curl -s localhost:15000/<endpoint>
```

| Endpoint | Shows |
|---|---|
| `/config_dump?resource=dynamic_route_configs` | Compiled route tables — HTTPRoute weights appear as `weighted_clusters` (our 90/10 visible verbatim) |
| `/certs` | mTLS chain + SPIFFE identity + expiry. **"0 days" is NORMAL** — workload certs live 24h, rotate ~12h |
| `/listeners`, `/clusters` | Inventories. A default sidecar knows EVERY service in the cluster (ours: 1096 outbound clusters) — the `Sidecar` CR scopes this down; #1 sidecar-memory lever at scale |
| `/stats \| grep update_` | xDS sync: `cds/lds update_success` counting up, `update_rejected` MUST be 0 (rejected = istiod pushed config Envoy refused) |
| `/clusters?format=json` | Per-endpoint health + weights |
| `/logging?level=debug` (POST) | Live log-level flip, no restart |

`istioctl` (**install at Phase 6 step 0 on a redo** — `brew install
istioctl`) wraps all of it: `proxy-status` (fleet xDS sync table),
`proxy-config routes|listeners|clusters|endpoints|secrets <pod>`,
`analyze -A` (mesh lint), `dashboard envoy <pod>`.

Sidecar port map (memorize): **15000** admin · **15001** outbound
capture · **15006** inbound capture · **15021** health (kubelet probes)
· **15090** Prometheus metrics · **15014** istiod control-plane metrics.

Mesh debug flow: `proxy-status` → `proxy-config routes` →
`proxy-config endpoints` → `stats | grep update_rejected`.

### Multi-domain vs multi-gateway (both built + proven)

- **Second DOMAIN ≠ second gateway.** `*.pldisturbme.site` = second
  wildcard cert signed by the SAME lab root CA + second HTTPS listener
  on the SAME :443 — **SNI** (hostname in TLS ClientHello) selects
  listener + cert. Verified without DNS: `openssl s_client -servername`
  per domain shows the right cert; `curl --resolve host:443:<LB-IP>`
  full round-trip. Listener `hostname:` doubles as route-admission
  boundary (routes bind only where hostnames intersect — the
  anti-hostname-hijack tenancy mechanism Ingress never had).
- **Second GATEWAY = different exposure.** `internal-gateway` = second
  istio/gateway helm release (own Envoy) + Gateway CR in manual mode;
  NodePort 31080 wired to NO LB listener — internet gets 404 (public
  Envoy has no route), port-forward + Host header gets 200. Isolation
  by construction, not policy.
- Route→listener binding is **implicit by hostname intersection**
  (parentRefs names only the Gateway). `attachedRoutes` in Gateway
  status is where the computed result shows. `sectionName` makes it
  explicit (HTTP→HTTPS redirect pattern).
- Hostname behavior differs per domain? **Different routes** — hostname
  is route-level, not rule-level. Canary QA access: header-match rule
  above the weighted rule (`x-canary: true` → v2 at 100%).

### Misc gotchas from the session

| Symptom | Cause | Fix |
|---|---|---|
| `.spec.containers[*].name` doesn't show istio-proxy | It's in `.spec.initContainers` (native sidecar) | Query both arrays / use the custom-columns one-liner |
| `/certs` shows expiry "0 days" | 24h workload certs, integer-floor display | Normal. istiod auto-rotates at ~12h |
| echo image has no curl | Node-based image ships wget only | `which curl wget` first; netshoot debug container otherwise |
| `helm status <release> -n <ns> -o json \| jq .info.status` | Check release lifecycle state — `deployed`, `failed`, `pending-install`, `pending-upgrade`. If pending, install/upgrade will refuse until `helm uninstall --no-hooks` clears the marker |
| `helm uninstall <release> -n <ns> --no-hooks` | Clear a stuck release marker without running post-uninstall hooks. Necessary for retry after a first-install failure |
| `--disable-openapi-validation` | Skip client-side OpenAPI schema fetch. Needed when apiserver is behind a slow tunnel or when the schema is very large (1.33 + many CRDs) — server-side apply still validates on the API side, no safety loss |

### Phase 7 install-time gotchas (kube-prometheus-stack v87.12.3)

| Symptom | Root cause | Fix |
|---|---|---|
| `helm install` fails: `failed to download openapi: net/http: request canceled ... Client.Timeout` | Helm running from Mac fetches the apiserver's OpenAPI schema for client-side manifest validation; the schema is very large in 1.33 with all our CRDs (Calico, Tigera, CSI snapshots, kube-prometheus-stack CRDs) and the SSH-tunneled connection can't finish downloading it in time | Add `--disable-openapi-validation` to `helm upgrade --install`. Server-side apply still validates on API side. A CI runner inside the cluster network wouldn't hit this |
| `helm install` fails: `Prometheus.monitoring.coreos.com "kps-prometheus" is invalid: spec.resources.limits.cpu: Invalid value: "null"` | K8s CRD schemas reject a literal `"null"` string for numeric-or-string fields. The correct idiom for "no limit" is to omit the field, not set it to null | In values.yaml: `limits: { memory: 1500Mi }` (drop the `cpu:` key entirely) |
| Second `helm install` fails: `another operation (install/upgrade/rollback) is in progress` | Previous failed install left the release marker in `pending-install` state | `helm uninstall <release> -n <ns> --no-hooks` clears the marker; then re-run install |
| CRDs already exist after a failed pre-install hook | Helm 3 installs CRDs from `crds/` directory BEFORE any pre-install hooks. If hooks fail, CRDs are still there | No fix needed — retry, helm detects existing CRDs and skips |
| `kubectl exec ... -- curl` on distroless image fails: `curl: executable file not found in $PATH` | Modern K8s components (metrics-server, kube-scheduler, CoreDNS, etc.) ship as distroless — no shell, no curl, only the app binary | Use `kubectl port-forward` + curl from your machine, OR `kubectl debug pod/X --image=nicolaka/netshoot --target=<container>` for an ephemeral container sharing the target's network namespace |

### Distroless debugging pattern (interview-worthy)

Modern k8s system components use distroless base images (`gcr.io/distroless/*`).
Traditional `kubectl exec -it ... -- curl` fails because there is no shell + no
curl in the image. The correct pattern:

```bash
# See what's actually in the image
kubectl -n <ns> exec pod/<name> -- ls / 2>&1 || echo "no shell, distroless"

# Read the probe spec — that IS the health-check contract
kubectl -n <ns> get deploy <name> -o jsonpath='
port={.spec.template.spec.containers[0].ports[0].containerPort}
liveness={.spec.template.spec.containers[0].livenessProbe.httpGet.path}
scheme={.spec.template.spec.containers[0].livenessProbe.httpGet.scheme}
'; echo

# Health-check via port-forward from your machine (works every time)
kubectl -n <ns> port-forward pod/<name> 10250:10250 &
sleep 2
curl -sk https://localhost:10250/livez -w "\n%{http_code}\n"
curl -sk 'https://localhost:10250/readyz?verbose' -w "\n%{http_code}\n"

# OR ephemeral debug container (modern K8s 1.23+ way)
kubectl -n <ns> debug pod/<name> --image=nicolaka/netshoot --target=<container> -it -- \
  curl -sk https://localhost:10250/readyz
```

`nicolaka/netshoot` is the industry-standard debug image: curl, dig, tcpdump,
netcat, ss, mtr, iperf — everything a networking-adjacent SRE ever wants.

### Alertmanager concepts practiced (P7-5)

Working knowledge from walking through the live install:

| Concept | Config key | What it does |
|---|---|---|
| **Routing tree** | `route` + nested `routes` | First-match-wins by default; `continue: true` fans out to multiple receivers |
| **Matchers** | `matchers: [severity="critical"]` or `matchers: [alertname=~"Kube.*"]` (regex) | Label-based routing; supports `=`, `!=`, `=~`, `!~` |
| **Grouping** | `group_by: [alertname, namespace]` | Bundle similar alerts into one notification; reduces spam |
| **Timing** | `group_wait: 30s` / `group_interval: 5m` / `repeat_interval: 12h` | Wait to batch, wait between batches, wait between re-notifications |
| **Silences** | Runtime object (UI or `amtool silence add`) | Mute an alert temporarily by matcher; alert stays firing but doesn't route |
| **Inhibition** | `inhibit_rules` with `source_matchers` + `target_matchers` + `equal:` | Higher-severity alert suppresses lower on same subject (e.g. critical suppresses warning) |
| **Receivers** | `receivers: - name: X, slack_configs: [...]` | Notifier definitions: `slack_configs`, `pagerduty_configs`, `webhook_configs`, `email_configs` etc. |
| **Secret handling** | `api_url_file: /etc/alertmanager/secrets/slack-webhook/url` | Prod pattern: URL in K8s Secret, mounted via `alertmanagerSpec.secrets: [slack-webhook]`, referenced by file. Never `api_url:` inline in values.yaml |
| **Templates** | `text: '{{ template "slack.default.text" . }}'` | Go templates format messages; kube-prometheus-stack ships default templates |

Interview-critical: **alerts stay firing in Prometheus regardless of silences/inhibitions.**
Alertmanager only decides whether/where to notify. Firing counts are always accurate.

---

## 10. Istio telemetry/Kiali, app-metrics, Loki+Fluent Bit logging (2026-07-13)

### Prometheus scrape topology (the full mental model)

Prometheus scrapes what **advertises `/metrics` and is registered** — it
does NOT auto-scrape every pod:

| Source | Mechanism | What it yields | Covers |
|---|---|---|---|
| node-exporter (DS) | ServiceMonitor | host CPU/mem/disk/net (`node_*`) | every node |
| kube-state-metrics (Deploy) | ServiceMonitor | k8s object STATE (`kube_*`: replicas, pod phase) | cluster objects |
| kubelet / cAdvisor | ServiceMonitor (kps-kubelet) | per-CONTAINER resource use (`container_*`) | **every container, automatic** |
| istiod | ServiceMonitor `:15014` | control-plane (`pilot_xds_pushes`…) | istiod |
| Envoy sidecars+gateways | PodMonitor `:15090` | mesh (`istio_requests_total`) | injected pods + gateways |
| an app | ServiceMonitor/PodMonitor on the app's port | the app's OWN metrics | **only if instrumented + wired** |

NOT scraped by Prometheus: **metrics-server** (separate `metrics.k8s.io`
aggregation API for `kubectl top`/HPA — parallel pipeline), and app
containers with no `/metrics` + no monitor.

### App metrics are two jobs (interview-load-bearing)

1. **Instrument** (developer): app code exposes `/metrics` via a client
   library — Go `client_golang`, Java Micrometer/Actuator, Python
   `prometheus_client`, Node `prom-client`. Without this there is
   nothing to scrape.
2. **Wire** (dev or platform): a `ServiceMonitor`/`PodMonitor` tells
   Prometheus to scrape it. Often bundled in the app's own Helm chart.

`ServiceMonitor`/`PodMonitor` are **Prometheus-Operator CRDs**, not a
Prometheus-server feature. Three parties, separate pods in our cluster:
you write the CR (intent) → `kps-operator` pod (controller) watches it,
generates the scrape config → `prometheus-kps-prometheus-0` (server)
consumes the config + scrapes. Without the operator the CR is inert.
`kind` is fixed by the CRD; `metadata.name` is any DNS-1123 string.
Vanilla Prometheus alternative: `prometheus.io/scrape` pod annotations +
hand-written `kubernetes_sd_configs`. 3rd-party black boxes → an
**exporter** sidecar (`postgres_exporter`, `redis_exporter`…). Emerging
alt: OpenTelemetry (OTLP → Collector).

**podinfo demo:** one pod, three simultaneous pipelines — app
PodMonitor (`:9797` → `http_requests_total`), envoy PodMonitor (`:15090`
→ `istio_requests_total`), kubelet/cAdvisor (`container_memory_*`).
Multi-arch `ghcr.io/stefanprodan/podinfo` (metrics on the `--port-metrics`
port 9797, not the app port).

### Kiali

Reads **Prometheus + the k8s API** (Grafana is a deep-link only, not a
data source). Real-time service graph from `istio_requests_total` — so
it needs the Istio PodMonitor first, and the graph goes EMPTY without
recent traffic (widen Duration / generate load; not a fault). `proxy-status`
rows are proxies keyed by `pod.namespace` (one proxy per pod); the gateway
that terminates TLS also subscribes to **SDS** (5 xDS types vs 4) — certs
streamed over xDS, no file mounts, no restart on rotation.

### Loki + Fluent Bit gotchas

| Symptom | Cause | Fix |
|---|---|---|
| `kubectl exec loki-0 -- wget/curl` → executable not found | Loki image is distroless (metrics-server, echo, Loki — 3rd time) | Verify from the Mac via port-forward + curl, or read logs |
| Loki `/ready` via `wget -q` returns non-zero even when healthy | `-q` masks the body; Loki serves 503+message until all components report | Check the body without `-q`, or hit `/loki/api/v1/labels` (success = ready) |
| Loki boots with a schema error | loki 6.x needs an explicit `schemaConfig` (tsdb + v13) | Provide it in values (we did) |
| Loki pod OK but chart pulls in extra components | chart defaults toward simple-scalable + gateway + memcached caches + canary + grafana-agent | `deploymentMode: SingleBinary` + disable read/write/backend/gateway/chunksCache/resultsCache/lokiCanary/monitoring.selfMonitoring |
| Every container log line mangled | Fluent Bit default parser is docker/JSON; containerd writes CRI format `<rfc3339> stdout F msg` | `multiline.parser cri` on the tail INPUT — decodes + re-stitches P/F-split lines. THE load-bearing 7b config |
| cp logs (apiserver/etcd) missing | Fluent Bit DS didn't schedule on the tainted cp | control-plane toleration on the DaemonSet |
| Log line shows as JSON blob in Grafana | `Line_Format json` ships the whole record | query `| json | line_format "{{.log}}"` to show just the message |

**Loki has no UI** — Grafana Explore IS its UI (contrast Kibana for ELK;
this is the one-pane metrics+logs advantage). Endpoints: push/query
`loki.monitoring.svc:3100`, push path `/loki/api/v1/push`. LogQL model:
`{labels}` indexed (cheap, fast) + `|= "text"` greps chunks — the
"index labels, grep content" design that makes Loki far lighter than ES.

### ELK vs Loki decision (recorded)

On this ~5 GB-unreserved free-tier cluster: ELK ≈ ES 2–3 GB + Kibana
1 GB ≈ 4 GB, ES OOM-fragile (index corruption on OOM, not clean
restart); Loki+Fluent Bit ≈ 0.7 GB, reuses Grafana. Chose Loki. The
strong interview answer isn't "I ran ELK" — it's *why* Loki on a
cloud-native/cost-sensitive platform (labels-only index + object-store
chunks + one Grafana pane), reaching for ELK/OpenSearch only when
full-text search at large volume is the actual requirement.

---

## 11. Phase 8 — Argo CD adoption (2026-07-13/14)

### The adoption recipe (per component)

1. Read installed version: `helm -n <ns> list --filter '^<release>$'`.
2. Application: multi-source (chart@EXACT version + values via
   `ref/$values`), **`helm.releaseName: <release>` ALWAYS** (Argo
   defaults it to the app name → subcharts render as duplicates —
   node-exporter would have double-deployed on hostPort 9100).
3. `kubectl apply` the Application (manual sync) → **diff before sync**
   (UI App Diff, or the API classifier: pull
   `/api/v1/applications/<app>/managed-resources`, deep-diff
   normalizedLiveState vs predictedLiveState, filter tracking-id/
   caBundle/managedFields). Annotations-only = safe.
4. Sync → resources say `configured` (adopted), never `created`; pods
   keep AGE/restarts.
5. Delete `sh.helm.release.v1.<release>.*` secrets — Helm's bookkeeping
   only. **NEVER `helm uninstall`** (deletes live resources).

### Gotchas (symptom → cause → fix)

| Symptom | Cause | Fix |
|---|---|---|
| Diff shows `<appname>-*` resources to CREATE | Argo defaulted Helm releaseName to Application name | `helm.releaseName:` = the installed release. Mandatory habit |
| Sync wedged "Running", 0 tasks, 90+ min; CLI timeouts; hook "resource missing" | **Controller OOMKilled** (512Mi) — kps's 116 resources + multi-MB CRDs; controller memory scales with the LARGEST app | 1Gi limit; delete stuck pod; clear `.operation` (patch remove); re-sync `strategy: apply`. Check `lastState.terminated.reason` FIRST when syncs wedge |
| istio webhooks perpetually OutOfSync | istiod flips failurePolicy Ignore→Fail at runtime (fail-open bootstrap) | ignoreDifferences on `webhooks[].failurePolicy` (same family: kps caBundle) |
| Kiali always OutOfSync + would restart every sync | chart bakes `randAlphaNum` signing_key into ConfigMap per render — non-deterministic | Pin the value, or don't adopt. We skipped (anonymous auth = inert key; chart has no external-secret support). **Determinism is a GitOps prerequisite** |
| ExcludedResourceWarning on kps Endpoints | Argo 3.x default `resource.exclusions` blocks v1/Endpoints; kps hand-crafts 2 for static-pod scrapes → rebuild would skip them | Override exclusions = shipped default MINUS core Endpoints (keep EndpointSlice etc.) |
| Root-app's own policy change didn't take effect | Nothing manages the root — its sync applies children, not itself | `kubectl apply` root-app.yaml after editing it (or place it in its own watched dir = self-management) |
| PreSync hook Job "is missing" errors | Job TTL/hook-delete races (aggravated by controller crashes) | Retry; or `strategy: apply` skips hooks — safe when hook outputs (webhook cert secret) already exist |
| argocd CLI gRPC "error dial proxy" over port-forward | flaky gRPC-over-forward | `ARGOCD_OPTS='--core'` + kube-context ns=argocd (talks straight to k8s API); for big apps use the REST API (session token) |

### Design rules locked in

- **Two healing layers**: Kubernetes controllers heal runtime (delete a
  pod → ReplicaSet recreates, Argo uninvolved); Argo selfHeal heals
  DECLARED objects (scale/edit/delete a Deployment → reverted/recreated).
- **Prune safety split**: prune on for ordinary apps; OFF for CRD
  carriers (CRD delete = every CR of that kind dies) and for the root
  (children carry finalizers → prune = cascade-delete a component).
- **No precedence root vs child policies** — disjoint object sets:
  root governs Application objects, child governs its component
  resources (Deployment→RS→Pod analogy).
- **GitOps horizon**: in-cluster Argo can never do day-1 CNI/CCM (no
  network / uninitialized-taint deadlock). Patterns: A bootstrap owns
  both days (ours) · B bootstrap day-1 + GitOps day-2 adoption (the
  cilium-in-Flux repos) · C hub-and-spoke management cluster (fleet).
- Argo reconciles **k8s API objects only** — CRD+operator (Crossplane
  et al) is how GitOps extends to cloud infra; we keep TF (industry
  default).

### §11 addendum — 2026-07-15 restructure (k8s/ → gitops/) lessons

| Symptom / risk | Cause | Fix / rule |
|---|---|---|
| Whole fleet ComparisonError after a tree rename lands | Root app isn't self-managed ("who manages the root") — live root still watches the old path | Rename = ONE atomic push + immediate `kubectl apply` of the new root-app. The error window is a FREEZE, not a hazard: Argo can't compute state so nothing syncs, and allowEmpty=false blocks prune-to-zero |
| platform-root permanently OutOfSync on 2 new children | `directory: {recurse: false}` is the API default → server normalizes it away → git ≠ live forever | Never declare default values in Application specs |
| Pruning a demo app could delete the whole demo namespace (incl. podinfo, owned by ANOTHER app) | echo.yaml carried the `kind: Namespace` — a workload app owned its own namespace | Namespaces get their own wave "-1" Application; every Namespace annotated `argocd.argoproj.io/sync-options: Prune=false`; workload apps NEVER contain Namespace objects |
| Fresh rebuild would fail at sync-wave 0 | Every app sets CreateNamespace=false but NO Namespace object existed in git (hole existed since Phase 8, surfaced by review) | The `namespaces` app (wave -1) declares istio-system/monitoring/demo/apps with live labels (istio-injection) |
| 13 live objects (Gateways, monitors, demo apps, blog) invisible to drift-heal and absent from rebuild | "In git" ≠ "GitOps" — kubectl-applied files nothing watches. The most common real-world GitOps failure mode: partial adoption | Coverage sweep → adopt everything or name the owner (StorageClass = Ansible/D3, Kiali = Helm exception, blog Secret = never-in-git) |
| Backing out a bad adoption deletes live resources | Applications carry resources-finalizer from birth; post-first-sync delete = cascade | Abort with `argocd app delete <app> --cascade=false` (or strip the finalizer first) — runbook now in gitops/bootstrap/README |

**Repo-split cutover (2026-07-16, B11-0a):** two-repo splits have NO
freeze window when sequenced right — push the NEW repo first, re-point
root-app, verify, THEN remove the old tree. (Contrast: the 8.5 same-repo
rename forced a ComparisonError window because old and new paths could
not coexist on one branch.) Also: `git subtree split -P <dir>` carries a
directory's history into a standalone repo; Argo repo credentials are
matched by URL, so a split = new deploy key + new labeled Secret + repoURL
edits — destination/tracking untouched, so resources never notice.

---

## 12. Incident 2026-07-16 — control-plane OOM storm (dnf makecache)

**Impact:** kubectl/API + SSH to cp dead ~40 min; DATA PLANE UNAFFECTED
(LB served 200 throughout — control/data plane separation held).

**Debug ladder (the reusable method):** error says 127.0.0.1 → check
local listener (`lsof -iTCP:6443 -sTCP:LISTEN`) → tunnel process ≠
listener → hop-by-hop: bastion OK → cp:22 TCP-open-but-NO-banner →
cp:6443 no TCP while LB serves → OCI says RUNNING (kernel alive,
userspace dead) → **serial console history** (`oci compute
console-history capture/get-content` — read the screen of a box you
can't SSH into) → 25-min OOM storm → parse the task-dump table.

**Root cause:** hourly `dnf-makecache.timer` ballooned to 3.7GB RSS
(known OL behavior) on the 8GB cp. Kernel OOM-killer selects by
oom_score_adj, NOT size: besteffort pods (CCM/CSI/typha, adj +1000,
14-25MB each) were executed serially while dnf (adj 0) was protected —
"the killer shoots the sacrificeable, not the guilty."

**Recovery:** OCI SOFTRESET → guest too wedged for ACPI graceful
shutdown (graceful shutdown NEEDS userspace) → OCI 15-min force-off
fallback → boot → all pods self-healed (restart counts: csi-ctrl 10,
etcd 3, apiserver 2). Steady-state after: 2.2GB used / 4.6GB avail →
NO resize needed (leak, not chronic pressure — evidence before money).

**Fixes:** (1) dnf-makecache.timer stopped+MASKED all nodes, codified
in common role (changed=0 verified). (2) TODO backlog: resource
requests for CCM/CSI/typha so platform pods stop being the kernel's
preferred victims (besteffort = adj +1000 = first to die).

**Gotchas collected:** `ssh -N` looks identical healthy/connecting/
wedged — always verify the LISTENER, and use ExitOnForwardFailure +
ServerAliveInterval so dead tunnels die loudly. `systemctl is-enabled`
returns rc=1 for masked units (output "masked" = success). zsh reserves
`$status` — scripts must not assign it.

---

## 13. Pipeline 2 (apps CI/CD) — built and shipped 2026-07-16

### The 6-run road to green (every gate fired for a REAL reason once)

| Run | Caught | Lesson |
|---|---|---|
| #1 | `pytest` import fails only in CI | bare `pytest` ≠ `python -m pytest` (CWD on sys.path); fix = conftest.py at service root. "Works on my machine" is an ENVIRONMENT claim |
| review | x86 runners + Trivy AFTER push | amd64 image on ARM cluster = exec format error; scan after push = report, not gate |
| #3 | pip-audit: 6 real CVEs (starlette ×5, pytest ×1) | bump + re-pin + re-verify. NEVER bypass a scanner |
| #4 | image reported version "dev" | build-arg missing in ONE of two build sites; the traceability check exists precisely for untraceable artifacts |
| #5 | publish died at "Set up job" | unresolvable `uses:` ref (trivy-action needs v-prefix). Setup-phase failure = workflow can't init; per-step API diagnoses it anonymously |
| #6 | nothing — green; image in OCIR | tag = full git SHA; digest sha256:b4baee4c… |

### OCIR mechanics (the answers to "how does docker login work")

- Registry v2 flow: `GET /v2/` → 401 + WWW-Authenticate → basic-auth
  exchanged for short-lived bearer JWT → blob PUTs + manifest PUT.
- OCIR username = `<tenancy-ns>/<user>`; password = AUTH TOKEN only
  (never the account password); **max 2 auth tokens per user**.
- Push path: runner → public 443. Pull path: kubelet → Service Gateway
  + imagePullSecret (`kubernetes.io/dockerconfigjson`, in-cluster only).
- buildx pushes an OCI INDEX: tagged index + untagged children (arch
  manifest + provenance attestation). Untagged rows are STRUCTURE, not
  litter — never "clean" them.
- SHA tags for deploys (immutable, bijective, rollback-exact); semver
  only for artifacts with consumers who upgrade on their own schedule.

### CI auth to OCI — the honest matrix (2026)

OIDC/WIF: AWS/GCP/Azure yes, **OCI no** (identity domains OIDC = user
SSO only; OCIR accepts only auth tokens). Vault from hosted runner:
chicken-and-egg (need a credential to read the vault). Instance
principal: impossible on GitHub-hosted (no OCI IMDS) — becomes THE
answer at Phase 12 self-hosted runner; kubelet image credential
providers (GA, exec plugin + instance principal) retire the PULL secret
the same way. Best today: robot user, `use repos` in one compartment,
token in GitHub secrets. **TODO: rotate the current token (exposed in
terminal/chat 2026-07-16) — tracked in task #39.**

### Workflow-authoring gotchas bank

- Steps share one VM (filesystem + docker daemon persist); explicit
  values via `$GITHUB_OUTPUT`. Jobs are separate VMs: outputs (strings)
  · artifacts (files — Block 11's tfplan.bin) · registry (images).
- `if: always()` on cleanup steps or failures hide the logs you need.
- `pull_request.branches` filters the TARGET branch — pointing it at a
  nonexistent branch silently disables all PR checks.
- `defaults.working-directory` does NOT apply to `uses:` actions.
- Unquoted `run: echo "x: y"` breaks YAML (colon+space) — use `run: |`.
- Pasting multiline commands with BLANK lines between continuations
  executes each flag as its own command.
- Unpinned `pip install tool` in CI = nonreproducible builds; pin
  everything, including the scanner that scans your pins.

**§13 addendum — stage 4 shipped (same evening):** `bump-gitops` job =
writer-class-2 bot: checkout the OTHER repo (actions/checkout with
`repository:` + fine-grained PAT), sed the tag, no-op guard, bot
identity, 3× rebase-retry for push races. First fully-automated deploy:
apps merge 4c9637e → bot commit gitops@1d84663 → Argo → live flip
observed fb02ff8→4c9637e, zero human steps. Gotcha: a job that checks
out a different repo MUST override workflow-level working-directory.
Demo A thereby completed in its best form (rolling update of one's own
service, watched from the URL).
