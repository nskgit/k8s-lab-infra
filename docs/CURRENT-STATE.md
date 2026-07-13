# Where we are — resume pointer for the next session

**Last updated:** 2026-07-13 — **Observability COMPLETE** (metrics +
mesh + logs). Phase 6 (Istio + expansions) done; Phase 7 metrics done;
Istio telemetry + Kiali done; app-metrics demo (podinfo) done; Phase 7b
(Loki + Fluent Bit) done. **Next: Phase 8 (Argo CD adoption) or Block 11
(CI/CD)** — the whole platform is now in git, ready to GitOps-adopt.

Read this file FIRST if you're a new session or coming back after a break.

---

## How to open a new Claude Code session from here

What survives between sessions:
- Everything on disk (this repo, `~/.k8s-lab-secrets/`, `~/.ssh/config`, `~/.oci/`)
- Memory files at
  `~/.claude/projects/-Users-satheshkumarnapoleon-workspace-project/memory/`
- `~/.kube/config-lab` — admin.conf fetched by Ansible

**First message for a new session:**

> Read `docs/CURRENT-STATE.md` and `docs/PHASES-COMPLETED.md` §Phase 6.
> Phases 0-5a, 6, and 7-metrics are complete. Pick up from "Next options"
> in CURRENT-STATE.

---

## Overall arc

| # | Phase | State |
|---|---|---|
| 0-4 | Foundation, TF infra, kubeadm, CCM, CSI, PV/PVC | ✅ done |
| 5a | Round 2 codify — 8 idempotent Ansible roles | ✅ done |
| 5b | Workers → instance pool + join-vending | ⏳ deferred (Phase 15 dep) |
| 7 (metrics) | kube-prometheus-stack + metrics-server + AM/Grafana | ✅ done |
| **6** | **Istio + Gateway API + LB 443 + real domain** | ✅ **done 2026-07-12** |
| 7-istio | Istio ServiceMonitor/PodMonitor + Kiali + app-metrics demo | ✅ done (`1bffc6e`,`3420902`) |
| 7b | Loki + Fluent Bit logging | ✅ done (`834dc49`,`88ef6d2`) |
| 8 | Argo CD adoption of platform | ⏭️ **next candidate** |
| Block 11 | CI/CD workflow (industry-standard PR pipeline) | ⏳ deferred |
| 9-15 | Apps, promotion, chaos/rebuild, runner, DR, stretch | ⏳ |

**Observability is COMPLETE**: metrics (Prometheus) + mesh (Kiali) +
logs (Loki), all viewable in Grafana. Missing pillar = distributed
tracing (Jaeger/Tempo, later). Logs UI: Grafana → Explore → Loki (Loki
has no UI of its own).

---

## Live state (2026-07-12)

**TWO gateways now** (`kubectl get gateway -A`):
- `lab-gateway` → public Envoy (`istio-ingressgateway`), 3 listeners:
  http:80 + https-sathesh:443 + **https-pldisturbme:443** (SNI selects
  cert; second domain `*.pldisturbme.site` — **DNS pending at
  registrar**; test via `curl --resolve host:443:157.151.193.45`)
- `internal-gateway` → dedicated Envoy (`istio-internal-gateway`),
  NodePort 31080 wired to NO LB = unreachable from internet. Access:
  `kubectl -n istio-system port-forward svc/istio-internal-gateway 18081:80`

**Public ingress — 5 hostnames on `*.satheshkumarnapoleon.site` (+1 pending domain, +1 internal):**

| Host | Backend | Notes |
|---|---|---|
| `echo.` | echo v1/v2 **weighted 90/10 canary** | XFF + canary demos |
| `hello.pldisturbme.site` | same weighted pair | domain #2, DNS pending |
| `httpbin.` | go-httpbin 2.23.1 | request playground |
| `grafana.` | kps-grafana (monitoring ns) | root_url set; public-gateway compromise named |
| `blog.` | WordPress (apps ns) | installed via wizard; live blog |
| `db-admin.` | Adminer (apps ns) | same MariaDB; public compromise named |
| `intranet.` | intranet echo (demo ns) | **internal gateway ONLY** — 404 from internet by design |

**Path:** GoDaddy DNS (`*` A-record → 157.151.193.45) → OCI LB (80
HTTP-L7 + 443 TCP-L4 passthrough) → NodePort 30080/30443 →
istio-ingressgateway (TLS terminates; lab CA wildcard) → HTTPRoutes.

**TLS:** root CA (10y) + wildcard (1y, expires 2027-07-12) in
`~/.k8s-lab-secrets/lab-ca/`; Secret `istio-ingressgateway-tls-wildcard`
in istio-system. Regen runbook: `k8s/istio/README.md`. Upgrade path:
cert-manager HTTP-01 (GoDaddy has no DNS API → no DNS-01 wildcard).

**Cluster:** 3 nodes Ready v1.33.13. Istio 1.30.2 (istiod + 2 gateways,
one LB only — trap defused). **monitoring/** = kps 87.12.3 + metrics-server
+ Kiali 2.28.0 + Loki (SingleBinary) + Fluent Bit (3-node DS) — all
targets UP; observability = metrics + mesh + logs, all in Grafana.
**apps/** = MariaDB StatefulSet (PVC 2Gi local-path, no sidecar) +
WordPress + Adminer. **demo/** = echo, echo-v2, httpbin, podinfo
(app-metrics demo, 3 metric sources), intranet (internal-gw only).
Alertmanager still null-receiver (Slack wiring designed, needs webhook).
Grafana admin password: `~/.k8s-lab-secrets/grafana-admin-password`.
Logs UI: Grafana → Explore → Loki datasource; LogQL e.g.
`{namespace="apps"} | json | line_format "{{.log}}"`.

---

## Istio telemetry + Kiali — ✅ DONE (2026-07-13)

- `k8s/observability/istio-telemetry.yaml` **applied**: ServiceMonitor
  (istiod :15014) + PodMonitor (envoy :15090). Verified: istiod job
  up=1, envoy job up=9/9 (7 sidecars + 2 gateways), `istio_requests_total`
  flowing, `pilot_xds_pushes` present.
- **Kiali 2.28.0** installed (`k8s/observability/kiali-values.yaml`):
  anonymous auth, reads our Prometheus + k8s API (Grafana = deep-link
  only), tracing off, ~64Mi. Pod 1/1. Graph API confirmed returning
  live topology (istio-ingressgateway → echo/echo-v2/httpbin).
- Access: `kubectl -n istio-system port-forward svc/kiali 20001:20001`
  → http://localhost:20001. Graph is REAL-TIME (rates decay to empty
  without traffic — widen Duration or generate load).

## Next options (user picks)

1. **Phase 8 — Argo CD adoption (the big GitOps milestone)** — install
   trimmed Argo, adopt the whole platform as Applications: istio × 3
   charts (sync-waves), kps (ServerSideApply + annotation tracking),
   metrics-server, Kiali, Loki, Fluent Bit, gateways, all routes +
   monitors. Every values file + pinned version is already in git →
   first syncs should be no-op diffs. ccm-csi stays Ansible-owned (D3).
2. **Block 11 — CI/CD** — deferred industry-standard design session
   (dynamic inventory `tf.py` or oracle.oci, Makefile, PR → plan →
   gated apply workflows).
3. **Istio telemetry dashboards / tracing** — import Istio Grafana
   dashboards; or add Tempo/Jaeger for the missing 4th pillar (tracing).
4. **P7-5b Slack** — 5 min if a webhook URL shows up (AM wiring designed).
5. **cert-manager HTTP-01** — real per-host certs (ingress path is live
   now, so it's unblocked).

**Recommendation when asked**: 1 → 2 → 3 (make the mesh observable,
complete observability, then GitOps-adopt the whole platform at once).

---

## Commits (all pushed to origin/main)

| Commit | Content |
|---|---|
| `faa547a` | Phase 5 pre-work: first push, provider fix, TF outputs |
| `d7c9dd2` | Ansible scaffolding (8 role stubs, inventory, site.yml) |
| `d5ec6ad` | Base roles (common, containerd, kubernetes-packages) |
| `f2e7d1b` | kubeadm-cp + cni-calico roles |
| `4fdd8f5` | oci-ccm + oci-csi roles |
| `af6a1dc` | kubeadm-worker role |
| `3c430d0` | Phase 7 pre-work: bind-address + 4 NSG rules |
| `123b8cc` | Docs + kps-values.yaml |
| `dd14a27` | kps install (cpu:null fix) |
| `7e9f9bb` | metrics-server |
| `890cc90` | Phase 7 docs complete |
| `a5ee2be` | **Phase 6: Istio + Gateway API + LB 443 + demos (16 files)** |

---

## Deferred items (tracked, not lost)

- **Phase 5b** — workers → instance pool + Object Storage join-vending.
- **Block 11** — CI/CD (dynamic inventory `tf.py` or oracle.oci plugin,
  Makefile, cloud-init wait, cp IP pin D9, PR workflows).
- **Istio telemetry + Kiali** — see Next options #1.
- **Slack → Alertmanager** — Secret + `api_url_file` pattern designed in
  chat 2026-07-11; needs webhook URL.
- **cert-manager HTTP-01** — real per-host certs; ingress path now live
  so it's unblocked whenever wanted.
- **Dedicated ServiceAccounts per workload** — makes SPIFFE identities
  distinct → enables AuthorizationPolicy ("only cart may call orders").
- **kubernetes.core.k8s** module swap; **kubeadm-config CM patch** as
  Ansible task (both small, noted in Phase 5a docs).
- **PROXY protocol / Network LB** for client IP on HTTPS (Phase 15).

---

## Access details

- kubectl from Mac: SSH tunnel `ssh -N -L 6443:127.0.0.1:6443 k8s-cp`
- SSH: `k8s-bastion`, `k8s-cp`, `k8s-worker-1`, `k8s-worker-2`
- Bastion 157.151.226.90 (reserved) · LB 157.151.193.45 (D8: move to
  bootstrap at rebuild)
- Grafana: https://grafana.satheshkumarnapoleon.site (admin / password
  file) — no port-forward needed anymore
- Trust the lab CA in the Mac keychain for green padlocks:
  `sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain ~/.k8s-lab-secrets/lab-ca/lab-root-ca.crt`

## Secrets (never in git)

- `~/.k8s-lab-secrets/state-backend.env` — source before ANY terraform
  against primary/
- `~/.k8s-lab-secrets/lab-ca/` — root CA + wildcard keypairs (600)
- `~/.k8s-lab-secrets/grafana-admin-password`
- In-cluster only: `blog-db-credentials` (apps ns) — created via CLI
- `~/.ssh/k8s_lab_ed25519`, `~/.oci/config` + key

---

## Quick sanity check on arrival

```bash
kubectl get nodes                                   # 3 Ready
for h in echo httpbin blog db-admin grafana; do
  printf "%-10s " "$h"; curl -s --cacert ~/.k8s-lab-secrets/lab-ca/lab-root-ca.crt \
    -o /dev/null -w "%{http_code}\n" "https://$h.satheshkumarnapoleon.site/" --max-time 8
done                                                # 200/200/302or200/200/302
cd ~/workspace/k8s-lab-infra/ansible && source ~/.k8s-lab-secrets/state-backend.env && \
  ansible-playbook site.yml --check --diff 2>&1 | tail -4   # changed=0 failed=0
```
