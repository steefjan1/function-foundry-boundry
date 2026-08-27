using Azure.AI.Projects;
using Azure.Identity;
using Microsoft.Agents.AI;
using Microsoft.Agents.AI.Foundry.Hosting;
using Microsoft.Extensions.AI;
using Orders.Tools.Core;

// ---------------------------------------------------------------------------
// Option 3. The same agent code, running inside Foundry's runtime instead of yours.
//
// This project exists to make the ownership split visible. The agent construction below is
// character for character the block in Orders.DurableAgent/Program.cs. What changes is
// everything around it: Foundry supplies the endpoint, the scaling, the Entra identity and
// the session state, and you supply the container. Neither side owns the whole thing, which
// is why the sample keeps insisting you write the topology down.
// ---------------------------------------------------------------------------

var builder = WebApplication.CreateBuilder(args);
var config = builder.Configuration;

var toolLayerUrl = config["TOOL_LAYER_URL"]
    ?? throw new InvalidOperationException("TOOL_LAYER_URL is required.");
var toolLayerKey = config["TOOL_LAYER_KEY"];
var foundryEndpoint = config["FOUNDRY_PROJECT_ENDPOINT"]
    ?? throw new InvalidOperationException("FOUNDRY_PROJECT_ENDPOINT is required.");
var modelDeployment = config["MODEL_DEPLOYMENT_NAME"] ?? "gpt-5.4-mini";

var http = new HttpClient { BaseAddress = new Uri(toolLayerUrl.TrimEnd('/') + "/") };
if (!string.IsNullOrWhiteSpace(toolLayerKey))
{
    http.DefaultRequestHeaders.Add("x-functions-key", toolLayerKey);
}

var toolLayer = new ToolLayerClient(http);

const string Instructions = """
    You fulfil customer orders for a hardware retailer.

    Use the supplied tools rather than guessing. Never invent stock levels, order ids
    or booking references. If free stock is lower than the order quantity, say so plainly.

    Reserve stock exactly once, using a reservation key of the form resv-{orderId}. Never
    derive the key from the current run or from a timestamp.
    """;

AIAgent agent = new AIProjectClient(new Uri(foundryEndpoint), new DefaultAzureCredential())
    .AsAIAgent(
        model: modelDeployment,
        instructions: Instructions,
        name: "FulfilmentHostedAgent",
        tools:
        [
            AIFunctionFactory.Create(toolLayer.LookupOrderAsync,
                "lookup_order", "Look up a single customer order by its id."),
            AIFunctionFactory.Create(toolLayer.CheckInventoryAsync,
                "check_inventory", "Return on hand, reserved and available stock for a SKU."),
            AIFunctionFactory.Create(toolLayer.ReserveStockAsync,
                "reserve_stock", "Hold stock for an order. Idempotent on the reservation key."),
            AIFunctionFactory.Create(toolLayer.ArrangeDeliveryAsync,
                "arrange_delivery", "Book a delivery slot for an order."),
            AIFunctionFactory.Create(toolLayer.NotifyCustomerAsync,
                "notify_customer", "Send the customer a message about their order.")
        ]);

// Note the tool set is wider than option 2's. Without a durable orchestrator there is no
// activity boundary to hide behind, so the model itself has to be trusted with the two
// state changing tools. That is not a detail. It is the trade, stated in code.

// ---------------------------------------------------------------------------
// Host the agent on the Responses protocol, which is what the registration DECLARED.
//
// The first version of this file declared container_protocol_versions: responses at
// registration and then mapped a hand-rolled POST /run. Nothing ever called /run. The
// platform routes playground traffic to the protocol's own paths and probes GET /readiness
// before routing anything at all, so every invoke failed with HTTP 424 session_not_ready
// while the container sat healthy, listening politely on routes nobody visits.
//
// AddFoundryResponses/MapFoundryResponses is the whole fix: it maps /readiness and the full
// /responses surface for the agent. Declaring a protocol is a promise about the container's
// HTTP surface, and the hosting package is what keeps that promise.
// ---------------------------------------------------------------------------
builder.Services.AddFoundryResponses(agent);

var app = builder.Build();
app.MapFoundryResponses();

app.Run();
