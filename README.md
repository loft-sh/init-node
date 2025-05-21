# init-node
Easy script to init a node before joining via Kubeadm: 
```
# Install required tools (containerd, kubelet etc.) and prepare host
curl -sfL https://raw.githubusercontent.com/loft-sh/init-node/main/init.sh | sh -s -- --kubernetes-version v1.32.1

# Then continue with joining the node to a cluster as explained here https://kubernetes.io/docs/tasks/administer-cluster/kubeadm/adding-linux-nodes/#adding-linux-worker-nodes
kubeadm join --token <token> <control-plane-host>:<control-plane-port> --discovery-token-ca-cert-hash sha256:<hash>
```
