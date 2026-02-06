#!/usr/bin/env bash

set -o errexit
set -o nounset
set -o pipefail

# Configuration
PRINCIPAL_CLUSTER_NAME="${PRINCIPAL_CLUSTER_NAME:-argocd-hub}"
AGENT_CLUSTER_COUNT="${1:-1}"
NAMESPACE_NAME="${NAMESPACE_NAME:-argocd}"
AGENT_MODE="${AGENT_MODE:-managed}"
RELEASE_BRANCH="${RELEASE_BRANCH:-release-0.6}"
KIND_IMAGE="${KIND_IMAGE:-kindest/node:v1.31.0}"

# Network configuration
CLUSTER_USER_ID=1
PRINCIPAL_POD_CIDR="10.$((244 + CLUSTER_USER_ID)).0.0/16"
PRINCIPAL_SVC_CIDR="10.$((96 + CLUSTER_USER_ID)).0.0/12"

declare -a AGENT_CLUSTERS=()
for (( i=1; i<=AGENT_CLUSTER_COUNT; i++ )); do
  AGENT_CLUSTERS+=("argocd-agent$i")
done

echo "=== Configuration ==="
echo "Principal Cluster: $PRINCIPAL_CLUSTER_NAME"
echo "Agent Clusters: ${AGENT_CLUSTERS[*]}"
echo "Namespace: $NAMESPACE_NAME"
echo "Agent Mode: $AGENT_MODE"
echo "Release Branch: $RELEASE_BRANCH"
echo ""

# Create Principal Cluster
echo "=== Creating Principal Cluster ==="
cat <<EOF | kind create cluster --name $PRINCIPAL_CLUSTER_NAME --image=$KIND_IMAGE --config=-
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
name: $PRINCIPAL_CLUSTER_NAME
networking:
  podSubnet: "$PRINCIPAL_POD_CIDR"
  serviceSubnet: "$PRINCIPAL_SVC_CIDR"
nodes:
  - role: control-plane
EOF

kubectl create namespace $NAMESPACE_NAME --context kind-$PRINCIPAL_CLUSTER_NAME

# Install Argo CD for Principal
echo "=== Installing Argo CD on Principal ==="
kubectl apply --server-side=true -n $NAMESPACE_NAME \
  -k "https://github.com/argoproj-labs/argocd-agent/install/kubernetes/argo-cd/principal?ref=$RELEASE_BRANCH" \
  --context kind-$PRINCIPAL_CLUSTER_NAME

# Configure Apps-in-Any-Namespace
kubectl patch configmap argocd-cmd-params-cm \
  -n $NAMESPACE_NAME \
  --context kind-$PRINCIPAL_CLUSTER_NAME \
  --patch '{"data":{"application.namespaces":"*"}}'

kubectl rollout restart deployment argocd-server -n $NAMESPACE_NAME --context kind-$PRINCIPAL_CLUSTER_NAME

# Initialize PKI
echo "=== Initializing PKI ==="
argocd-agentctl pki init \
  --principal-context kind-$PRINCIPAL_CLUSTER_NAME \
  --principal-namespace $NAMESPACE_NAME

# Install Principal
echo "=== Installing Principal ==="
kubectl apply -n $NAMESPACE_NAME \
  -k "https://github.com/argoproj-labs/argocd-agent/install/kubernetes/principal?ref=$RELEASE_BRANCH" \
  --context kind-$PRINCIPAL_CLUSTER_NAME

# Configure Principal allowed namespaces
ALLOWED_NAMESPACES=$(IFS=,; echo "${AGENT_CLUSTERS[*]}")
kubectl patch configmap argocd-agent-params \
  -n $NAMESPACE_NAME \
  --context kind-$PRINCIPAL_CLUSTER_NAME \
  --patch "{\"data\":{\"principal.allowed-namespaces\":\"$ALLOWED_NAMESPACES\"}}"

kubectl rollout restart deployment argocd-agent-principal \
  -n $NAMESPACE_NAME \
  --context kind-$PRINCIPAL_CLUSTER_NAME

# Expose Principal service
kubectl patch svc argocd-agent-principal \
  -n $NAMESPACE_NAME \
  --context kind-$PRINCIPAL_CLUSTER_NAME \
  --patch '{"spec":{"type":"NodePort"}}'

# Generate Principal certificates
echo "=== Generating Principal Certificates ==="
PRINCIPAL_EXTERNAL_IP=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' $PRINCIPAL_CLUSTER_NAME-control-plane)
PRINCIPAL_NODE_PORT=$(kubectl get svc argocd-agent-principal -n $NAMESPACE_NAME --context kind-$PRINCIPAL_CLUSTER_NAME -o jsonpath='{.spec.ports[0].nodePort}')
PRINCIPAL_DNS_NAME=$(kubectl get svc argocd-agent-principal -n $NAMESPACE_NAME --context kind-$PRINCIPAL_CLUSTER_NAME -o jsonpath='{.metadata.name}.{.metadata.namespace}.svc.cluster.local')

argocd-agentctl pki issue principal \
  --principal-context kind-$PRINCIPAL_CLUSTER_NAME \
  --principal-namespace $NAMESPACE_NAME \
  --ip 127.0.0.1,$PRINCIPAL_EXTERNAL_IP \
  --dns localhost,$PRINCIPAL_DNS_NAME \
  --upsert

RESOURCE_PROXY_INTERNAL_IP=$(kubectl get svc argocd-agent-resource-proxy -n $NAMESPACE_NAME --context kind-$PRINCIPAL_CLUSTER_NAME -o jsonpath='{.spec.clusterIP}')
RESOURCE_PROXY_DNS_NAME=$(kubectl get svc argocd-agent-resource-proxy -n $NAMESPACE_NAME --context kind-$PRINCIPAL_CLUSTER_NAME -o jsonpath='{.metadata.name}.{.metadata.namespace}.svc.cluster.local')

argocd-agentctl pki issue resource-proxy \
  --principal-context kind-$PRINCIPAL_CLUSTER_NAME \
  --principal-namespace $NAMESPACE_NAME \
  --ip 127.0.0.1,$RESOURCE_PROXY_INTERNAL_IP \
  --dns localhost,$RESOURCE_PROXY_DNS_NAME \
  --upsert

# Generate JWT signing key
argocd-agentctl jwt create-key \
  --principal-context kind-$PRINCIPAL_CLUSTER_NAME \
  --principal-namespace $NAMESPACE_NAME \
  --upsert

# Create Agent Clusters
for (( i=0; i<AGENT_CLUSTER_COUNT; i++ )); do
  AGENT_CLUSTER_NAME="${AGENT_CLUSTERS[$i]}"
  AGENT_USER_ID=$((i + 2))
  AGENT_POD_CIDR="10.$((244 + AGENT_USER_ID)).0.0/16"
  AGENT_SVC_CIDR="10.$((96 + AGENT_USER_ID)).0.0/12"

  echo "=== Creating Agent Cluster: $AGENT_CLUSTER_NAME ==="
  cat <<EOF | kind create cluster --name $AGENT_CLUSTER_NAME --image=$KIND_IMAGE --config=-
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
name: $AGENT_CLUSTER_NAME
networking:
  podSubnet: "$AGENT_POD_CIDR"
  serviceSubnet: "$AGENT_SVC_CIDR"
nodes:
  - role: control-plane
EOF

  kubectl create namespace $NAMESPACE_NAME --context kind-$AGENT_CLUSTER_NAME

  # Install Argo CD for Agent
  echo "=== Installing Argo CD on Agent: $AGENT_CLUSTER_NAME ==="
  kubectl apply --server-side=true -n $NAMESPACE_NAME \
    -k "https://github.com/argoproj-labs/argocd-agent/install/kubernetes/argo-cd/agent-$AGENT_MODE?ref=$RELEASE_BRANCH" \
    --context kind-$AGENT_CLUSTER_NAME

  # Create Agent configuration on Principal
  echo "=== Creating Agent Configuration: $AGENT_CLUSTER_NAME ==="
  argocd-agentctl agent create $AGENT_CLUSTER_NAME \
    --principal-context kind-$PRINCIPAL_CLUSTER_NAME \
    --principal-namespace $NAMESPACE_NAME \
    --resource-proxy-server ${PRINCIPAL_EXTERNAL_IP}:9090 \
    --resource-proxy-username $AGENT_CLUSTER_NAME \
    --resource-proxy-password "$(openssl rand -base64 32)"

  # Issue Agent client certificate
  argocd-agentctl pki issue agent $AGENT_CLUSTER_NAME \
    --principal-context kind-$PRINCIPAL_CLUSTER_NAME \
    --agent-context kind-$AGENT_CLUSTER_NAME \
    --agent-namespace $NAMESPACE_NAME \
    --upsert

  # Propagate CA to Agent
  argocd-agentctl pki propagate \
    --principal-context kind-$PRINCIPAL_CLUSTER_NAME \
    --principal-namespace $NAMESPACE_NAME \
    --agent-context kind-$AGENT_CLUSTER_NAME \
    --agent-namespace $NAMESPACE_NAME

  # Create Agent namespace on Principal
  kubectl create namespace $AGENT_CLUSTER_NAME --context kind-$PRINCIPAL_CLUSTER_NAME

  # Deploy Agent
  echo "=== Deploying Agent: $AGENT_CLUSTER_NAME ==="
  kubectl apply -n $NAMESPACE_NAME \
    -k "https://github.com/argoproj-labs/argocd-agent/install/kubernetes/agent?ref=$RELEASE_BRANCH" \
    --context kind-$AGENT_CLUSTER_NAME

  # Configure Agent connection
  kubectl patch configmap argocd-agent-params \
    -n $NAMESPACE_NAME \
    --context kind-$AGENT_CLUSTER_NAME \
    --patch "{\"data\":{
      \"agent.server.address\":\"$PRINCIPAL_EXTERNAL_IP\",
      \"agent.server.port\":\"$PRINCIPAL_NODE_PORT\",
      \"agent.mode\":\"$AGENT_MODE\",
      \"agent.creds\":\"mtls:any\"
    }}"

  kubectl rollout restart deployment argocd-agent-agent \
    -n $NAMESPACE_NAME \
    --context kind-$AGENT_CLUSTER_NAME

  # Patch default AppProject
  kubectl patch appproject default -n $NAMESPACE_NAME \
    --context kind-$PRINCIPAL_CLUSTER_NAME --type='merge' \
    --patch='{"spec":{"sourceNamespaces":["*"],"destinations":[{"name":"*","namespace":"*","server":"*"}]}}'

  # Fix ClusterRole for agent
  kubectl patch clusterrole argocd-agent-agent \
    --context kind-$AGENT_CLUSTER_NAME \
    --type='json' \
    -p='[{"op":"add","path":"/rules/-","value":{"apiGroups":["argoproj.io"],"resources":["applications","appprojects"],"verbs":["get","list","watch","create","update","patch","delete"]}}]'

  # Add server.secretkey
  kubectl patch secret argocd-secret -n $NAMESPACE_NAME \
    --context kind-$AGENT_CLUSTER_NAME \
    --patch='{"data":{"server.secretkey":"'$(openssl rand -base64 32 | base64 -w 0)'"}}'
done

echo ""
echo "=== Setup Complete ==="
echo "Principal Cluster: kind-$PRINCIPAL_CLUSTER_NAME"
echo "Agent Clusters: ${AGENT_CLUSTERS[*]}"
echo ""
echo "To access ArgoCD UI:"
echo "  kubectl port-forward svc/argocd-server -n $NAMESPACE_NAME 8080:443 --context kind-$PRINCIPAL_CLUSTER_NAME"
echo ""
echo "Get admin password:"
echo "  kubectl -n $NAMESPACE_NAME get secret argocd-initial-admin-secret --context kind-$PRINCIPAL_CLUSTER_NAME -o jsonpath='{.data.password}' | base64 -d"
echo ""
echo "List connected agents:"
echo "  argocd-agentctl agent list --principal-context kind-$PRINCIPAL_CLUSTER_NAME --principal-namespace $NAMESPACE_NAME"
