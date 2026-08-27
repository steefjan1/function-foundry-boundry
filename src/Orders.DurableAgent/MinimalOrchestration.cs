using System.Net;
using Microsoft.Agents.AI;
using Microsoft.Agents.AI.DurableTask;
using Microsoft.Azure.Functions.Worker;
using Microsoft.Azure.Functions.Worker.Http;
using Microsoft.DurableTask;
using Microsoft.DurableTask.Client;

namespace Orders.DurableAgent;

/// <summary>
/// A bisect, not a feature.
///
/// FulfilOrder fails with "The orchestrator function completed on a non-orchestrator thread!",
/// which is Durable Functions saying the orchestrator awaited something that was not a durable
/// task. Four candidates in FulfilOrder could do that:
///
///   1. await agent.CreateSessionAsync()
///   2. agent.RunAsync&lt;T&gt;(..., session: session)   with an explicit session
///   3. the try/catch around the agent turn
///   4. context.SetCustomStatus between steps
///
/// Microsoft's own docs use CreateSessionAsync in the sequential example and omit it in the
/// parallel one, so the documentation cannot settle it. These three orchestrations add one
/// candidate at a time. Run them in order and the first one that fails names the cause.
/// </summary>
public class MinimalOrchestration
{
    /// <summary>Step 1: no session, no try/catch, no custom status, no activities.</summary>
    [Function(nameof(BisectA_NoSession))]
    public static async Task<string> BisectA_NoSession(
        [OrchestrationTrigger] TaskOrchestrationContext context)
    {
        var request = context.GetInput<FulfilOrderRequest>()!;

        DurableAIAgent agent = context.GetAgent(FulfilmentOrchestration.AgentName);

        AgentResponse<TriageResult> triage = await agent.RunAsync<TriageResult>(
            $"Order {request.OrderId} needs fulfilling. Use lookup_order and check_inventory. " +
            "Decide whether there is enough free stock. Do not reserve anything yet.");

        return triage.Result is null
            ? "AGENT RETURNED NULL RESULT"
            : $"canFulfil={triage.Result.CanFulfil} sku={triage.Result.Sku} qty={triage.Result.Quantity}";
    }

    /// <summary>Step 2: adds the explicit session. Everything else identical to A.</summary>
    [Function(nameof(BisectB_WithSession))]
    public static async Task<string> BisectB_WithSession(
        [OrchestrationTrigger] TaskOrchestrationContext context)
    {
        var request = context.GetInput<FulfilOrderRequest>()!;

        DurableAIAgent agent = context.GetAgent(FulfilmentOrchestration.AgentName);
        AgentSession session = await agent.CreateSessionAsync();

        AgentResponse<TriageResult> triage = await agent.RunAsync<TriageResult>(
            message:
                $"Order {request.OrderId} needs fulfilling. Use lookup_order and check_inventory. " +
                "Decide whether there is enough free stock. Do not reserve anything yet.",
            session: session);

        return triage.Result is null
            ? "AGENT RETURNED NULL RESULT"
            : $"canFulfil={triage.Result.CanFulfil} sku={triage.Result.Sku} qty={triage.Result.Quantity}";
    }

    /// <summary>Step 3: adds custom status and an activity call. No session, no try/catch.</summary>
    [Function(nameof(BisectC_WithActivity))]
    public static async Task<string> BisectC_WithActivity(
        [OrchestrationTrigger] TaskOrchestrationContext context)
    {
        var request = context.GetInput<FulfilOrderRequest>()!;

        context.SetCustomStatus("awaiting agent");

        DurableAIAgent agent = context.GetAgent(FulfilmentOrchestration.AgentName);

        AgentResponse<TriageResult> triage = await agent.RunAsync<TriageResult>(
            $"Order {request.OrderId} needs fulfilling. Use lookup_order and check_inventory. " +
            "Decide whether there is enough free stock. Do not reserve anything yet.");

        context.SetCustomStatus("notifying");

        await context.CallActivityAsync(
            nameof(ToolActivities.NotifyCustomer),
            new NotifyArgs(request.OrderId, "Bisect C reached the activity."));

        context.SetCustomStatus("done");
        return "completed with activity";
    }

    /// <summary>Starter for all three. POST /api/bisect/{which}/{orderId} where which is a, b or c.</summary>
    [Function(nameof(StartBisect))]
    public static async Task<HttpResponseData> StartBisect(
        [HttpTrigger(AuthorizationLevel.Function, "post", Route = "bisect/{which}/{orderId}")]
            HttpRequestData req,
        [DurableClient] DurableTaskClient client,
        string which,
        string orderId)
    {
        var name = which.ToLowerInvariant() switch
        {
            "a" => nameof(BisectA_NoSession),
            "b" => nameof(BisectB_WithSession),
            "c" => nameof(BisectC_WithActivity),
            _ => null
        };

        if (name is null)
        {
            var bad = req.CreateResponse(HttpStatusCode.BadRequest);
            await bad.WriteAsJsonAsync(new { error = "which must be a, b or c" });
            return bad;
        }

        var instanceId = await client.ScheduleNewOrchestrationInstanceAsync(
            name, new FulfilOrderRequest(orderId));

        return await client.CreateCheckStatusResponseAsync(req, instanceId);
    }
}
