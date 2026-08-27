#!/usr/bin/env sh
# See postprovision.ps1 for why this exists: azd provision wipes TOOL_LAYER_KEY.
RG="${AZURE_RESOURCE_GROUP:-$(azd env get-value AZURE_RESOURCE_GROUP 2>/dev/null)}"

if [ -z "$RG" ]; then
  echo "AZURE_RESOURCE_GROUP not set. Run test/configure.ps1 -ResourceGroup <rg> by hand."
  exit 0
fi

if command -v pwsh >/dev/null 2>&1; then
  pwsh "$(dirname "$0")/configure.ps1" -ResourceGroup "$RG"
else
  echo "pwsh not found. Run test/configure.ps1 -ResourceGroup $RG by hand."
fi
