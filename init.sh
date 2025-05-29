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
REPOSITORY_URL="https://github.com/loft-sh/kubernetes/releases/download"
BINARIES_DIR="/usr/local/bin"
CNI_BINARIES_DIR="/opt/cni/bin"

# Parse command line arguments
while [ $# -gt 0 ]; do
  case "$1" in
    --kubernetes-version)
      KUBERNETES_VERSION="$2"
      shift 2
      ;;
    --repository-url)
      REPOSITORY_URL="$2"
      shift 2
      ;;
    --binaries-dir)
      BINARIES_DIR="$2"
      shift 2
      ;;
    --cni-binaries-dir)
      CNI_BINARIES_DIR="$2"
      shift 2
      ;;
    *)
      echo "Unknown argument: $1"
      echo "Usage: $0 --kubernetes-version <version>"
      exit 1
      ;;
  esac
done

# Kubernetes version is required
if [ -z "$KUBERNETES_VERSION" ]; then
  echo "Error: --kubernetes-version is required"
  echo "Usage: $0 --kubernetes-version <version>"
  exit 1
fi

# Print the versions
echo "Preparing node for Kubernetes installation..."
echo "Kubernetes version: $KUBERNETES_VERSION"

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

# Install Kubernetes binaries
echo "Installing Kubernetes binaries..."
curl -s -L -o kubernetes.tar.gz ${REPOSITORY_URL}/${KUBERNETES_VERSION}/kubernetes-${KUBERNETES_VERSION}-${TARGETARCH}.tar.gz
mkdir kubernetes-binaries
tar -zxf kubernetes.tar.gz -C kubernetes-binaries
mkdir -p ${BINARIES_DIR} || true
mv kubernetes-binaries/release/kubeadm ${BINARIES_DIR}/kubeadm
mv kubernetes-binaries/release/kubelet ${BINARIES_DIR}/kubelet
mv kubernetes-binaries/release/kubectl ${BINARIES_DIR}/kubectl 
mv kubernetes-binaries/release/ctr ${BINARIES_DIR}/ctr
mv kubernetes-binaries/release/crictl ${BINARIES_DIR}/crictl
mv kubernetes-binaries/release/containerd ${BINARIES_DIR}/containerd
mv kubernetes-binaries/release/containerd-shim-runc-v2 ${BINARIES_DIR}/containerd-shim-runc-v2
mv kubernetes-binaries/release/runc ${BINARIES_DIR}/runc
mkdir -p ${CNI_BINARIES_DIR} || true
mv kubernetes-binaries/release/cni/bin/loopback ${CNI_BINARIES_DIR}/loopback
mv kubernetes-binaries/release/cni/bin/portmap ${CNI_BINARIES_DIR}/portmap
mv kubernetes-binaries/release/cni/bin/bandwidth ${CNI_BINARIES_DIR}/bandwidth
mv kubernetes-binaries/release/cni/bin/bridge ${CNI_BINARIES_DIR}/bridge
mv kubernetes-binaries/release/cni/bin/firewall ${CNI_BINARIES_DIR}/firewall
mv kubernetes-binaries/release/cni/bin/host-local ${CNI_BINARIES_DIR}/host-local
rm kubernetes.tar.gz
rm -rf kubernetes-binaries

# Configure crictl
if [ ! -f /etc/crictl.yaml ]; then
cat <<EOF > /etc/crictl.yaml
runtime-endpoint: unix:///run/containerd/containerd.sock
EOF
fi

# Make sure bridge and br_netfilter are active
if [ ! -e /proc/sys/net/bridge/bridge-nf-call-iptables ]; then
  echo "Loading bridge and br_netfilter modules..."
  modprobe -va bridge br_netfilter
fi

# Make sure ip forward is set correctly
if [ "$(sysctl -n net.ipv4.ip_forward)" -ne 1 ]; then
  echo "Activating ip_forward..."
  sysctl -w net.ipv4.ip_forward=1
  sysctl -w net.ipv6.conf.all.forwarding=1
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
mkdir -p /etc/kubernetes/manifests
if [ ! -f /etc/containerd/config.toml ]; then
  # Create default config if not there
  containerd config default > /etc/containerd/config.toml

  # Make sure to use systemd cgroups
  sed -i.bak -E 's#^[[:space:]]*(SystemdCgroup)[[:space:]]*=[[:space:]]*false#\1 = true#' /etc/containerd/config.toml
fi

# Create containerd.service
mkdir -p /etc/systemd/system
cat <<EOF > /etc/systemd/system/containerd.service
[Unit]
Description=containerd container runtime
Documentation=https://containerd.io
After=network.target

[Service]
ExecStart=${BINARIES_DIR}/containerd
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
ExecStart=${BINARIES_DIR}/kubelet
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
ExecStart=${BINARIES_DIR}/kubelet \$KUBELET_KUBECONFIG_ARGS \$KUBELET_CONFIG_ARGS \$KUBELET_KUBEADM_ARGS \$KUBELET_EXTRA_ARGS
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
