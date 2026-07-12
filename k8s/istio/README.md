# Istio + Gateway API (Phase 6)

## TLS — lab CA + wildcard cert (P6-3)

Live cert chain generated 2026-07-12. All private material lives in
`~/.k8s-lab-secrets/lab-ca/` (never in git):

| File | What | Lifetime |
|---|---|---|
| `lab-root-ca.key` | Root CA private key — the trust anchor. Mode 600. | 10 years |
| `lab-root-ca.crt` | Root CA public cert — give to clients (`curl --cacert`) | 10 years |
| `lab-wildcard.key` | Server private key. Mode 600. | 1 year |
| `lab-wildcard.crt` | Server cert for `*.satheshkumarnapoleon.site` + apex, signed by the root | 1 year (expires 2027-07-12) |
| `pldisturbme-wildcard.key` | Domain #2 server key. Mode 600. | 1 year |
| `pldisturbme-wildcard.crt` | `*.pldisturbme.site` + apex, signed by the SAME root | 1 year (expires 2027-07-12) |

In-cluster Secrets (type `kubernetes.io/tls`, istio-system), one per
domain, each referenced by its own HTTPS listener on the shared :443 —
**SNI selects the listener + cert from the hostname in the TLS
handshake**:
- `istio-ingressgateway-tls-wildcard` → listener `https-sathesh`
- `istio-ingressgateway-tls-pldisturbme` → listener `https-pldisturbme`
  (added 2026-07-12; **DNS still pending** at the registrar — until the
  `*` A-record → LB IP lands, test with
  `curl --resolve hello.pldisturbme.site:443:157.151.193.45 --cacert lab-root-ca.crt https://hello.pldisturbme.site/`)

DNS: GoDaddy hosts the zone. A `*` A-record points every subdomain at
the LB public IP (157.151.193.45). The apex `@` record still serves
GoDaddy WebsiteBuilder — we only own subdomains.

### Regenerate (e.g. after the server cert expires)

```bash
cd ~/.k8s-lab-secrets/lab-ca

# server key + CSR
openssl genrsa -out lab-wildcard.key 2048
openssl req -new -key lab-wildcard.key \
  -subj "/CN=*.satheshkumarnapoleon.site/O=Sathesh Lab" -out lab-wildcard.csr

# SAN file (clients only look at SAN, never CN)
cat > /tmp/san.ext <<'EOF'
subjectAltName = DNS:*.satheshkumarnapoleon.site, DNS:satheshkumarnapoleon.site
extendedKeyUsage = serverAuth
EOF

# sign with the existing root CA (10y; regen with `openssl req -x509` if expired)
openssl x509 -req -in lab-wildcard.csr \
  -CA lab-root-ca.crt -CAkey lab-root-ca.key -CAcreateserial \
  -sha256 -days 365 -extfile /tmp/san.ext -out lab-wildcard.crt
rm lab-wildcard.csr /tmp/san.ext && chmod 600 lab-wildcard.key

# refresh the in-cluster Secret; Envoy hot-reloads, no restart
kubectl -n istio-system create secret tls istio-ingressgateway-tls-wildcard \
  --cert=lab-wildcard.crt --key=lab-wildcard.key \
  --dry-run=client -o yaml | kubectl apply -f -
```

### Client trust

```bash
curl --cacert ~/.k8s-lab-secrets/lab-ca/lab-root-ca.crt https://echo.satheshkumarnapoleon.site/
```

### Upgrade path to real certs (planned, after P6-7)

cert-manager + Let's Encrypt **HTTP-01** (GoDaddy DNS has no usable API
for DNS-01; HTTP-01 needs the ingress path live first — that's why
cert-manager comes after the mesh works). cert-manager will overwrite
the same Secret name; Gateway config unchanged. If a true wildcard cert
is ever needed: move DNS to Cloudflare (free; registrar stays GoDaddy)
and switch the Issuer to DNS-01.
