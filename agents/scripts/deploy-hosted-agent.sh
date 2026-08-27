#!/usr/bin/env bash
# Option 3. Build the hosted agent container, push it, and register it as a Foundry hosted agent.
set -euo pipefail

: "${AZURE_RESOURCE_GROUP:?set AZURE_RESOURCE_GROUP}"
: "${FOUNDRY_PROJECT_ENDPOINT:?set FOUNDRY_PROJECT_ENDPOINT}"
: "${ACR_NAME:?set ACR_NAME}"
: "${TOOLS_APP_NAME:?set TOOLS_APP_NAME}"
: "${MODEL_DEPLOYMENT_NAME:=gpt-5.4-mini}"

API_VERSION="${API_VERSION:-v1}"
AGENT_NAME="${AGENT_NAME:-FulfilmentHostedAgent}"
IMAGE_TAG="${IMAGE_TAG:-v1}"
IMAGE="${ACR_NAME}.azurecr.io/orders-hosted-agent:${IMAGE_TAG}"

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

echo "==> Building ${IMAGE}"
az acr build \
  --registry "${ACR_NAME}" \
  --image "orders-hosted-agent:${IMAGE_TAG}" \
  --file "${ROOT}/src/Orders.HostedAgent/Dockerfile" \
  "${ROOT}"

echo "==> Registering hosted agent version"
BODY_FILE="$(mktemp)"
trap 'rm -f "${BODY_FILE}"' EXIT

cat > "${BODY_FILE}" <<JSON
{
  "definition": {
    "kind": "hosted",
    "image": "${IMAGE}",
    "cpu": "1",
    "memory": "2Gi",
    "container_protocol_versions": [
      { "protocol": "responses", "version": "1.0.0" }
    ],
    "environment_variables": {
      "TOOL_LAYER_URL": "https://${TOOLS_APP_NAME}.azurewebsites.net",
      "MODEL_DEPLOYMENT_NAME": "${MODEL_DEPLOYMENT_NAME}"
    }
  }
}
JSON

az rest --method POST \
  --url "${FOUNDRY_PROJECT_ENDPOINT}/agents/${AGENT_NAME}/versions?api-version=${API_VERSION}" \
  --resource "https://ai.azure.com" \
  --headers "Content-Type=application/json" "Foundry-Features=HostedAgents=V1Preview" \
  --body "@${BODY_FILE}"

echo "==> Done. azd ai agent show ${AGENT_NAME} for status, azd ai agent monitor for logs."
