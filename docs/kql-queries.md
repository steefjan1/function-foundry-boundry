# KQL queries: watching three substrates share one action layer

Run these in the App Insights **Logs** blade, or from the CLI:

```powershell
az monitor app-insights query --app <ai-component-name> -g <rg> --analytics-query "<query>" -o table
```

Replace the two role names below with your app names (`az functionapp list -g <rg> -o table`).
Every query filters on `cloud_RoleName`, because both function apps report into one App
Insights component and an unfiltered query happily describes the wrong app (finding 27).

A naming accident does the substrate attribution for free: MCP-triggered functions log under
their bare tool names (`LookupOrder`, `CheckInventory`) and are only reachable by the prompt
agent, while HTTP-triggered ones carry the `http_` prefix and serve the durable and hosted
agents. One `extend` splits the traffic by door.

## 1. Which substrate came through which door

```kql
requests
| where timestamp > ago(2h)
| where cloud_RoleName == 'ffb-tools-<suffix>'
| where name !in ('http_health', 'http_notifications_for')   // probes and test hooks out
| extend door = iff(name startswith 'http_', 'HTTP: durable or hosted agent', 'MCP: prompt agent')
| summarize calls = count(), avgMs = round(avg(duration), 1) by door, name
| order by door, calls desc
```

## 2. One order, end to end, across both apps

The single most useful query after a run. Everything that mentions the order id, in time
order, whatever table it landed in.

```kql
union requests, traces, exceptions, dependencies
| where timestamp > ago(2h)
| where * has 'ORD-1002'
| project timestamp, itemType, cloud_RoleName,
          detail = coalesce(name, message, outerMessage)
| order by timestamp asc
```

## 3. The durable orchestration's own narrative

The replay-safe logger and the agent turns tell the story step by step, token counts
included. The `dafx-` lines are the model turns; each carries the full request and response.

```kql
traces
| where timestamp > ago(2h)
| where cloud_RoleName == 'ffb-durable-<suffix>'
| where message has_any ('Fulfilling', 'dafx-fulfilmentagent', 'Reserving', 'Notifying', 'Looking up')
| project timestamp, message
| order by timestamp asc
```

## 4. Model turn cost, extracted

Every agent response line ends with its token usage. Parse it out and you have a per-turn
cost series without any extra instrumentation.

```kql
traces
| where timestamp > ago(24h)
| where cloud_RoleName == 'ffb-durable-<suffix>'
| where message has 'Total tokens:'
| parse message with * 'Input tokens: ' inTok:int ', Output tokens: ' outTok:int ', Total tokens: ' totTok:int ')' *
| project timestamp, inTok, outTok, totTok
| summarize turns = count(), totalTokens = sum(totTok), avgIn = avg(inTok), avgOut = avg(outTok)
```

Worth remembering while reading it: finding 36's wrong triage verdict ran on 670 input
tokens where every correct one ran on ~997. An outlier in this query is not noise.

## 5. Exactly-once, proven from the caller's side

The smoke tests count notifications in the store. This counts the attempts that produced
them. Both numbers being 1 per order is the whole claim.

```kql
requests
| where timestamp > ago(2h)
| where cloud_RoleName == 'ffb-tools-<suffix>'
| where name == 'http_notify_customer'
| summarize attempts = count() by bin(timestamp, 5m)
| order by timestamp asc
```

## 6. What the durable app called, and how long each hop took

Dependencies from the durable app: the model endpoint and the action layer, with durations.
This is where a slow run explains itself.

```kql
dependencies
| where timestamp > ago(2h)
| where cloud_RoleName == 'ffb-durable-<suffix>'
| project timestamp, name, target, durationMs = duration, resultCode, operation_Id
| order by timestamp asc
```

## 7. Failures, correlated

Take an `operation_Id` from any query above and pull its whole story. This is the loud-side
counterpart of finding 22: a failed call that looks like a failed call can be walked from
request to exception in two clicks.

```kql
union requests, dependencies, exceptions, traces
| where operation_Id == '<paste one here>'
| project timestamp, itemType, detail = coalesce(name, message, outerMessage), resultCode
| order by timestamp asc
```

## 8. Cold starts, since Flex scales to zero

Host startup lines bracket every cold start. If a smoke run seems slow, this says whether
the platform was waking up rather than working.

```kql
traces
| where timestamp > ago(24h)
| where cloud_RoleName in ('ffb-tools-<suffix>', 'ffb-durable-<suffix>')
| where message has 'Initializing function HTTP routes' or message has 'Host started'
| project timestamp, cloud_RoleName, message
| order by timestamp asc
```

## What is NOT here

The hosted agent's own runtime telemetry. Its container runs inside Foundry, which does not
report into this App Insights component; from here you only see its tool calls arriving at
the action layer as `http_*` requests. Its inside view lives in the Foundry portal's agent
monitoring, or in whatever OpenTelemetry exporter you wire into the container. The
boundary in the diagrams is also a boundary in the observability, which is worth a sentence
in any architecture review: below the line you watch it in your App Insights, above the line
you watch it in whoever owns the substrate.
