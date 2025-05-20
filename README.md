# init-node
Easy script to init a node before joining via Kubeadm: 
```
# Install containerd, kubelet, kubeadm, kubectl and cni tools
curl -sfL https://raw.githubusercontent.com/loft-sh/init-node/main/init.sh | sh -s -- --kubernetes-version v1.32.1
```
