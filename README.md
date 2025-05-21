# init-node
Easy script to init a node before joining via Kubeadm: 
```
# Install containerd, kubelet, kubeadm, kubectl and cni tools
curl -sfL https://raw.githubusercontent.com/loft-sh/init-node/main/init.sh | sh -s -- --kubernetes-version v1.32.1

# Then continue with joining the node to a cluster as explained here https://github.com/loft-sh/loft-enterprise/pull/4327#discussion_r2100075895
sudo kubeadm join --token <token> <control-plane-host>:<control-plane-port> --discovery-token-ca-cert-hash sha256:<hash>
```
