#!/usr/bin/env bash
# Option 1. Create the Foundry prompt agent and point it at the Functions MCP endpoint.
#
# Agents are a data plane concern. There is no Microsoft.CognitiveServices/.../agents ARM
# type, so this cannot live in infra/main.bicep. That split is itself worth noticing: the
# substrate is deployed by IaC, the agent on it is not.
set -euo pipefail

: "${AZURE_RESOURCE_GROUP:?set AZURE_RESOURCE_GROUP}"
: "${FOUNDRY_PROJECT_ENDPOINT:?set FOUNDRY_PROJECT_ENDPOINT}"
: "${TOOLS_APP_NAME:?set TOOLS_APP_NAME}"
: "${MODEL_DEPLOYMENT_NAME:=gpt-5.4-mini}"

API_VERSION="${API_VERSION:-v1}"
AGENT_NAME="${AGENT_NAME:-FulfilmentPromptAgent}"
CONNECTION_NAME="orders-action-layer"

echo "==> Reading the mcp_extension system key from ${TOOLS_APP_NAME}"
MCP_KEY="$(az functionapp keys list \
  --resource-group "${AZURE_RESOURCE_GROUP}" \
  --name "${TOOLS_APP_NAME}" \
  --query systemKeys.mcp_extension -o tsv)"

if [[ -z "${MCP_KEY}" || "${MCP_KEY}" == "null" ]]; then
  echo "No mcp_extension system key found. Deploy Orders.Tools first, then re-run." >&2
  exit 1
fi

MCP_ENDPOINT="https://${TOOLS_APP_NAME}.azurewebsites.net/runtime/webhooks/mcp"
echo "==> MCP endpoint: ${MCP_ENDPOINT}"

# The connection carries the key, so it never appears in the agent definition.
# Docs are explicit that Key Vault references are not auto-injected here, so this is
# the seam to harden first in a regulated environment.
echo "==> Creating the remote tool connection"
azd ai connection create "${CONNECTION_NAME}" \
  --kind remote-tool \
  --target "${MCP_ENDPOINT}" \
  --auth-type custom-keys \
  --custom-key "x-functions-key=${MCP_KEY}" \
  || echo "Connection already exists, continuing."

echo "==> Creating agent version for ${AGENT_NAME}"
BODY_FILE="$(mktemp)"
trap 'rm -f "${BODY_FILE}"' EXIT

sed \
  -e "s|MODEL_DEPLOYMENT_NAME|${MODEL_DEPLOYMENT_NAME}|" \
  -e "s|MCP_ENDPOINT|${MCP_ENDPOINT}|" \
  "$(dirname "$0")/../prompt-agent/agent.json" > "${BODY_FILE}"

az rest --method POST \
  --url "${FOUNDRY_PROJECT_ENDPOINT}/agents/${AGENT_NAME}/versions?api-version=${API_VERSION}" \
  --resource "https://ai.azure.com" \
  --headers "Content-Type=application/json" \
  --body "@${BODY_FILE}"

echo "==> Done. Run test/smoke-option1.sh to exercise it."
