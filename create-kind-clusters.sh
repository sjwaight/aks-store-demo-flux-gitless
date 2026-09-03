#!/bin/bash
# Creates the kind clusters used by the KubeFleet gitless demo:
#   - kf-hub-01    (hub cluster)
#   - kf-member-01, kf-member-02, kf-member-03 (member clusters)
#
# Example usage: ./create-kind-clusters.sh

set -euo pipefail

HUB_CLUSTER="kf-hub-01"
MEMBER_CLUSTERS=("kf-member-01" "kf-member-02" "kf-member-03")
KUBEFLEET_VERSION="0.3.1"

usage() {
    cat <<'EOF'
Usage:
    ./create-kind-clusters.sh

Creates four kind clusters: kf-hub-01, kf-member-01, kf-member-02, kf-member-03,
then installs the KubeFleet hub-agent chart on the hub cluster.
Existing clusters with the same name are left untouched.

Requirements:
    - kind, kubectl and helm must be installed
    - Docker (or an equivalent container runtime) must be running
EOF
}

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
    usage
    exit 0
fi

if ! command -v kind >/dev/null 2>&1; then
    echo "Error: kind is not installed or not available in PATH" >&2
    exit 1
fi

if ! command -v kubectl >/dev/null 2>&1; then
    echo "Error: kubectl is not installed or not available in PATH" >&2
    exit 1
fi

if ! command -v helm >/dev/null 2>&1; then
    echo "Error: helm is not installed or not available in PATH" >&2
    exit 1
fi

if ! command -v docker >/dev/null 2>&1; then
    echo "Error: docker is not installed or not available in PATH" >&2
    exit 1
fi

existing_clusters="$(kind get clusters 2>/dev/null || true)"

create_cluster() {
    local name="$1"

    if echo "$existing_clusters" | grep -Fxq "$name"; then
        echo "Cluster '$name' already exists, skipping."
        return 0
    fi

    echo "Creating cluster '$name'..."
    kind create cluster --name "$name"
}

create_cluster "$HUB_CLUSTER"

for member in "${MEMBER_CLUSTERS[@]}"; do
    create_cluster "$member"
done

echo
echo "Installing KubeFleet hub-agent on '$HUB_CLUSTER'..."
helm --kube-context "kind-${HUB_CLUSTER}" upgrade --install hub-agent \
    oci://ghcr.io/kubefleet-dev/kubefleet/charts/hub-agent \
    --version "$KUBEFLEET_VERSION" \
    --namespace fleet-system \
    --create-namespace \
    --set logFileMaxSize=100000 \
    --set enableWorkload=truekub

echo
echo "All clusters ready:"
kind get clusters

# Member clusters reach the hub over the Docker network, not the mapped host port.
HUB_IP="$(docker inspect "${HUB_CLUSTER}-control-plane" --format='{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}')"

if [ -z "$HUB_IP" ]; then
    echo "Error: could not determine the IP address of '${HUB_CLUSTER}-control-plane'" >&2
    exit 1
fi

member_contexts=""
for member in "${MEMBER_CLUSTERS[@]}"; do
    member_contexts="${member_contexts} kind-${member}"
done

echo
echo "Kubeconfig contexts are named 'kind-<cluster-name>', for example: kind-${HUB_CLUSTER}"
echo
echo "Join the member clusters to the fleet with:"
echo "./join-member-clusters.sh ${KUBEFLEET_VERSION} kind-${HUB_CLUSTER} https://${HUB_IP}:6443/${member_contexts}"
