using Azure.AI.Projects;
using Azure.Identity;
using Microsoft.Agents.AI;
// ConfigureDurableAgents and AddAIAgent are extensions in this namespace.
using Microsoft.Agents.AI.Hosting.AzureFunctions;
using Microsoft.Azure.Functions.Worker.Builder;
using Microsoft.Extensions.AI;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Hosting;
using Orders.DurableAgent;
using Orders.Tools.Core;

var builder = FunctionsApplication.CreateBuilder(args);

var config = builder.Configuration;

var toolLayerUrl = config["TOOL_LAYER_URL"]
    ?? throw new InvalidOperationException("TOOL_LAYER_URL is required.");
var toolLayerKey = config["TOOL_LAYER_KEY"];
var foundryEndpoint = config["FOUNDRY_PROJECT_ENDPOINT"]
    ?? throw new InvalidOperationException("FOUNDRY_PROJECT_ENDPOINT is required.");
var modelDeployment = config["MODEL_DEPLOYMENT_NAME"] ?? "gpt-5.4-mini";

// ---------------------------------------------------------------------------
// The action layer client. One registration for activities (via DI), one plain
// instance for the agent's own tool set. Both point at the same Functions app.
// ---------------------------------------------------------------------------
static HttpClient BuildToolClient(string url, string? key)
{
    var http = new HttpClient { BaseAddress = new Uri(url.TrimEnd('/') + "/") };
    if (!string.IsNullOrWhiteSpace(key))
    {
        http.DefaultRequestHeaders.Add("x-functions-key", key);
    }

    return http;
}

builder.Services.AddHttpClient<ToolLayerClient>(client =>
{
    client.BaseAddress = new Uri(toolLayerUrl.TrimEnd('/') + "/");
    if (!string.IsNullOrWhiteSpace(toolLayerKey))
    {
        client.DefaultRequestHeaders.Add("x-functions-key", toolLayerKey);
    }
});

var agentTools = new ToolLayerClient(BuildToolClient(toolLayerUrl, toolLayerKey));

// ---------------------------------------------------------------------------
// The agent itself. Note what is NOT here: no thread table, no retry loop, no
// checkpoint bookkeeping. The durable runtime supplies all three.
// ---------------------------------------------------------------------------
const string Instructions = """
    You fulfil customer orders for a hardware retailer.

    Use the supplied tools rather than guessing. Never invent stock levels, order ids
    or booking references. If free stock is lower than the order quantity, say so
    plainly and do not attempt to reserve anything.

    When you are asked for a structured result, return only that structure.
    """;

AIAgent agent = new AIProjectClient(new Uri(foundryEndpoint), new DefaultAzureCredential())
    .AsAIAgent(
        model: modelDeployment,
        instructions: Instructions,
        name: FulfilmentOrchestration.AgentName,
        tools:
        [
            AIFunctionFactory.Create(
                agentTools.LookupOrderAsync,
                "lookup_order",
                "Look up a single customer order by its id."),
            AIFunctionFactory.Create(
                agentTools.CheckInventoryAsync,
                "check_inventory",
                "Return on hand, reserved and available stock for a SKU."),
            AIFunctionFactory.Create(
                agentTools.ArrangeDeliveryAsync,
                "arrange_delivery",
                "Book a delivery slot for an order and return the booking reference.")
        ]);

// reserve_stock and notify_customer are deliberately absent from the model's tool set.
// Both change state the customer can see, so the orchestrator calls them as activities
// where the durable runtime guarantees exactly once. Giving the model a tool that spends
// money and then hoping it calls it once is how you get double bookings.

builder.ConfigureDurableAgents(options => options.AddAIAgent(agent));

// Also register the plain agent so TestAgent can call the model without any durable
// machinery in the way. When an orchestration hangs, the first question is whether the model
// call works at all, and this answers it in one request instead of by inference.
builder.Services.AddSingleton(agent);

builder.Build().Run();
