#!/bin/sh
set -e
set -o noglob

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
REPOSITORY_URL=""
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

# If rhel / centos, try to install extra kernel modules
OS=$(awk -F= '/^ID=/{gsub(/"/,"",$2); print tolower($2)}' /etc/os-release 2>/dev/null || echo unknown)
echo "Detected OS: ${OS}"
if [ "$OS" = "rhel" ] || [ "$OS" = "centos" ]; then
  # check if SELinux is enforcing
  if [ "$(getenforce 2>/dev/null)" = "Enforcing" ]; then
    echo "Seems like SELinux is enforcing currently. Please disable SELinux via 'setenforce 0' and rerun this script"
    exit 1
  fi

  # install extra kernel modules
  echo "Detected RHEL/CentOS - try installing extra kernel modules..."
  dnf install -y "kernel-modules-extra-$(uname -r)" || true
fi

# Make sure binaries dir is part of PATH
export PATH=${BINARIES_DIR}:${PATH}

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

# create temporary directory and cleanup when done
setup_tmp() {
    TMP_DIR=$(mktemp -d -t vcluster-install.XXXXXXXXXX)
    cleanup() {
        code=$?
        set +e
        trap - EXIT
        rm -rf ${TMP_DIR} || true
        exit $code
    }
    trap cleanup INT EXIT
}

# figure out the target architecture
TARGETARCH="amd64"
if is_arm; then
  TARGETARCH="arm64"
fi

# Install Kubernetes binaries
echo "Installing Kubernetes binaries..."
setup_tmp

# Download the binaries or extract the bundle
echo "Downloading Kubernetes binaries from https://github.com/loft-sh/kubernetes/releases/download..."
curl -fsSLk -o ${TMP_DIR}/kubernetes-${KUBERNETES_VERSION}-${TARGETARCH}.tar.gz https://github.com/loft-sh/kubernetes/releases/download/${KUBERNETES_VERSION}/kubernetes-${KUBERNETES_VERSION}-${TARGETARCH}.tar.gz
tar -zxf ${TMP_DIR}/kubernetes-${KUBERNETES_VERSION}-${TARGETARCH}.tar.gz -C ${TMP_DIR}

# Move the binaries to the correct location
mkdir -p ${BINARIES_DIR} || true
mv ${TMP_DIR}/release/kubeadm ${BINARIES_DIR}/kubeadm
mv ${TMP_DIR}/release/kubelet ${BINARIES_DIR}/kubelet
mv ${TMP_DIR}/release/kubectl ${BINARIES_DIR}/kubectl
mv ${TMP_DIR}/release/ctr ${BINARIES_DIR}/ctr
mv ${TMP_DIR}/release/crictl ${BINARIES_DIR}/crictl
mv ${TMP_DIR}/release/containerd ${BINARIES_DIR}/containerd
mv ${TMP_DIR}/release/containerd-shim-runc-v2 ${BINARIES_DIR}/containerd-shim-runc-v2
mv ${TMP_DIR}/release/runc ${BINARIES_DIR}/runc
mkdir -p ${CNI_BINARIES_DIR} || true
mv ${TMP_DIR}/release/cni/bin/loopback ${CNI_BINARIES_DIR}/loopback
mv ${TMP_DIR}/release/cni/bin/portmap ${CNI_BINARIES_DIR}/portmap
mv ${TMP_DIR}/release/cni/bin/bandwidth ${CNI_BINARIES_DIR}/bandwidth
mv ${TMP_DIR}/release/cni/bin/bridge ${CNI_BINARIES_DIR}/bridge
mv ${TMP_DIR}/release/cni/bin/firewall ${CNI_BINARIES_DIR}/firewall
mv ${TMP_DIR}/release/cni/bin/host-local ${CNI_BINARIES_DIR}/host-local

# Configure crictl
if [ ! -f /etc/crictl.yaml ]; then
cat <<EOF > /etc/crictl.yaml
runtime-endpoint: unix:///run/containerd/containerd.sock
EOF
fi

# Configure bridge and br_netfilter modules
if [ ! -e /proc/sys/net/bridge/bridge-nf-call-iptables ]; then
  echo "Loading bridge and br_netfilter modules..."
  modprobe -va bridge br_netfilter || true
fi

# Load nf_conntrack module as it's required for kube-proxy
if [ ! -f /proc/sys/net/netfilter/nf_conntrack_max ]; then
  echo "Loading nf_conntrack module..."
  modprobe -va nf_conntrack || true
fi

# Make sure ip forward is set correctly
if [ "$(sysctl -n net.ipv4.ip_forward)" -ne 1 ]; then
  echo "Activating ip_forward..."
  sysctl -w net.ipv4.ip_forward=1 || true
  sysctl -w net.ipv6.conf.all.forwarding=1 || true
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
  # is v2?
  if [ "$(containerd --version | cut -d' ' -f3 | tr -d 'v' | cut -d. -f1)" -ge 2 ]; then
  # Containerd v2
cat <<EOF > /etc/containerd/config.toml
version = 3
root = '/var/lib/containerd'
state = '/run/containerd'

[grpc]
  address = '/run/containerd/containerd.sock'

[plugins.'io.containerd.internal.v1.opt']
  path = '/opt/containerd'

[plugins.'io.containerd.grpc.v1.cri']
  stream_server_address = "127.0.0.1"
  stream_server_port = "10010"

[plugins.'io.containerd.cri.v1.runtime']
  enable_selinux = false
  enable_unprivileged_ports = true
  enable_unprivileged_icmp = true
  device_ownership_from_security_context = false

[plugins.'io.containerd.cri.v1.images']
  snapshotter = "overlayfs"
  disable_snapshot_annotations = true

[plugins.'io.containerd.cri.v1.images'.pinned_images]
  sandbox = "registry.k8s.io/pause:3.10"

[plugins.'io.containerd.cri.v1.runtime'.cni]
  bin_dirs = ['/opt/cni/bin']
  conf_dir = '/etc/cni/net.d'

[plugins.'io.containerd.cri.v1.runtime'.containerd]
  default_runtime_name = "runc"

[plugins.'io.containerd.cri.v1.runtime'.containerd.runtimes.runc]
  runtime_type = "io.containerd.runc.v2"

[plugins.'io.containerd.cri.v1.runtime'.containerd.runtimes.runc.options]
  SystemdCgroup = true

[plugins.'io.containerd.cri.v1.images'.registry]
  config_path = ""
EOF
  else
  # Containerd v1
cat <<EOF > /etc/containerd/config.toml
version = 2
root = "/var/lib/containerd"
state = "/run/containerd"

[grpc]
  address = "/run/containerd/containerd.sock"

[plugins."io.containerd.internal.v1.opt"]
  path = "/opt/containerd"

[plugins."io.containerd.grpc.v1.cri"]
  cdi_spec_dirs = ["/etc/cdi", "/var/run/cdi"]
  stream_server_address = "127.0.0.1"
  stream_server_port = "10010"
  enable_selinux = false
  enable_unprivileged_ports = false
  enable_unprivileged_icmp = false
  device_ownership_from_security_context = false
  sandbox_image = "registry.k8s.io/pause:3.10"

[plugins."io.containerd.grpc.v1.cri".containerd]
  snapshotter = "overlayfs"
  disable_snapshot_annotations = true

[plugins."io.containerd.grpc.v1.cri".cni]
  bin_dir = "/opt/cni/bin"
  conf_dir = "/etc/cni/net.d"

[plugins."io.containerd.grpc.v1.cri".containerd.runtimes.runc]
  runtime_type = "io.containerd.runc.v2"

[plugins."io.containerd.grpc.v1.cri".containerd.runtimes.runc.options]
  SystemdCgroup = true

[plugins."io.containerd.grpc.v1.cri".registry]
  config_path = ""
EOF
  fi
fi

# Create containerd.service
mkdir -p /etc/systemd/system
cat <<EOF > /etc/systemd/system/containerd.service
[Unit]
Description=containerd container runtime
Documentation=https://containerd.io
After=network.target dbus.service

[Service]
ExecStartPre=-/sbin/modprobe overlay
ExecStart=${BINARIES_DIR}/containerd
Type=notify
Delegate=yes
KillMode=process
Restart=always
RestartSec=5
# Having non-zero Limit*s causes performance problems due to accounting overhead
# in the kernel. We recommend using cgroups to do container-local accounting.
LimitNPROC=infinity
LimitCORE=infinity
LimitNOFILE=infinity
# Comment TasksMax if your systemd version does not supports it.
# Only systemd 226 and above support this version.
TasksMax=infinity
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
{{- if .FlannelEnabled }}
ExecStartPre=-/sbin/modprobe bridge
ExecStartPre=-/sbin/modprobe br_netfilter
{{- end }}
ExecStartPre=-/sbin/modprobe nf_conntrack
ExecStartPre=-sysctl -w net.ipv4.ip_forward=1
ExecStartPre=-sysctl -w net.ipv6.conf.all.forwarding=1
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

# Start containerd and kubelet
systemctl daemon-reload

echo "Starting containerd..."
systemctl enable --now containerd.service
echo "Starting kubelet..."
systemctl enable --now kubelet.service

echo "Installation successful!"
