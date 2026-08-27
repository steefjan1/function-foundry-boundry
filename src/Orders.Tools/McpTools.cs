using System.Text.Json;
using Microsoft.Azure.Functions.Worker;
using Microsoft.Azure.Functions.Worker.Extensions.Mcp;
using Microsoft.Extensions.Logging;
using Orders.Tools.Core;

namespace Orders.Tools;

/// <summary>
/// The MCP face of the action layer.
///
/// Every method here is a two line wrapper: bind the arguments, call <see cref="OrderTools"/>,
/// serialise the result. When the orchestration substrate changes, this file does not.
/// Foundry reaches these over https://{app}.azurewebsites.net/runtime/webhooks/mcp.
/// </summary>
public class McpTools
{
    private readonly OrderTools _tools;
    private readonly ILogger<McpTools> _log;

    private static readonly JsonSerializerOptions Json = new(JsonSerializerDefaults.Web);

    public McpTools(OrderTools tools, ILogger<McpTools> log)
    {
        _tools = tools;
        _log = log;
    }

    [Function(nameof(LookupOrder))]
    public string LookupOrder(
        [McpToolTrigger("lookup_order", "Look up a single customer order by its id.")]
            ToolInvocationContext context,
        [McpToolProperty("orderId", "The order id, for example ORD-1001.", isRequired: true)]
            string orderId)
    {
        _log.LogInformation("lookup_order {OrderId}", orderId);
        var order = _tools.LookupOrder(orderId);
        return order is null
            ? JsonSerializer.Serialize(new { error = $"Unknown order '{orderId}'." }, Json)
            : JsonSerializer.Serialize(order, Json);
    }

    [Function(nameof(CheckInventory))]
    public string CheckInventory(
        [McpToolTrigger("check_inventory", "Return on hand, reserved and available stock for a SKU.")]
            ToolInvocationContext context,
        [McpToolProperty("sku", "The stock keeping unit, for example SKU-KEYBOARD.", isRequired: true)]
            string sku)
    {
        _log.LogInformation("check_inventory {Sku}", sku);
        return JsonSerializer.Serialize(_tools.CheckInventory(sku), Json);
    }

    [Function(nameof(ReserveStock))]
    public string ReserveStock(
        [McpToolTrigger("reserve_stock",
            "Hold stock for an order. Idempotent: the same reservation key never holds stock twice.")]
            ToolInvocationContext context,
        [McpToolProperty("sku", "The stock keeping unit to hold.", isRequired: true)] string sku,
        [McpToolProperty("quantity", "How many units to hold.", isRequired: true)] int quantity,
        [McpToolProperty("reservationKey",
            "A stable key derived from the order, not from the run. Reusing it is safe.",
            isRequired: true)] string reservationKey)
    {
        _log.LogInformation("reserve_stock {Sku} x{Quantity} key {Key}", sku, quantity, reservationKey);
        return JsonSerializer.Serialize(_tools.ReserveStock(sku, quantity, reservationKey), Json);
    }

    [Function(nameof(ArrangeDelivery))]
    public string ArrangeDelivery(
        [McpToolTrigger("arrange_delivery", "Book a delivery slot for an order.")]
            ToolInvocationContext context,
        [McpToolProperty("orderId", "The order id to book against.", isRequired: true)] string orderId,
        [McpToolProperty("slot", "A slot label, for example 2026-09-02-AM.", isRequired: true)] string slot)
    {
        _log.LogInformation("arrange_delivery {OrderId} {Slot}", orderId, slot);
        try
        {
            return JsonSerializer.Serialize(_tools.ArrangeDelivery(orderId, slot), Json);
        }
        catch (KeyNotFoundException ex)
        {
            return JsonSerializer.Serialize(new { error = ex.Message }, Json);
        }
    }

    [Function(nameof(NotifyCustomer))]
    public string NotifyCustomer(
        [McpToolTrigger("notify_customer", "Send the customer a message about their order.")]
            ToolInvocationContext context,
        [McpToolProperty("orderId", "The order the message concerns.", isRequired: true)] string orderId,
        [McpToolProperty("message", "What to tell the customer.", isRequired: true)] string message)
    {
        _log.LogInformation("notify_customer {OrderId}", orderId);
        return JsonSerializer.Serialize(_tools.NotifyCustomer(orderId, message), Json);
    }
}
