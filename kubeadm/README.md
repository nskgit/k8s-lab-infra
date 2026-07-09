# kubeadm

Phase 2. `ClusterConfiguration.yaml` — declarative kubeadm init config: podSubnet
10.244.0.0/16, serviceSubnet 10.96.0.0/16, API server SANs (incl. 127.0.0.1 for the
SSH-tunnel access path), kubelet `cloud-provider: external`.
