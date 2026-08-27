using System.Net;
using Microsoft.Agents.AI;
// DurableAIAgent and the GetAgent extension on TaskOrchestrationContext both live here,
// not in Microsoft.Agents.AI. The package is Microsoft.Agents.AI.DurableTask.
using Microsoft.Agents.AI.DurableTask;
using Microsoft.Azure.Functions.Worker;
using Microsoft.Azure.Functions.Worker.Http;
using Microsoft.DurableTask;
using Microsoft.DurableTask.Client;
using Microsoft.Extensions.Logging;
using Orders.Tools.Core;

namespace Orders.DurableAgent;

/// <summary>
/// Option 2. Orchestration in Azure Functions, with the state machine supplied rather than
/// hand written.
///
/// Read the orchestrator as the answer to the claim this sample was built to test. Every
/// agent turn below is a checkpoint. If the host dies between the reservation and the
/// delivery booking, the replay does not re-run the reservation, and the customer is not
/// notified twice. In 2025 you wrote that yourself. You no longer do.
///
/// The division of labour here was earned the hard way, and it is the sample's second claim:
/// activities fetch facts and commit side effects, the action layer enforces constraints, and
/// the model does the one thing only a model can do, which is plan and write. The model never
/// decides WHETHER. See the step 1 comment for the run that drew that line.
/// </summary>
public class FulfilmentOrchestration
{
    public const string AgentName = "FulfilmentAgent";

    [Function(nameof(FulfilOrder))]
    public static async Task<FulfilmentOutcome> FulfilOrder(
        [OrchestrationTrigger] TaskOrchestrationContext context)
    {
        var request = context.GetInput<FulfilOrderRequest>()
            ?? throw new InvalidOperationException("An order id is required.");

        var log = context.CreateReplaySafeLogger<FulfilmentOrchestration>();
        log.LogInformation("Fulfilling {OrderId}", request.OrderId);

        // Custom status is the cheapest observability a durable orchestration has. It shows
        // up in the status endpoint immediately, so a hang tells you which step it hung on
        // instead of just saying Running. Every step below sets it before doing the work.
        context.SetCustomStatus("resolving agent");

        DurableAIAgent agent = context.GetAgent(AgentName);
        AgentSession session = await agent.CreateSessionAsync();

        // Step 1. Facts come from an activity, not from a model.
        //
        // The first version of this orchestration opened with an agent turn: "use lookup_order
        // and check_inventory, decide whether there is enough free stock". It worked for a day,
        // and then, with 12 units free and 2 wanted, the model returned canFulfil=false with
        // the reason "Free stock is lower than the order quantity". The tools had been called.
        // The tool had answered 12. The model fumbled a comparison a CPU does perfectly, the
        // orchestrator took its word for it, and a customer was told their order could not be
        // fulfilled while eleven spare units sat on the shelf.
        //
        // The lesson is the same one the action layer already encodes: a model's judgment is
        // not a gate on a fact the runtime can check. Reading an order is a lookup. Whether
        // stock covers it is arithmetic the reservation call enforces anyway. Neither needs a
        // model, so neither gets one now.
        context.SetCustomStatus("looking up order");

        var order = await context.CallActivityAsync<Order?>(
            nameof(ToolActivities.LookupOrder), request.OrderId);

        if (order is null)
        {
            // No notification: there is no customer behind an id that does not exist.
            return new FulfilmentOutcome(
                request.OrderId, false, null, null, $"Unknown order '{request.OrderId}'.");
        }

        // Step 2. Reserve, with a key derived from the ORDER, never from the run.
        //
        // This matters more than it looks. A run-derived key is indistinguishable from having
        // no key at all: every replay and every retry invents a fresh one and holds stock again.
        // Deriving it from the order is what makes the tool call safe to repeat.
        //
        // Note there is no stock pre-check. ReserveStock IS the stock check: the action layer
        // refuses over-reservation atomically, which is the only answer that cannot be stale
        // between checking and reserving.
        var reservationKey = $"resv-{request.OrderId}";
        context.SetCustomStatus("reserving stock");

        var reservation = await context.CallActivityAsync<ReservationResult>(
            nameof(ToolActivities.ReserveStock),
            new ReserveArgs(order.Sku, order.Quantity, reservationKey));

        if (reservation.Reservation is null)
        {
            // The refusal reason is the action layer's, verbatim. When the runtime decides,
            // the runtime explains. The model is not asked to narrate a fact it did not decide.
            await context.CallActivityAsync(
                nameof(ToolActivities.NotifyCustomer),
                new NotifyArgs(request.OrderId,
                    $"We cannot fulfil this order yet: {reservation.Detail}"));

            return new FulfilmentOutcome(
                request.OrderId, false, null, null, reservation.Detail);
        }

        // Step 3. Let the agent book the slot and write the customer message.
        //
        // The DATE is computed here, not by the model. Two reasons, and the second is the one
        // people forget. First, the first run of this asked the agent for "the earliest weekday
        // morning slot after today" and got a booking reference containing the literal string
        // "earliest weekday morning after today", because a model asked for a slot will happily
        // return the phrase. Second, and more important: an orchestrator must be
        // deterministic, so time comes from context.CurrentUtcDateTime, never DateTime.UtcNow
        // and never from a model. On replay the same instant comes back and the same slot is
        // chosen. Ask a model for the date and every replay can pick a different one.
        var slotDate = context.CurrentUtcDateTime.Date.AddDays(1);
        while (slotDate.DayOfWeek is DayOfWeek.Saturday or DayOfWeek.Sunday)
        {
            slotDate = slotDate.AddDays(1);
        }
        var slot = $"{slotDate:yyyy-MM-dd}-AM";

        context.SetCustomStatus($"planning: awaiting agent, slot {slot}");

        AgentResponse<FulfilmentPlan> plan = await agent.RunAsync<FulfilmentPlan>(
            message:
                $"Stock is held for order {request.OrderId} under key {reservationKey}. " +
                $"Call arrange_delivery for order {request.OrderId} with the slot exactly as " +
                $"'{slot}'. Do not invent a different slot. Then write one short message " +
                "telling the customer what happens next.",
            session: session);

        // Step 4. The customer facing side effect runs as an activity, not as a model turn,
        // so it is committed exactly once even if the agent turn above is replayed.
        context.SetCustomStatus("notifying customer");

        await context.CallActivityAsync(
            nameof(ToolActivities.NotifyCustomer),
            new NotifyArgs(request.OrderId, plan.Result.CustomerMessage));

        context.SetCustomStatus("done");

        return new FulfilmentOutcome(
            request.OrderId,
            true,
            reservationKey,
            plan.Result?.BookingReference,
            "Fulfilled.");
    }

    /// <summary>HTTP starter. Returns 202 and a status endpoint, the standard Durable Functions shape.</summary>
    [Function(nameof(StartFulfilment))]
    public static async Task<HttpResponseData> StartFulfilment(
        [HttpTrigger(AuthorizationLevel.Function, "post", Route = "fulfil/{orderId}")]
            HttpRequestData req,
        [DurableClient] DurableTaskClient client,
        string orderId)
    {
        var instanceId = await client.ScheduleNewOrchestrationInstanceAsync(
            nameof(FulfilOrder),
            new FulfilOrderRequest(orderId));

        return await client.CreateCheckStatusResponseAsync(req, instanceId);
    }
}

public record FulfilOrderRequest(string OrderId);

public record TriageResult(bool CanFulfil, string Sku, int Quantity, string Reason);

public record FulfilmentPlan(string BookingReference, string CustomerMessage);

public record ReserveArgs(string Sku, int Quantity, string ReservationKey);

public record NotifyArgs(string OrderId, string Message);
