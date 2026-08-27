# What was verified, and what was not

This repo was written on 27 August 2026 in an environment with no .NET SDK and no access to
nuget.org, so its first draft had never been compiled.

**Current status, 27 August 2026.** `pwsh test/validate.ps1` passes on .NET SDK 8.0.423:
`az bicep build` succeeds, restore succeeds, and all four projects compile with zero errors
and one benign warning. Getting there took nine fixes across four rounds, listed below,
because the first draft was written without an SDK. Deployment then found nine more.

**Deployment status: deployed, verification in progress.** `azd up` provisions and deploys,
and the durable orchestration completes end to end. The earlier "10 of 10" is withdrawn: fixes
29 and 30 showed that the notification assertion was a false pass over an action layer that
was silently running its in-memory store. Re-run `test/smoke.ps1` after those fixes for a
result that means something. It now checks the store is persistent before asserting anything
that depends on persistence.

**What that covers.** The action layer and option 2, the durable agent, are deployed and
measured. Options 1 and 3 are written, compiled and scripted, but neither has been stood up:
no prompt agent and no hosted agent has been created against a live Foundry project. Treat
`agents/scripts/create-prompt-agent.sh` and `deploy-hosted-agent.sh` as unverified, in the
same sense every version number in this file was unverified before the first build.

**Still unmeasured:** resumability. That an orchestration survives a host restart mid flight
and does not re-run the reservation is a documented product behaviour here, not an observed
one. Measuring it needs a harness that kills the host between two specific checkpoints and
counts side effects.

## Confirmed against Microsoft Learn and nuget.org

| Claim | Source |
| --- | --- |
| `Microsoft.Azure.Functions.Worker.Extensions.Mcp` 1.6.0, published 2026-07-31 | nuget.org version table |
| `McpToolTriggerAttribute(toolName, description)` binding `ToolInvocationContext` | [MCP tool trigger reference](https://learn.microsoft.com/en-us/azure/azure-functions/functions-bindings-mcp-tool-trigger) |
| `McpToolProperty(propertyName, description, isRequired:)` | same |
| MCP endpoints `/runtime/webhooks/mcp` and `/runtime/webhooks/mcp/sse` | [MCP bindings overview](https://learn.microsoft.com/en-us/azure/azure-functions/functions-bindings-mcp) |
| System key is named `mcp_extension`, passed as `x-functions-key` | same |
| `ConfigureDurableAgents(options => options.AddAIAgent(agent))` registration shape | [Agent Framework on Azure Functions](https://learn.microsoft.com/en-us/agent-framework/hosting/azure-functions) |
| `DurableAIAgent`, `AgentSession`, `AgentResponse<T>`, `context.GetAgent(name)` | [Create a durable agent](https://learn.microsoft.com/en-us/agent-framework/user-guide/agents/agent-types/durable-agent/create-durable-agent) |
| There is no dedicated agent trigger; orchestrations use `[OrchestrationTrigger] TaskOrchestrationContext` | same |
| `Microsoft.Agents.AI` 1.19.0 is stable; `Microsoft.Agents.AI.Hosting.AzureFunctions` and `Microsoft.Agents.AI.DurableTask` are preview only, latest 1.16.0-preview.260730.1 | nuget.org |
| `AIProjectClient(...).AsAIAgent(model:, instructions:, name:, tools:)` | [Local MCP tools](https://learn.microsoft.com/en-us/agent-framework/agents/tools/local-mcp-tools) |
| Agents are data plane. No `Microsoft.CognitiveServices/accounts/projects/agents` ARM type exists | [ARM template reference](https://learn.microsoft.com/en-us/azure/templates/microsoft.cognitiveservices/accounts/projects/applications) |
| Foundry MCP tool JSON: `type`, `server_label`, `server_url`, `require_approval`, `project_connection_id`, `allowed_tools` | [MCP tool how-to](https://learn.microsoft.com/en-us/azure/foundry/agents/how-to/tools/model-context-protocol) |
| `azd ai connection create --kind remote-tool --auth-type custom-keys --custom-key` | same |
| Hosted agent registration by `az rest` with `"kind": "hosted"` and `container_protocol_versions` | [Manage a hosted agent](https://learn.microsoft.com/en-us/azure/foundry/agents/how-to/manage-hosted-agent) |
| Hosted agents are GA; A2A is preview; Agent Optimizer is preview | [Foundry Agent Service overview](https://learn.microsoft.com/en-us/azure/foundry/agents/overview) |

## Fixed after the first real build

The repo was authored with no SDK, so the first build on a real machine found four things.
They are recorded here because they are the honest cost of that, and because two of them
say something about the packages rather than about my typing.

1. **`net9.0` target on an 8.0.423 SDK.** Now `net8.0`, in all three places it is pinned.
2. **Central package management plus floating versions.** Mutually exclusive (`NU1011`).
   Central package management is gone; `Directory.Build.targets` forces it off even if a
   stale `Directory.Packages.props` survives an extract-over-the-top.
3. **`Microsoft.Extensions.AI` downgrade (`NU1605`).** `Microsoft.Agents.AI` 1.19.0 requires
   10.9.0 or later, and the hosting preview requires 10.7.0 or later. A direct 9.x reference
   downgraded it on every project. The direct reference is gone; the package now arrives
   transitively, which is the right answer regardless, since the Agent Framework should pick
   its own floor.
4. **`ConfigureFunctionsWebApplication` and `ConfigureFunctionsApplicationInsights` not
   found.** The first lives in `...Extensions.Http.AspNetCore`, which switches the HTTP model
   from `HttpRequestData` to `HttpRequest`. This sample uses `HttpRequestData`, so the call
   was wrong rather than the package. Both calls and the two Application Insights worker
   packages are now removed. Host level telemetry still flows from the connection string
   that `infra/main.bicep` sets.

## Fixed on the second build

5. **`CS1705` assembly version conflict.** `Microsoft.Agents.AI.Foundry` 1.19.0 binds
   `Azure.AI.Projects` 2.1.0.0, which exists only as a beta. Pinning the stable 2.0.1 was
   therefore wrong. The reference is now `2.*-*`. This is worth knowing before you write
   anything about Foundry maturity: the current Agent Framework Foundry package requires a
   prerelease data plane SDK.
6. **`ToolLayerClient` not found.** A missing using after the class moved to
   `Orders.Tools.Core`. My error.
7. **`AIAgent.GetNewThread`.** Not present on the version that restored. The hosted agent now
   runs without an explicit thread, since Foundry supplies session state for hosted agents
   anyway.
8. **Bicep lint.** The deployments container now uses an explicit `blobServices` parent
   instead of a slash-joined name plus `dependsOn`.

## Fixed on the third build

9. **`DurableAIAgent`, `context.GetAgent`, `ConfigureDurableAgents` unresolved.** Two missing
   using directives, not missing packages. The types are split across two namespaces that do
   not match the package you would guess from:

   | Type or method | Namespace | Package |
   | --- | --- | --- |
   | `AIAgent`, `AgentSession`, `AgentResponse<T>` | `Microsoft.Agents.AI` | `Microsoft.Agents.AI` |
   | `DurableAIAgent`, `context.GetAgent(name)` | `Microsoft.Agents.AI.DurableTask` | `Microsoft.Agents.AI.DurableTask` |
   | `ConfigureDurableAgents`, `AddAIAgent` | `Microsoft.Agents.AI.Hosting.AzureFunctions` | same |

   The orchestration file needs the DurableTask namespace, the startup file needs the hosting
   namespace, and neither is implied by the other. `Microsoft.Agents.AI.DurableTask` is
   documented as the bring-your-own-compute package, which is why it was missing from the
   Functions project in the first place: the hosting package does not surface the
   orchestration types.

### The one remaining warning

`CS9057` fires because `Microsoft.DurableTask.Analyzers` 0.2.0 was built against Roslyn
4.12.0 and the .NET 8.0.4xx SDK ships 4.11.0. The analyzer is skipped, the build is
unaffected. It disappears on an SDK with a newer compiler.

## Fixed on the first provision attempt

10. **Model not in the catalog.** `azd up` warned that `gpt-4o-mini` (GlobalStandard,
    2024-07-18) was not found in `swedencentral`. `gpt-4o-mini` is closed to new deployments;
    its Standard retirement was 31 March 2026 and Global Standard follows on 1 October 2026.

    Two changes, and the second matters more than the first. The default is now `gpt-5-mini`.
    More importantly, `modelVersion` defaults to empty and the Bicep omits the `version`
    property entirely when it is, so Azure resolves the default version for that model in that
    region. A pinned version that a region does not carry is the most common way this kind of
    template fails, and pinning one bought nothing here.

    `modelCapacity` is now a parameter too, defaulting to 30, because Sweden Central has been
    reported returning no available capacity on GlobalStandard.

## Fixed on the second provision attempt

11. **`FUNCTIONS_WORKER_RUNTIME` rejected on Flex Consumption.** ARM returned
    `BadRequest: The following app setting (Site.SiteConfig.AppSettings.FUNCTIONS_WORKER_RUNTIME)
    for Flex Consumption sites is invalid.`

    On Flex Consumption the worker runtime is declared once, in
    `functionAppConfig.runtime`. Repeating it as an app setting is an error, not a duplicate.
    The same holds for `FUNCTIONS_EXTENSION_VERSION`, `WEBSITE_CONTENTAZUREFILECONNECTIONSTRING`,
    `WEBSITE_CONTENTSHARE` and `WEBSITE_RUN_FROM_PACKAGE`. This is the classic Consumption
    template habit that does not survive the move to Flex.

    `local.settings.json` still needs `FUNCTIONS_WORKER_RUNTIME`, so the sample settings files
    keep it. Only the deployed app settings drop it.

## Fixed on the third provision attempt

12. **One site per Flex Consumption plan.** ARM returned `There can only be one site per Flex
    Consumption serverfarm.` The template now creates two plans, one per function app.

    Worth pausing on, because it is the platform enforcing the diagram. The received pattern
    describes the action layer as "independently scalable", which reads as a design goal you
    could choose to honour or not. On Flex Consumption you have no choice: the orchestrator and
    the action layer sit on separate plans, scale separately, and cannot starve each other of
    instances. The boundary is real infrastructure, not just a line on a slide.

## Fixed on the fourth provision attempt

15. **`unable to find a resource tagged with 'azd-service-name: durable'`.** Provisioning
    succeeded and publishing failed. azd links a service in `azure.yaml` to the resource it
    deploys to by an `azd-service-name` tag, and the tag value must equal the service key.
    Both function apps are now tagged, `tools` and `durable` respectively.

    Nothing in the Bicep or the ARM validation catches this, because it is an azd convention
    rather than an Azure one. It only shows up at publish time, after everything has
    provisioned.

16. **The durable agent had no key for the action layer.** `HttpTools` uses
    `AuthorizationLevel.Function`, the Bicep sets `TOOL_LAYER_URL` but never `TOOL_LAYER_KEY`,
    so every activity would have returned 401. `test/configure.ps1` reads the tools app's
    default function key and sets it on the durable app.

    Deliberately a script rather than a `listKeys()` expression in the template: `listKeys()`
    output lands in the ARM deployment history in clear text and stays there.

17. **Durable app returned 404 for every route.** The action layer passed all seven of its
    smoke tests; the durable app answered 404 on `POST /api/fulfil/{orderId}`. A 404 on a route
    you know you deployed almost always means the host failed to start and registered no
    functions at all, rather than that the route is wrong.

    Cause: storage roles. The template granted Storage Blob Data Owner and nothing else.
    Durable Functions does not live in blobs alone: the task hub uses queues for the control
    and work item queues, and tables for instance and history state. Without those roles the
    durable extension cannot initialise, the host never finishes starting, and every function
    404s with nothing in the response explaining why.

    Both apps now get Storage Queue Data Contributor and Storage Table Data Contributor as
    well, because the Functions host itself uses all three for `AzureWebJobsStorage`.

    `test/diagnose.ps1` checks the three places the reason lives: the registered function list,
    the app settings, and the host traces in Application Insights.

18. **The durable app was running the tools app's code.** After the queue and table roles were
    added, the durable app still 404d on `/api/fulfil/{orderId}`. The host was `Running` with
    no errors, and the registered function list explained why: `LookupOrder`, `CheckInventory`,
    `ArrangeDelivery` and the `http_*` set. Not one orchestration or activity. The host trace
    `MCP server endpoint: https://ffb-durable-.../runtime/webhooks/mcp` settled it, because
    only `Orders.Tools` references the MCP extension.

    Cause: both function apps pointed `functionAppConfig.deployment.storage` at the same blob
    container. Flex Consumption keeps the deployed package there, so the second deployment
    overwrote the first and one app started running the other's code.

    **This failure is quiet, which is what makes it worth writing down.** Nothing errors. The
    host starts cleanly, registers whatever functions it found in the package it was given,
    and every route you expected returns 404. There is no signal anywhere that says "wrong
    code", and the only reliable tell is comparing the registered function list against what
    you wrote.

    Each app now has its own container, `deployments-tools` and `deployments-durable`. One
    deployment container per function app, always.

19. **`The orchestrator function completed on a non-orchestrator thread!`** The orchestration
    reaches the agent, the agent answers in about 18 seconds (the history shows `EventSent op
    Run` followed by `EventRaised` with an assistant message), and then the orchestrator fails
    this determinism check and is retried forever, which surfaces as `Running` with no
    progress.

    Durable Functions raises this when an orchestrator awaits something that is not a durable
    task, so the continuation lands on a thread pool thread. Four things in `FulfilOrder` could
    do it: `await agent.CreateSessionAsync()`, the `session:` overload of `RunAsync<T>`, the
    try/catch around the agent turn, or `SetCustomStatus` between steps.

    **The documentation cannot settle it.** Microsoft's sequential example calls
    `CreateSessionAsync` and their parallel example omits it, neither page mentions this error,
    and neither states whether try/catch around `RunAsync` is allowed. So
    `MinimalOrchestration.cs` bisects it: three orchestrations adding one suspect at a time,
    driven by `test/bisect.ps1`. The first that fails names the cause.

    **Resolved: package train skew.** Bisect A, which is Microsoft's own parallel-example
    shape with no session, no try/catch, no custom status and no activity, failed the same
    way. So `RunAsync<T>` itself does not work in an orchestrator on these versions, and the
    package list says why:

    ```
    Microsoft.Agents.AI                          1.19.0
    Microsoft.Agents.AI.Abstractions             1.19.0
    Microsoft.Agents.AI.Foundry                  1.19.0-preview.260822.1
    Microsoft.Agents.AI.DurableTask              1.16.0-preview.260730.1
    Microsoft.Agents.AI.Hosting.AzureFunctions   1.16.0-preview.260730.1
    Microsoft.Agents.AI.Workflows                1.16.0
    ```

    The durable packages are a release train behind the stable core they are running against.
    They hook into core internals, nothing declares an upper bound, so NuGet pairs 1.19 with
    1.16 without a murmur. It compiles, deploys, starts, the agent answers, and only then does
    the orchestrator fail a determinism check and get retried forever.

    Everything is now pinned to `1.16.*`, the train the durable previews were built against.
    Note the direction: you pin the STABLE package DOWN to match the previews. `validate.ps1`
    now fails if the `Microsoft.Agents.AI*` packages ever span more than one train again.

    **This is the sharpest maturity finding in the whole exercise.** Not that the packages are
    preview, which the feed tells you, but that the preview and stable halves of one product
    are on different trains, silently resolvable together, and fail at runtime rather than at
    build. No compiler error, no restore warning, no startup error. An 18 second agent
    response, then an orchestration that says Running forever.

20. **The action layer's state was in memory, on a platform that scales out.** With the train
    skew fixed, the orchestration completed in seconds and the last assertion still failed:
    "customer notified exactly once, expected 1, got 0".

    `OrderStore` was a singleton dictionary. Flex Consumption runs the action layer on many
    instances, so the durable agent wrote the notification on one instance and the smoke test
    read from another. The orchestration had done its job perfectly and looked broken.

    Reservations, deliveries and notifications now live in Azure Table Storage, reached with
    the same managed identity and storage account as `AzureWebJobsStorage`. Orders and
    inventory stay in memory, because they are read only reference data seeded identically
    everywhere. The Storage Table Data Contributor role added in fix 17 already covers this.

    **The idempotency guarantee got stronger as a side effect.** Table Storage rejects a
    duplicate row key with 409, so insert-if-absent is atomic across every instance. The
    original `lock` was only correct within one process, which means the reservation key,
    the control this whole sample is built around, was never actually safe until now.

    Worth noticing what caught this: not a crash, not an error, but a smoke test asserting a
    side effect happened exactly once. Nothing else in the stack would have told you.

21. **`azd provision` wipes `TOOL_LAYER_KEY`, silently.** After a model change, the
    orchestration completed with `fulfilled=False` and the reason "Order ORD-1001 could not be
    found", while a direct call to the same endpoint returned 200.

    `siteConfig.appSettings` in the Bicep is the complete set. Every `azd provision` rewrites
    it, and `TOOL_LAYER_KEY` is not in it because `configure.ps1` sets it afterwards. So the
    key disappears on every provision and every tool call comes back 401.

    `test/postprovision.ps1` and `.sh` now run `configure.ps1`, and `azure.yaml` already wired
    them as the azd postprovision hook, so the wiring survives.

22. **The client turned failures into nulls, which is how 21 stayed hidden.** `ToolLayerClient`
    returned `null` on any non-success status. A 401 therefore looked to the agent like "no
    such order", and `NotifyCustomerAsync` returned `null` while the activity reported success,
    so the notification count stayed at zero with nothing failing anywhere.

    Every method now throws on an unexpected status, with a message that names the likely cause
    for 401 and 403. Only genuine answers pass through: 404 from a lookup means the order does
    not exist, 409 from a reservation means insufficient stock.

    **This one is worth a paragraph in the post.** A durable activity that swallows a transport
    failure and returns success is worse than one that crashes, because the runtime's retry and
    the orchestration's error handling never engage. The agent then reasons confidently over a
    fabricated premise. Exactly once is only a guarantee if a failed call is allowed to look
    like one.

23. **The model was choosing the delivery date.** The first fully working run returned
    `bookingReference=DLV-ORD-1001-earliest weekday morning after today`. Asked for "the
    earliest weekday morning slot", the model returned the phrase.

    Funny, and then not, because the real problem is determinism. An orchestrator must produce
    the same decisions on replay, so time comes from `context.CurrentUtcDateTime`, never
    `DateTime.UtcNow` and never from a model. The orchestrator now computes the slot and tells
    the agent to use exactly that string.

    The general rule: anything that must be stable across replays belongs in the orchestrator,
    not in the prompt. That already covered the reservation key. It covers the clock too.

24. **`].name was unexpected at this time.`** On Windows `az` is a `.cmd` shim, so PowerShell
    shells out through `cmd.exe`, which mangles JMESPath brackets in `--query`. The scripts for
    options 1 and 3 now ask for `-o json` and filter in PowerShell. Property paths without
    brackets, such as `--query systemKeys.mcp_extension`, are still fine.

25. **`FOUNDRY_PROJECT_ENDPOINT` missing from the azd env.** azd only holds it if a provision
    captured its outputs. Both scripts now fall back to deriving it from Azure: find the
    `AIServices` account, list its projects through ARM, and build the endpoint. Less brittle
    than depending on azd env state.

26. **Table entities were private nested classes.** `verify-notifications.ps1` reported one
    notification with an empty message and an empty sequence. The row count was right and
    every custom property was at its default.

    `Azure.Data.Tables` maps custom properties by reflection, and private nested types do not
    map. The entity classes are now public and top level.

    This is the same failure shape as the shared deployment container and the null returning
    client: it does not throw, it returns something plausible. The only reason it was caught is
    that a test asserted on the content rather than on the count.

27. **The derived project endpoint was doubled.** ARM names child resources
    `account/project`, so building the endpoint from `$project.name` produced
    `.../api/projects/<account>/<project>`. Take the last segment.

28. **`azd ai connection create` needs an extension that is not installed by default.**
    "Foundry Connections (Beta)", id `azure.ai.connections`. The script installs it and
    retries, and falls back if it cannot.

    The fallback is worth understanding rather than just accepting. The documented
    alternative is the query string form,
    `https://<app>/runtime/webhooks/mcp?code=<mcp_extension_key>`, which needs no extension and
    puts the key **inside the agent definition**, readable by anyone who can read the agent.
    A connection keeps the key out of the definition entirely.

    So option 1 has a real security seam that options 2 and 3 do not: the agent is
    configuration stored in a managed service, and whether its credentials live inside that
    configuration depends on tooling you may not have installed. The docs also note that Key
    Vault references are not auto-injected here. This is the first thing to harden in a
    regulated environment.

29. **The verifier counted an empty array as one row.** `verify-notifications.ps1` reported
    "Notifications: 1" with an empty sequence and message. Three separate theories were
    developed and two code fixes shipped before the raw response settled it:

    ```
    HTTP/1.1 200 OK
    Content-Length: 2      <- the body is []
    ```

    `Invoke-RestMethod` returns `$null` for an empty JSON array, and `@($null)` has `Count` 1
    with a single null element. Wrapping the call in `@()` therefore reports one notification
    when there are none, and prints a blank line for the null.

    The Table store was correct throughout. ORD-1002's notification had been written by an
    earlier in-memory run and never existed in the table; the only durable run since the switch
    used ORD-1001.

    **This is the worst instance of the day's recurring theme, because the lying instrument was
    the test.** A tool that reports plausible-but-wrong results sends you fixing code that was
    never broken. Two of the fixes it caused, public table entities and the shared Application
    Insights role filter, were improvements on their own merits. The rest was wasted, and only
    the raw HTTP response ended it.

    Rule earned: when a test and the system disagree, get the unformatted response before
    changing anything.

30. **The action layer was never using Table Storage at all.** `verify-notifications.ps1`,
    once it stopped counting nulls, reported zero notifications for ORD-1001 and `reserved 0`
    after dozens of reservations. Not an empty order. An empty store.

    In Azure Functions, an app setting named `AzureWebJobsStorage__accountName` reaches
    `IConfiguration` as `AzureWebJobsStorage:accountName`. **The double underscore is the
    hierarchy separator, not part of the key.** `Program.cs` read the literal
    double-underscore name, got null, and fell back to `InMemoryOrderStateStore`.

    So the Table store shipped, was never constructed, created no tables, persisted nothing,
    and every endpoint answered 200 throughout. The smoke suite passed 10 of 10 against it,
    helped by the null-counting bug in fix 29 which turned the one assertion that would have
    caught it into a false pass.

    Three changes, and the second and third matter more than the first:

    - `STATE_STORAGE_ACCOUNT` is now set explicitly in the Bicep, and read first. The colon
      and double-underscore forms remain as fallbacks.
    - The fallback **logs a warning naming the in-memory store**. A fallback that does not
      announce itself will fool you, and this one did.
    - `GET /api/tools/health` reports which store is live and round trips a write through it.
      A configured store and a working store are not the same claim.

    `smoke.ps1` now asserts `persistent == true` before it asserts anything that depends on
    persistence. Had that existed this morning it would have failed on the first run.

31. **`TOOL_LAYER_KEY` was wiped again, by the provision that fixed 30.** The run against
    ORD-1002 came back 9 passed, 2 failed. The state store check finally passed clean
    (`TableOrderStateStore`, `persistent: True`, `roundTrip: ok`), the whole action layer
    passed, and the orchestration failed on its first tool call:

    ```
    Microsoft.DurableTask.TaskFailedException: Task 'NotifyCustomer' (#1) failed:
    notify_customer(ORD-1002) failed with 401 Unauthorized. The action layer rejected the
    credential. TOOL_LAYER_KEY is missing or stale: azd provision rewrites app settings from
    the Bicep, so re-run the postprovision hook.
    ```

    This is fix 21 recurring for exactly the reason fix 21 gives: `azd provision` rewrites
    `siteConfig.appSettings` wholesale from the template, and the key is deliberately not in
    the template. Setting `STATE_STORAGE_ACCOUNT` required a provision, so the provision took
    the key with it.

    **The failure is the good news.** That message is the one written in fix 22, and it named
    its own cause, the exact setting, and the fix, in one line. Every other fault in this log
    presented as something plausible instead: an empty store answering 200, a health check
    counting a null, a host serving the wrong app's routes. This one failed loudly and
    correctly on the first attempt, and cost about a minute.

    Three changes so the loop closes rather than repeats:

    - `configure.ps1` reads the setting back and throws if it does not match. `az ... set`
      exiting 0 means ARM accepted the write, not that the value is what you think.
    - `configure.ps1` waits 30 seconds afterwards, because setting an app setting restarts the
      host and the first smoke run otherwise races the restart into a 401 that is already
      fixed.
    - `smoke.ps1` takes an optional `-ResourceGroup` and preflights the setting before it
      starts an orchestration. One ARM read, or three minutes spent watching a doomed run.

    The rule the repo now states plainly: **any `azd provision` is followed by
    `configure.ps1`.** Not `azd deploy`, which leaves app settings alone. Provision only.

32. **`diagnose.ps1` threw 22 copies of `The term 'try' is not recognized`.** My own bug, in
    the failed-requests section added to diagnose fix 31, and it arrived at the worst possible
    moment: a diagnostic tool erroring while you are already reading an unfamiliar failure.

    The line used `try/catch` inline in a `-f` argument list. The fix is to assign it first.
    The interesting part is why nothing caught it, because **it parses cleanly**:

    ```powershell
    # parse errors: 0.  Fails only when the line executes.
    Write-Host ("{0}" -f (try { [datetime]$r[0] } catch { '--' }), $r[1])
    ```

    PowerShell parses in two modes. Inside parentheses in argument position it reads `try` as
    a *command name* with two script block arguments, which is valid syntax for a command that
    happens not to exist. `Parser::ParseFile` returns zero errors. You find out when
    PowerShell goes looking for a program called `try`.

    So `validate.ps1` gained a step that runs two checks, not one: parse errors, and an AST
    walk for a reserved statement keyword sitting in command position, which is never
    intentional and is the only signal available for the case above. Verified both ways, a
    deliberately broken file is caught and the 13 real scripts pass.

    Worth naming, because the repo already had `bash -n` on the two `.sh` files and nothing at
    all on the 13 `.ps1` files, which are where the actual operational risk lives. And the
    general form is the same lesson as everything above it: **a clean parse is not a promise
    that the script runs**, in the same way that a 200 was not a promise that anything was
    stored.

33. **`definition.kind` must be `prompt`, not `declarative`.** With the 403 cleared, the
    create call reached actual payload validation for the first time and the service returned
    the full legal enum in the error:

    ```
    "message": "Must be one of: [prompt, hosted, workflow, external, voice]",
    "param": "definition.kind"
    ```

    `agent.json` said `declarative`, a term the docs use *prose-style* for this kind of agent.
    The REST reference's `AgentKind` confirms `prompt` is the discriminator value that selects
    `PromptAgentDefinition`. Interesting detail: the live service's enum (`external`, `voice`
    included) is already ahead of the published REST reference, which lists only three. The
    API is the source of truth and it tells you so in its 400s.

    Same run, second finding: with the `azure.ai.connections` extension finally installed,
    `azd ai connection create` failed with `no Foundry project endpoint resolved`. The
    extension reads the endpoint from the process environment or a workspace default, not from
    the derivation the script had already done into a local variable. The script now exports
    `$env:FOUNDRY_PROJECT_ENDPOINT` before calling it.

    Both are the same shape as fix 6 in the "not confirmed" list predicted: the agent REST
    surface was the least verified thing in the repo, and the script's own header said
    "expect to iterate". This was the iteration.

34. **The prompt agent notified twice. This one is not a bug, it is the finding.** First real
    run of option 1 against ORD-1002, instructions saying "send the customer exactly one
    message", and `verify-notifications.ps1` reported:

    ```
    Notifications for ORD-1002: 2
      [1] Your delivery has been booked for 2026-08-28-AM. ...
      [2] Your order has been reserved and delivery is booked for the earliest weekday ...
    ```

    Two messages, differently worded, because they are two separate generations. And in the
    same run: `reserved 1`. The reservation did not duplicate. `reserve_stock` carries an
    idempotency key the action layer enforces; `notify_customer` has no key and was trusted to
    the model, which was told once and did it twice.

    That is the whole architecture argument in one run. Where the guarantee lived in the
    runtime (the action layer's insert-if-absent), instruction-following did not matter. Where
    the guarantee lived in the instructions, it did not hold. Option 2 gets exactly-once
    notification structurally, by putting the call in an orchestration activity; options 1
    and 3 get it probabilistically, by asking nicely. The sample now has data for that
    sentence instead of an assertion.

35. **The health probe starved the demo's own inventory.** Same run, the durable agent refused
    ORD-1001, "Free stock is 1, which is lower than the required quantity of 2", on a SKU
    seeded at 12. No bug in the orchestration: free stock really was 1. The health endpoint
    proves the store round-trips by reserving one SKU-KEYBOARD per call, reservations are held
    forever, and the afternoon's diagnostics had eaten eleven units one probe at a time. The
    smoke idempotency test holds two more per run.

    A diagnostic that mutates the state it reports on will eventually cause the failures it
    exists to catch. Probes and the smoke idempotency test now spend from `SKU-PROBE`, seeded
    at a million, and the narrative SKUs belong to the narrative again. `clear-state.ps1`
    empties the three state tables when the seeds need restoring, deleting rows rather than
    tables, because a dropped table 409s on recreate for up to a minute and the apps only run
    `CreateIfNotExists` at startup.

36. **The model refused a fulfillable order, and the orchestrator believed it.** After
    clear-state, keyboards at 12, ORD-1001 wanting 2, the triage turn returned
    `canFulfil=false` with "Free stock is lower than the order quantity". The store was
    checked directly: `available: 12`. The pipe was checked directly: the test-agent endpoint
    asked the model to repeat check_inventory's JSON verbatim, and it did, `available: 12`.
    App Insights showed lookup_order and check_inventory both executed during the triage
    window. Everything worked. The model got the comparison wrong once, in the one turn that
    was a gate, and a customer notification went out saying the order could not be fulfilled.

    Note the trace detail: the wrong turn ran on 670 input tokens where every correct triage
    ran on ~997, and its refusal carried no numbers where every correct refusal quoted them.
    A vaguer answer on less context is what a guess looks like.

    The diagnosis discipline mattered here, because the smoke suite said 12 of 12 PASSED. The
    suite asserts the orchestration completes and notifies once, which it did; nothing asserts
    the DECISION was right. The tell was the reason string being vaguer than the previous
    run's, which is not something a test catches.

    The fix is not a better prompt. The orchestration no longer asks the model whether:

    - `LookupOrder` is now an activity. Facts come from activities, never from a model.
    - The stock pre-check is gone entirely. `reserve_stock` IS the stock check, enforced
      atomically by the action layer, and it is the only answer that cannot go stale between
      checking and reserving.
    - The refusal message quotes the action layer's reason verbatim. When the runtime decides,
      the runtime explains.
    - The model keeps step 3, planning the delivery and writing the customer message, which is
      the work only a model can do.

    Together with fix 34 this closes the day's argument from both sides. The prompt agent did
    MORE than instructed with a state-changing tool (two notifications for one order). The
    durable triage did WORSE than instructed with a read-only one (a wrong verdict on data it
    held). Instructions are not guarantees in either direction. Substrates and action layers
    are.

37. **`FOUNDRY_*` environment variables are reserved on hosted agents.** The container built
    and pushed first try (`az acr build`, 1m17s), and registration returned:

    ```
    "Environment variable 'FOUNDRY_PROJECT_ENDPOINT' is reserved for platform use.
     All FOUNDRY_* and AGENT_* variables are reserved per container-image-spec."
    ```

    Which is the platform saying it injects those itself. That makes the hosted Program.cs
    honest by accident: it requires `FOUNDRY_PROJECT_ENDPOINT` from configuration, and the
    platform, not the registration payload, is what supplies it. The payload now carries only
    `TOOL_LAYER_URL`, `TOOL_LAYER_KEY` and `MODEL_DEPLOYMENT_NAME`.

    Same key caveat as option 1's `-NoConnection` fallback, one layer over: `TOOL_LAYER_KEY`
    rides in the agent definition as an environment variable, readable by anyone who can read
    the agent. Fine for this demo group, wrong in production, where the container's Entra
    identity should authenticate to the action layer instead of a shared key.

38. **The image is pulled by the Foundry PROJECT's managed identity.** Hosted agent versions 1
    and 2 both died on `ImageError: Container registry authentication failed`, with AcrPull
    granted, between attempts, to the agent's instance identity, the blueprint identity and
    the Foundry account identity. None of them cleared it. AcrPull on the project identity
    did: version 3 came up `active` with no error.

    The sources disagree, which is why this took three versions. The Learn page for private
    ACR says the per-agent identity pulls and that azd grants it during deploy; a field
    writeup says plainly that AcrPull goes to the project managed identity, not the agent
    identity. The second matched observed behaviour. Worth understanding WHY the first cannot
    work over raw REST even if it were right: the per-agent instance identity is minted at
    registration, and the pull fires the moment registration is accepted, so there is no
    moment at which you could grant it. A failed version stays failed; every retry is a new
    version with a new identity. Only a stable identity breaks that loop, and the project's
    is the one that does.

    `deploy-hosted-agent.ps1` now grants AcrPull to the project identity before registering,
    so the sequence works first time. `azd ai agent doctor` is worth knowing about, but it
    audits azd's own flow (`azure.ai.agent` service in azure.yaml), which this repo's REST
    route does not use.

39. **`session_not_ready`: the container declared a protocol it did not speak, on a port
    nobody probed.** With the image pulling cleanly (fix 38), the first playground invoke
    returned `HTTP 424`: "Session ... did not become ready ... verify the /readiness endpoint
    returns HTTP 200." Two stacked faults:

    - **Port.** Foundry probes `GET /readiness` on **8088**. The Dockerfile pinned
      `ASPNETCORE_URLS` to 8080. The official sample's Dockerfile carries a comment
      describing this exact symptom, port for port.
    - **Protocol.** Registration declared `container_protocol_versions: responses`, and
      Program.cs mapped a hand-rolled `POST /run`. Nothing ever calls `/run`. The platform
      routes traffic to the protocol's own paths (`POST /responses` and friends) and probes
      `/readiness` first. Declaring a protocol is a promise about the container's HTTP
      surface, and this container did not keep it.

    The fix is the `Microsoft.Agents.AI.Foundry.Hosting` package:
    `builder.Services.AddFoundryResponses(agent)` plus `app.MapFoundryResponses()` maps
    `/readiness` and the full responses surface. (The sibling Invocations SDK does NOT map
    `/readiness`, per a comment in Microsoft's own echo sample, which suggests this class of
    424 is common enough that they wrote it down.)

    Also learned on the way, from the earlier playground attempt landing in the morning's
    prompt-agent thread: the model answered "Order ORD-1002 has already been handled" from
    its own conversation history, while the action layer, post clear-state, held nothing.
    The thread remembered; only the system of record knew. That line belongs in the post.

## Redeploy conflicts, and how the template avoids them

13. **Role assignment names cannot use `principalId`.** I briefly changed them to
    `guid(scope.id, site.identity.principalId, role)` to dodge a redeploy conflict. Bicep
    rejects that with `BCP120`: a roleAssignment name must be computable before the deployment
    starts, and `principalId` is a runtime output. Reverted to resource ids.

    The conflict I was dodging does not arise here anyway. Every assignment is scoped to a
    resource inside this resource group, so deleting the group deletes the assignments with
    it. For the rare orphaned case there is now a `roleAssignmentSeed` parameter: set it to any
    new string to generate fresh names instead of trying to update existing ones in place.

14. **Soft deleted Cognitive Services accounts.** Deleting the resource group does not purge
    the Foundry account. Recreating it with the same name then conflicts. `test/reset.ps1`
    deletes the group and purges the account; `az cognitiveservices account list-deleted`
    shows what is still lingering.

## Not confirmed. Check these first when something fails

1. **Package versions.** Only two were read off the feed and pinned exactly:
   `Microsoft.Azure.Functions.Worker.Extensions.Mcp` 1.6.0, and the fact that the Agent
   Framework hosting packages are preview only. Everything else floats on a conservative
   major (`2.*`, `3.*`, `1.*`), and the two preview-only packages float across
   prereleases with `1.*-*`.

   Floating is why there is no `Directory.Packages.props`. Central package management rejects
   floating versions outright with `NU1011`, so the versions live in the four project files
   instead. Run `dotnet list package` after a green restore and pin them if you want
   reproducible builds, which for anything beyond a sample you do.

   **Target framework.** The projects target `net8.0`, because that is the lowest common
   denominator across the packages here and the SDK on the machine this was first built on.
   Moving to `net9.0` means changing `Directory.Build.props`, the two base images in
   `src/Orders.HostedAgent/Dockerfile`, and `functionAppConfig.runtime.version` for both apps
   in `infra/main.bicep`. Changing only the first one produces a green `dotnet build` and a
   broken deployment, which is the worst of the three outcomes.

2. **`Microsoft.Agents.AI.Hosting.AzureFunctions` worker dependency.** Learn says
   Functions Worker 2.2.0 or later. The NuGet dependency list appeared to say 2.50.0 or later.
   These cannot both be right. Read the package's dependency list before pinning.

3. **`Microsoft.Agents.AI.Foundry` version line.** Core `Microsoft.Agents.AI` has a stable
   1.19.0 while this package's stable line appears to stop at 1.5.0, with 1.19.0 available only
   as preview. That is unusual enough to be worth a look before you write about it.

4. **The MCP HTTP transport in C#.** The documented way to attach a header such as
   `x-functions-key` to an HTTP or SSE MCP transport from .NET could not be confirmed. Python
   has a documented `header_provider` pattern; the C# equivalent was not in the docs I read.

   **This is why options 2 and 3 in this repo call the action layer over typed HTTP rather than
   over MCP.** The handlers are the same class either way: `Orders.Tools.Core.OrderTools` is
   bound to MCP triggers in `McpTools.cs` and to HTTP triggers in `HttpTools.cs`. Option 1
   reaches it over MCP, because Foundry does the calling and that path is documented. If you
   confirm the C# transport header story, swapping options 2 and 3 to MCP is a change to one
   file, `ToolLayerClient.cs`, and nothing else moves.

5. **Flex Consumption as a hard requirement for durable agents.** The docs recommend it and
   describe scaling to zero on it. They do not say it is required. The Bicep provisions FC1
   anyway, since that is the plan the guidance points at.

6. **`Azure.AI.Projects` type surface.** Two current Learn pages disagree: one shows
   `MCPToolDefinition` / `MCPToolResource` / `MCPApproval`, another shows
   `ResponseTool.CreateMcpTool` / `McpToolCallApprovalPolicy`, and the 2.0.1 readme shows
   `ProjectsAgentVersion`. They are probably tracking different SDK versions. This repo avoids
   the question by creating the prompt agent over REST rather than through the SDK.

7. ~~**Every line of Bicep.** `bicep build` has not been run.~~ **Resolved.** The template now
   builds clean and has provisioned the resource group repeatedly. Fixes 11 through 15 are what
   that cost.

## Known design limits, deliberate

- **The action layer stores state in Azure Table Storage, which is not a transactional store.**
  This started as an in-memory singleton, which fix 20 and fix 30 between them showed was wrong
  on a platform that scales out. Table Storage buys the one property the sample needs:
  insert-if-absent is atomic, so a duplicate reservation key gets a 409 from the service rather
  than from a race between two instances. It does not buy multi-row transactions. Reserving
  stock and decrementing the count are two writes here, not one. Move reservations to Azure SQL
  or Cosmos DB before reusing any of this.

- **Option 2 gives the model three tools; option 3 gives it five.** That asymmetry is the
  honest consequence of the architecture, not an oversight. With a durable orchestrator you can
  put the two state changing operations in activities and get exactly once from the runtime.
  Without one, the model is trusted with them. The code says so in both files.

- **No load or failure injection.** The claim that a durable agent resumes mid-flight after a
  host restart is asserted here, not measured. Measuring it needs a kill harness the smoke tests
  do not have. That is the obvious next build, and the honest place to stop for now.
