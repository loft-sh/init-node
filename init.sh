#!/bin/sh
set -e

# Check if curl is installed
if ! command -v curl >/dev/null 2>&1; then
  echo "Error: curl is not installed. Please install curl and try again."
  exit 1
fi

# Check if systemctl is installed
if ! command -v systemctl >/dev/null 2>&1; then
  echo "Error: systemctl is not installed. This installer only works on systems that use systemd."
  exit 1
fi

# Default versions
KUBERNETES_VERSION=""
CNI_BINARIES_VERSION="v1.6.0"
CONTAINERD_VERSION="2.1.0"
RUNC_VERSION="v1.3.0"

# Parse command line arguments
while [ $# -gt 0 ]; do
  case "$1" in
    --kubernetes-version)
      KUBERNETES_VERSION="$2"
      shift 2
      ;;
    --cni-binaries-version)
      CNI_BINARIES_VERSION="$2"
      shift 2
      ;;
    --containerd-version)
      CONTAINERD_VERSION="$2"
      shift 2
      ;;
    --runc-version)
      RUNC_VERSION="$2"
      shift 2
      ;;
    *)
      echo "Unknown argument: $1"
      echo "Usage: $0 --kubernetes-version <version> [--cni-binaries-version <version>] [--containerd-version <version>] [--runc-version <version>]"
      exit 1
      ;;
  esac
done

# Kubernetes version is required
if [ -z "$KUBERNETES_VERSION" ]; then
  echo "Error: --kubernetes-version is required"
  echo "Usage: $0 --kubernetes-version <version> [--cni-binaries-version <version>] [--containerd-version <version>] [--runc-version <version>]"
  exit 1
fi

# Print the versions
echo "Preparing node for Kubernetes installation..."
echo "Kubernetes version: $KUBERNETES_VERSION"
echo "CNI binaries version: $CNI_BINARIES_VERSION"
echo "Containerd version: $CONTAINERD_VERSION"
echo "Runc version: $RUNC_VERSION"

# ensure we're running as root
if [ "$(id -u)" -ne 0 ]; then
  echo "Error: this installer needs the ability to run commands as root."
  exit 1
fi

# check if the architecture is arm
is_arm() {
  case "$(uname -a)" in
  *arm* ) true;;
  *arm64* ) true;;
  *aarch* ) true;;
  *aarch64* ) true;;
  * ) false;;
  esac
}

# figure out the target architecture
TARGETARCH="amd64"
if is_arm; then
  TARGETARCH="arm64"
fi

# make sure we don't operate on /
mkdir -p init-node
cd init-node

# Install kubeadm, kubelet, and kubectl
echo "Installing kubeadm..."
curl -s -L -o kubeadm https://dl.k8s.io/release/${KUBERNETES_VERSION}/bin/linux/${TARGETARCH}/kubeadm
chmod +x kubeadm
mv kubeadm /usr/local/bin/kubeadm
echo "Installing kubelet..."
curl -s -L -o kubelet https://dl.k8s.io/release/${KUBERNETES_VERSION}/bin/linux/${TARGETARCH}/kubelet
chmod +x kubelet
mv kubelet /usr/local/bin/kubelet
echo "Installing kubectl..."
curl -s -L -o kubectl https://dl.k8s.io/release/${KUBERNETES_VERSION}/bin/linux/${TARGETARCH}/kubectl
chmod +x kubectl
mv kubectl /usr/local/bin/kubectl

# Install CNI plugins
echo "Installing CNI plugins..."
curl -s -L -o cni.tgz https://github.com/containernetworking/plugins/releases/download/${CNI_BINARIES_VERSION}/cni-plugins-linux-${TARGETARCH}-${CNI_BINARIES_VERSION}.tgz
mkdir cni
tar -zxf cni.tgz -C cni
mkdir -p /opt/cni/bin
mv cni/loopback /opt/cni/bin
mv cni/portmap /opt/cni/bin
mv cni/bandwidth /opt/cni/bin
mv cni/bridge /opt/cni/bin
mv cni/firewall /opt/cni/bin
mv cni/host-local /opt/cni/bin
rm cni.tgz
rm -rf cni

# Install containerd & runc
echo "Installing containerd..."
curl -s -L -o containerd.tgz https://github.com/containerd/containerd/releases/download/v${CONTAINERD_VERSION}/containerd-${CONTAINERD_VERSION}-linux-${TARGETARCH}.tar.gz
tar -zxf containerd.tgz bin
chmod +x bin/containerd-shim-runc-v2
mv bin/containerd-shim-runc-v2 /usr/local/bin
chmod +x bin/containerd
mv bin/containerd /usr/local/bin
chmod +x bin/ctr
mv bin/ctr /usr/local/bin
rm containerd.tgz
rm -rf bin
echo "Installing runc..."
curl -s -L -o runc https://github.com/opencontainers/runc/releases/download/${RUNC_VERSION}/runc.${TARGETARCH}
chmod +x runc
mv runc /usr/local/bin

# Make sure bridge and br_netfilter are active
if [ ! -e /proc/sys/net/bridge/bridge-nf-call-iptables ]; then
  echo "Loading bridge and br_netfilter modules..."
  modprobe -va bridge br_netfilter
fi

# Make sure ip forward is set correctly
if [ "$(sysctl -n net.ipv4.ip_forward)" -ne 1 ]; then
  echo "Activating ip_forward..."
  sysctl -w net.ipv4.ip_forward=1
fi

# Check if conntrack is installed
if ! command -v conntrack >/dev/null 2>&1; then
  echo "Installing conntrack..."
  if command -v apt-get >/dev/null 2>&1; then
    apt-get update && apt-get install -y conntrack
  elif command -v yum >/dev/null 2>&1; then
    yum install -y conntrack-tools
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y conntrack-tools
  elif command -v pacman >/dev/null 2>&1; then
    pacman -Sy --noconfirm conntrack-tools
  elif command -v zypper >/dev/null 2>&1; then
    zypper install -y conntrack-tools
  elif command -v apk >/dev/null 2>&1; then
    apk add conntrack-tools
  else
    echo "No supported package manager found. Please install conntrack manually."
    exit 1
  fi
fi

# Configure containerd
mkdir -p /etc/containerd
containerd config default > /etc/containerd/config.toml

# Create containerd.service
mkdir -p /etc/systemd/system
cat <<EOF > /etc/systemd/system/containerd.service
[Unit]
Description=containerd container runtime
Documentation=https://containerd.io
After=network.target

[Service]
ExecStart=/usr/local/bin/containerd
Type=notify
PIDFile=/run/containerd/containerd.pid
Restart=always
RestartSec=5
Delegate=yes
KillMode=process
RuntimeDirectory=containerd
RuntimeDirectoryMode=0755
OOMScoreAdjust=-999

[Install]
WantedBy=multi-user.target
EOF

# Create kubelet.service
cat <<EOF > /etc/systemd/system/kubelet.service
# slightly modified from:
# https://github.com/kubernetes/kubernetes/blob/ba8fcafaf8c502a454acd86b728c857932555315/build/debs/kubelet.service
[Unit]
Description=kubelet: The Kubernetes Node Agent
Documentation=http://kubernetes.io/docs/
# NOTE: kind deviates from upstream here to avoid crashlooping
# This does *not* support altering the kubelet config path though.
# We intend to upstream this change but first need to solve the upstream
# Packaging problem (all kubernetes versions use the same files out of tree).
ConditionPathExists=/var/lib/kubelet/config.yaml

[Service]
ExecStart=/usr/local/bin/kubelet
Restart=always
StartLimitInterval=0
# NOTE: kind deviates from upstream here with a lower RestartSec
RestartSec=1s
# And by adding the [Service] lines below
CPUAccounting=true
MemoryAccounting=true
Slice=kubelet.slice
KillMode=process
OOMScoreAdjust=-999

[Install]
WantedBy=multi-user.target
EOF

# Create kubelet.slice
cat <<EOF > /etc/systemd/system/kubelet.slice
[Unit]
Description=slice used to run Kubernetes / Kubelet
Before=slices.target

[Slice]
MemoryAccounting=true
CPUAccounting=true
EOF

# Create kubelet.service.d/10-kubeadm.conf
mkdir -p /etc/systemd/system/kubelet.service.d
cat <<EOF > /etc/systemd/system/kubelet.service.d/10-kubeadm.conf
# https://github.com/kubernetes/kubernetes/blob/ba8fcafaf8c502a454acd86b728c857932555315/build/debs/10-kubeadm.conf
# Note: This dropin only works with kubeadm and kubelet v1.11+
[Service]
Environment="KUBELET_KUBECONFIG_ARGS=--bootstrap-kubeconfig=/etc/kubernetes/bootstrap-kubelet.conf --kubeconfig=/etc/kubernetes/kubelet.conf"
Environment="KUBELET_CONFIG_ARGS=--config=/var/lib/kubelet/config.yaml"
# This is a file that "kubeadm init" and "kubeadm join" generates at runtime, populating the KUBELET_KUBEADM_ARGS variable dynamically
EnvironmentFile=-/var/lib/kubelet/kubeadm-flags.env
ExecStart=
ExecStart=/usr/local/bin/kubelet \$KUBELET_KUBECONFIG_ARGS \$KUBELET_CONFIG_ARGS \$KUBELET_KUBEADM_ARGS \$KUBELET_EXTRA_ARGS
EOF

# Enable containerd and kubelet
echo "Enabling containerd and kubelet..."
systemctl enable containerd.service
systemctl enable kubelet.service

# Start containerd and kubelet
echo "Starting containerd and kubelet..."
systemctl start containerd.service
systemctl start kubelet.service

echo "Installation successful!"
