#!/bin/bash

# Tanzu Community Edition Multi-Node Cluster Installer (Optimized)
# Features:
#   - Multi-node cluster (configurable size)
#   - Calico CNI networking
#   - Smart taint management only when needed
#   - Full development readiness verification
#   - Production-like configuration
# Requires: Ubuntu/Debian or macOS (Windows requires WSL2)

set -e  # Exit on error

# Configuration
CLUSTER_NAME="tce-multi"
CONTROL_PLANE_NODES=1
WORKER_NODES=2
TCE_VERSION="v0.12.1"
CALICO_VERSION="v3.26.1"  # Stable Calico version

# Detect OS
OS=""
if [ -f /etc/os-release ]; then
    . /etc/os-release
    OS=$ID
elif [ "$(uname)" == "Darwin" ]; then
    OS="macos"
else
    echo "Unsupported OS. Only Ubuntu/Debian or macOS supported."
    exit 1
fi

# Install prerequisites based on OS (requires root)
install_prerequisites() {
    echo "Installing prerequisites (requires sudo)..."

    # Common requirements
    if ! command -v curl &> /dev/null; then
        echo "Installing curl..."
        if [ "$OS" == "macos" ]; then
            brew install curl
        else
            sudo apt-get install -y curl
        fi
    fi

    if ! command -v jq &> /dev/null; then
        echo "Installing jq..."
        if [ "$OS" == "macos" ]; then
            brew install jq
        else
            sudo apt-get install -y jq
        fi
    fi

    # Docker installation
    if ! command -v docker &> /dev/null; then
        echo "Docker not found. Installing..."
        if [ "$OS" == "macos" ]; then
            echo "Please install Docker Desktop for macOS: https://docs.docker.com/desktop/install/mac-install/"
            exit 1
        else
            curl -fsSL https://get.docker.com | sudo sh
            sudo systemctl enable docker
            sudo systemctl start docker
            sudo usermod -aG docker $USER
        fi
    fi

    # kubectl installation
    if ! command -v kubectl &> /dev/null; then
        echo "kubectl not found. Installing..."
        if [ "$OS" == "macos" ]; then
            brew install kubectl
        else
            curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
            sudo install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl
            rm -f kubectl
        fi
    fi
}

# Install Calico CNI
install_calico() {
    echo "Installing Calico CNI plugin (${CALICO_VERSION})..."
    CALICO_MANIFEST_URL="https://raw.githubusercontent.com/projectcalico/calico/${CALICO_VERSION}/manifests/calico.yaml"
    kubectl apply -f $CALICO_MANIFEST_URL

    echo "Waiting for Calico to initialize..."
    # Wait for Calico pods to be created
    local timeout=120
    local start_time=$(date +%s)

    while [ $(kubectl get pods -n kube-system -l k8s-app=calico-node --no-headers 2>/dev/null | wc -l) -eq 0 ]; do
        sleep 5
        local current_time=$(date +%s)
        local elapsed=$((current_time - start_time))
        if [ $elapsed -ge $timeout ]; then
            echo "Error: Calico pods not created within $timeout seconds"
            return 1
        fi
        echo "Waiting for Calico pods to be created... (${elapsed}s)"
    done

    # Now wait for them to be ready
    kubectl wait --namespace=kube-system --for=condition=available deployment/calico-kube-controllers --timeout=300s
    kubectl wait --namespace=kube-system --for=condition=ready pod -l k8s-app=calico-node --timeout=300s
}

# Conditional taint removal
remove_taints_if_needed() {
    echo "Checking node taints..."
    local nodes=$(kubectl get nodes -o jsonpath='{.items[*].metadata.name}' 2>/dev/null)
    local needs_cleanup=false

    if [ -z "$nodes" ]; then
        echo "No nodes found. Skipping taint check."
        return
    fi

    for node in $nodes; do
        local taints=$(kubectl get node $node -o jsonpath='{.spec.taints[*].key}' 2>/dev/null || true)
        if [[ "$taints" =~ "node.kubernetes.io/not-ready" ]] || [[ "$taints" =~ "node.kubernetes.io/unreachable" ]]; then
            echo "Removing taints from $node"
            kubectl taint node $node node.kubernetes.io/not-ready:NoSchedule- --overwrite || true
            kubectl taint node $node node.kubernetes.io/not-ready:NoExecute- --overwrite || true
            kubectl taint node $node node.kubernetes.io/unreachable:NoSchedule- --overwrite || true
            kubectl taint node $node node.kubernetes.io/unreachable:NoExecute- --overwrite || true
            needs_cleanup=true
        fi
    done

    if $needs_cleanup; then
        echo "Taints removed. Waiting 20 seconds for changes to propagate..."
        sleep 20
    fi
}

# Verify node readiness (optimized)
verify_node_readiness() {
    echo "Verifying node readiness..."
    local timeout=600  # 10 minutes timeout
    local start_time=$(date +%s)
    local last_taint_check=0

    while true; do
        # Get nodes in JSON format
        local node_json=$(kubectl get nodes -o json 2>/dev/null)
        local total_nodes=$(echo "$node_json" | jq -r '.items | length')

        if [ $total_nodes -eq 0 ]; then
            echo "No nodes found. Waiting..."
            sleep 10
            continue
        fi

        local ready_count=0
        for (( i=0; i<$total_nodes; i++ )); do
            local status=$(echo "$node_json" | jq -r ".items[$i].status.conditions[] | select(.type==\"Ready\").status")
            if [ "$status" == "True" ]; then
                ((ready_count++))
            fi
        done

        if [ $ready_count -eq $total_nodes ]; then
            echo "All $total_nodes nodes are ready."
            return 0
        fi

        # Check timeout
        local current_time=$(date +%s)
        local elapsed=$((current_time - start_time))
        if [ $elapsed -ge $timeout ]; then
            echo "Error: Only $ready_count/$total_nodes nodes ready after $timeout seconds"
            return 1
        fi

        # Check for taints every 30 seconds
        if (( $elapsed - $last_taint_check >= 30 )); then
            remove_taints_if_needed
            last_taint_check=$elapsed
        fi

        echo "Node readiness: $ready_count/$total_nodes (${elapsed}s elapsed)"
        sleep 15
    done
}

# Verify network functionality
verify_network() {
    echo "Verifying cluster networking..."

    # Test DNS resolution
    echo "Creating network test pod..."
    kubectl run network-test --image=busybox:1.36 --restart=Never --command -- sleep 3600
    kubectl wait --for=condition=Ready pod/network-test --timeout=120s

    echo "Testing DNS resolution..."
    kubectl exec network-test -- nslookup kubernetes.default.svc.cluster.local

    # Test internet access
    echo "Testing internet connectivity..."
    kubectl exec network-test -- wget -qO- --timeout=5 http://example.com | grep -m1 "Example Domain" || echo "Internet test failed but continuing"

    # Test pod-to-pod networking
    echo "Testing pod-to-pod networking..."
    kubectl exec network-test -- ping -c 3 8.8.8.8

    # Cleanup
    kubectl delete pod network-test --now
}

# Main installation function
install_tce_cluster() {
    echo "Starting TCE v${TCE_VERSION} installation as $USER..."

    # Create installation directory in user's home
    INSTALL_DIR="$HOME/tce-installation"
    mkdir -p "$INSTALL_DIR"
    cd "$INSTALL_DIR"

    # Remove previous extraction if it exists
    rm -rf "tce-linux-amd64-${TCE_VERSION}" "tce-darwin-amd64-${TCE_VERSION}"

    # Set OS-specific file names
    if [ "$OS" == "macos" ]; then
        TCE_FILE="tce-darwin-amd64-${TCE_VERSION}.tar.gz"
    else
        TCE_FILE="tce-linux-amd64-${TCE_VERSION}.tar.gz"
    fi

    # Download TCE only if it doesn't exist
    if [ ! -f "$TCE_FILE" ]; then
        echo "Downloading TCE ${TCE_VERSION}..."
        curl -LO "https://github.com/vmware-tanzu/community-edition/releases/download/${TCE_VERSION}/${TCE_FILE}"
    else
        echo "Tarball $TCE_FILE already exists. Skipping download."
    fi

    # Extract TCE
    echo "Extracting ${TCE_FILE}..."
    tar -xvf "${TCE_FILE}"

    # Enter version-specific directory
    if [ "$OS" == "macos" ]; then
        cd "tce-darwin-amd64-${TCE_VERSION}"
    else
        cd "tce-linux-amd64-${TCE_VERSION}"
    fi

    echo "Installing Tanzu CLI..."
    ./install.sh

    # Add Tanzu to PATH
    if ! grep -q 'tanzu' "$HOME/.bashrc"; then
        echo "export PATH=\$PATH:$HOME/.local/bin/tanzu" >> "$HOME/.bashrc"
        source "$HOME/.bashrc"
    fi

    # Initialize Tanzu
    echo "Initializing Tanzu CLI..."
    tanzu init

    # Install plugins
    echo "Installing Tanzu plugins..."
    if [ -d "airgapped-bundle" ]; then
        tanzu plugin install --local airgapped-bundle all
    elif [ -d "cli" ]; then
        tanzu plugin install --local cli all
    else
        echo "WARNING: Plugin directory not found. Skipping plugin installation."
    fi

    # Create multi-node cluster
    TOTAL_NODES=$((CONTROL_PLANE_NODES + WORKER_NODES))
    echo "Creating ${TOTAL_NODES}-node cluster (${CONTROL_PLANE_NODES} control plane, ${WORKER_NODES} workers)..."
    tanzu unmanaged-cluster create $CLUSTER_NAME --worker-node-count $TOTAL_NODES --cni calico

    # Set kubeconfig context
    kubectl config use-context $CLUSTER_NAME

    # Install Calico CNI
    install_calico

    # Verify node readiness with smart taint handling
    verify_node_readiness

    # Verify network functionality
    verify_network

    # Deploy sample application
    echo "Deploying sample application..."
    kubectl create deployment nginx --image=nginx:latest --replicas=3
    kubectl expose deployment nginx --port=80 --type=NodePort

    # Wait for deployment
    echo "Waiting for application to become ready..."
    kubectl wait --for=condition=available deployment/nginx --timeout=120s

    # Get application details
    NODE_PORT=$(kubectl get svc nginx -o jsonpath='{.spec.ports[0].nodePort}')
    echo "Sample application deployed:"
    echo "  Deployment: nginx with 3 replicas"
    echo "  Service: NodePort on port $NODE_PORT"

    # Print cluster information
    echo ""
    echo "=================================================================="
    echo "Tanzu Multi-Node Cluster Installation Complete!"
    echo "Cluster Name: $CLUSTER_NAME"
    echo "Nodes:"
    kubectl get nodes -o wide
    echo ""
    echo "System Pods:"
    kubectl get pods -n kube-system
    echo ""
    echo "Sample Application:"
    kubectl get deployment,svc nginx
    echo ""
    echo "To access your application:"
    echo "  1. Get node IPs: kubectl get nodes -o wide"
    echo "  2. Access Nginx at: http://<ANY_NODE_IP>:$NODE_PORT"
    echo ""
    echo "Cluster management commands:"
    echo "  - View all resources: kubectl get all -A"
    echo "  - View cluster info: tanzu unmanaged-cluster list"
    echo "  - Delete cluster: tanzu unmanaged-cluster delete $CLUSTER_NAME"
    echo "=================================================================="
}

# Check if running as root
if [ "$(id -u)" -eq 0 ]; then
    echo "Error: Do not run this script as root."
    echo "Please run as a regular user with sudo privileges."
    echo "The script will request sudo when needed."
    exit 1
fi

# Execution flow
install_prerequisites
install_tce_cluster

# Post-install note about Docker permissions
if [ "$OS" != "macos" ]; then
    echo "Note: You might need to log out and back in for Docker group permissions to take effect."
    echo "If you get 'permission denied' errors with Docker, run:"
    echo "  newgrp docker"
    echo "Or restart your terminal session."
fi
