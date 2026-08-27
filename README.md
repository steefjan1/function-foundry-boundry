# functions-foundry-boundary

One action layer. Three orchestration substrates. The same order fulfilment task run through
each of them, so you can see what actually changes when you move the boundary.

Companion repo for the post *Azure Functions or Foundry Agent Service is the wrong question*.

> **Status: working.** `test/validate.ps1` passes offline, `azd up` deploys, and
> `test/smoke.ps1` passes 10 of 10 against the deployed system, including the full durable
> orchestration ending in exactly one customer notification.
> That covers the action layer and option 2. Options 1 and 3 compile and have creation
> scripts, but neither has been stood up against a live Foundry project.
> [`docs/verification.md`](docs/verification.md) records all 23 fixes it took to get there,
> what is confirmed against the docs, and what remains unmeasured.

## The claim under test

The pattern everyone is drawing says Azure Functions is the action layer and Foundry Agent
Service is the orchestration layer, because putting orchestration in Functions means
hand building a state machine in a runtime that was not designed for one.

Half of that is still true. The other half stopped being true when the Durable Task extension
for Microsoft Agent Framework shipped. So the repo builds one action layer and three
orchestrators over it, and lets you compare them on the things that actually differ.

| | Option 1: prompt agent | Option 2: durable agent on Functions | Option 3: hosted agent |
| --- | --- | --- | --- |
| Where orchestration runs | Foundry | Your Functions app | Foundry |
| Who writes the orchestration | Nobody, it is configuration | You, in C# | You, in C# |
| Session state | Foundry, or your Cosmos DB | Durable Task history | Foundry |
| Retry and failure handling | Foundry | You | Split |
| Deployed by | `az rest`, data plane | `azd up` | `az acr build` plus `az rest` |
| Tools the model may call | 5 | 3 | 5 |
| Status | GA | Preview packages | GA, some features preview |

That last row of the table is the one people skip. Option 2's packages have never had a stable
release. Say that out loud in an architecture review before you pick it.

## Why option 2 gives the model fewer tools

`reserve_stock` and `notify_customer` change state a customer can see. With a durable
orchestrator those two run as activities, where the runtime commits them exactly once even if
the surrounding agent turns replay. Without one, the model itself has to be trusted to call
them once.

That is the substantive difference between the substrates, and it is visible in about twelve
lines of `src/Orders.DurableAgent/Program.cs`. Everything else is packaging.

## Layout

```
src/Orders.Tools.Core/      the action layer logic, plus a typed client for it
src/Orders.Tools/           Functions app: MCP triggers and HTTP triggers over the same class
src/Orders.DurableAgent/    option 2, orchestration in Functions
src/Orders.HostedAgent/     option 3, the same agent code in a container for Foundry
agents/prompt-agent/        option 1, an agent definition and the script that creates it
infra/main.bicep            Foundry account and project, Flex Consumption plan, two apps, RBAC
test/                       offline validation and deployed smoke tests
docs/verification.md        what is confirmed, what is not, and what is deliberately limited
```

The action layer is five operations: `lookup_order`, `check_inventory`, `reserve_stock`,
`arrange_delivery`, `notify_customer`. `reserve_stock` is idempotent on a reservation key, and
the smoke tests prove it, because a retry that holds stock twice is the failure mode all three
substrates can produce and only one of them prevents for you.

Reservations, deliveries and notifications live in Azure Table Storage, using the same storage
account and managed identity as the Functions host. That is not incidental. Flex Consumption
scales the action layer across instances, so in-process state is wrong, and Table Storage's
409 on a duplicate row key makes insert-if-absent atomic across all of them. The idempotency
key is only a real guarantee because of it.

## Prerequisites

- .NET SDK 8.0 or later. The projects target `net8.0`. If you have the .NET 9 SDK and want to
  move up, see the comment at the top of `Directory.Build.props`: three files change, not one.
- Azure Developer CLI, Azure CLI, and Bicep on PATH.
- A subscription with quota for the model deployment in `infra/main.bicep`.

### About the model

The template deploys `gpt-5.4-mini` on Global Standard, and deliberately does **not** pin a
model version. Azure resolves the default version for the model in your region, which avoids
the most common provisioning failure: a version the region does not carry.

`gpt-4o-mini`, which this sample originally used, is closed to new deployments and its Global
Standard retirement is 1 October 2026. If you want something else, check what your region
actually offers before you set it:

```bash
az cognitiveservices model list \
  --location <your-region> \
  --query "[?kind=='OpenAI'].{name:model.name, version:model.version, skus:model.skus[].name}" \
  -o table
```

Then override without editing the template:

```bash
azd env set MODEL_NAME gpt-5.4-nano
azd env set MODEL_DEPLOYMENT_NAME gpt-5.4-nano
azd env set MODEL_CAPACITY 20      # lower this if the region reports no available capacity
```

One caveat about that listing command. Retired and closed models still appear in it:
`gpt-4o-mini` is listed in Sweden Central today despite being closed to new deployments. The
list tells you what the region knows about, not what it will let you deploy. Check the
[model retirements page](https://learn.microsoft.com/en-us/azure/foundry/openai/concepts/model-retirements)
alongside it.

The code never references a model name, only `MODEL_DEPLOYMENT_NAME`. That is the practice the
retirement notices ask for, and it is why swapping models here is an environment change rather
than a code change.

## Running it

Run the offline validation first, always. It also cleans up two things that break restore:
a stale `Directory.Packages.props` from an older checkout, and cached `obj/` folders that
still hold the previous restore graph.

```bash
# 1. Offline first. Nothing here needs a subscription.
pwsh ./test/validate.ps1

# 1b. If the durable agent fails to resolve DurableAIAgent, GetAgent or
#     ConfigureDurableAgents, dump the real API surface of the restored packages:
pwsh ./test/discover-api.ps1

# 2. Provision and deploy the action layer and the durable agent.
azd auth login
azd up

# 3. Option 1: create the prompt agent against the MCP endpoint.
export AZURE_RESOURCE_GROUP=<rg>
export FOUNDRY_PROJECT_ENDPOINT=$(azd env get-value FOUNDRY_PROJECT_ENDPOINT)
export TOOLS_APP_NAME=$(azd env get-value TOOLS_APP_NAME)
./agents/scripts/create-prompt-agent.sh

# 4. Option 3: build and register the hosted agent.
export ACR_NAME=<registry>
./agents/scripts/deploy-hosted-agent.sh

# 5. Smoke tests.
export TOOLS_APP_URL=$(azd env get-value TOOLS_APP_URL)
export TOOLS_KEY=$(az functionapp keys list -g "$AZURE_RESOURCE_GROUP" -n "$TOOLS_APP_NAME" --query functionKeys.default -o tsv)
./test/smoke.sh
```

### Options 1 and 3, on Windows

```powershell
# Option 1: the Foundry prompt agent over MCP
pwsh ./test/create-prompt-agent.ps1 -ResourceGroup <rg>

# drive it in the Foundry playground, then check what it actually did
pwsh ./test/verify-notifications.ps1 -ToolsAppUrl $env:TOOLS_APP_URL -ToolsKey $env:TOOLS_KEY -OrderId ORD-1002

# Option 3: the hosted agent. Creates a container registry if you do not have one.
pwsh ./test/deploy-hosted-agent.ps1 -ResourceGroup <rg>
```

### Every new terminal starts here

The test scripts read `TOOLS_APP_URL` and friends from the environment, and environment
variables do not survive a new window. Dot source this, leading dot and space:

```powershell
. ./test/env.ps1 -ResourceGroup <rg>
```

Without the dot it sets the variables in a child scope that vanishes on exit.

### On Windows

```powershell
# Wire the durable agent to the action layer and print every key you need.
pwsh ./test/configure.ps1 -ResourceGroup <rg>

# Then run the same tests, PowerShell flavoured. Pass -ResourceGroup and it preflights the
# wiring before it spends three minutes on an orchestration that cannot succeed.
pwsh ./test/smoke.ps1 -ToolsAppUrl <url> -ToolsKey <key> `
  -DurableAppUrl <url> -DurableKey <key> -ResourceGroup <rg>
```

> **Every `azd provision` is followed by `configure.ps1`.** Provision rewrites the function
> app's settings wholesale from the Bicep, and `TOOL_LAYER_KEY` is deliberately not in the
> Bicep, so provisioning erases it and the durable agent's first tool call returns 401. This
> has now happened twice. `azd deploy` on its own is safe; it leaves app settings alone.

If a deployed function returns 404 for a route you know exists:

```powershell
pwsh ./test/diagnose.ps1 -ResourceGroup <rg>

# or capture everything, full stack traces included, as JSON
pwsh ./test/diagnose.ps1 -ResourceGroup <rg> -OutFile diagnose.json

# add -AllTraces to include informational traces, not just warnings and exceptions
```

An empty function list means the host failed to start. A list containing functions you did
not write means two apps are sharing a deployment container.

For an orchestration that starts but never finishes:

```powershell
pwsh ./test/inspect-orchestration.ps1 -ResourceGroup <rg>
```

It prints the recent instances and the full history of the latest one. The last
`TaskScheduled` with no matching `TaskCompleted` is the step it is waiting on. Add
`-Terminate` to kill a wedged instance.

If an orchestration fails the durable determinism check, bisect the cause:

```powershell
pwsh ./test/bisect.ps1 -DurableAppUrl $env:DURABLE_APP_URL -DurableKey $env:DURABLE_KEY
```

Two diagnostic endpoints on the durable app split "the orchestration is stuck" into its two
possible causes, with no durable machinery in the path:

```powershell
# Does the action layer answer from inside the durable app?
Invoke-RestMethod "$env:DURABLE_APP_URL/api/test/tools?code=$env:DURABLE_KEY"

# Does the model answer at all, and how long does it take?
Invoke-RestMethod "$env:DURABLE_APP_URL/api/test/agent?code=$env:DURABLE_KEY"
```

If `test/agent` returns text, the model path works and the problem is durable. If it times
out or throws, the orchestration was never going to finish.

`configure.ps1` exists because the durable agent needs a function key to call the action
layer, and the template does not supply one. Bicep could fetch it with `listKeys()`, but that
writes the key into the ARM deployment history in clear text where it stays. A script keeps it
out of both.

`infra/main.bicep` does not create the container registry that step 4 needs. Point `ACR_NAME`
at one you already have, or add it.

### Starting over after a failed deploy

```bash
pwsh ./test/reset.ps1 -ResourceGroup <rg> -Location swedencentral
```

A resource group delete on its own is not enough. Cognitive Services accounts are soft
deleted and keep their name reserved until purged, which is what that script does.

## What this repo does not prove

The interesting claim about option 2 is that an orchestration survives a host restart mid
flight and does not re-run the reservation. This repo asserts that and does not measure it.
Measuring it needs a harness that kills the host between two specific checkpoints and then
counts side effects, which is a different build. Until that exists, treat resumability here
as a documented product behaviour rather than an observed one.
