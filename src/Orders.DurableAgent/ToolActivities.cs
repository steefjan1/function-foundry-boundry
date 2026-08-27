using Microsoft.Azure.Functions.Worker;
using Microsoft.Extensions.Logging;
using Orders.Tools.Core;

namespace Orders.DurableAgent;

/// <summary>
/// Durable activities. Everything with a side effect the customer can observe runs here rather
/// than inside an agent turn, so the durable runtime commits it exactly once.
/// </summary>
public class ToolActivities
{
    private readonly ToolLayerClient _tools;
    private readonly ILogger<ToolActivities> _log;

    public ToolActivities(ToolLayerClient tools, ILogger<ToolActivities> log)
    {
        _tools = tools;
        _log = log;
    }

    [Function(nameof(LookupOrder))]
    public async Task<Order?> LookupOrder([ActivityTrigger] string orderId)
    {
        _log.LogInformation("Looking up {OrderId}", orderId);
        return await _tools.LookupOrderAsync(orderId);
    }

    [Function(nameof(ReserveStock))]
    public async Task<ReservationResult> ReserveStock([ActivityTrigger] ReserveArgs args)
    {
        _log.LogInformation("Reserving {Quantity} x {Sku} under {Key}",
            args.Quantity, args.Sku, args.ReservationKey);

        return await _tools.ReserveStockAsync(args.Sku, args.Quantity, args.ReservationKey);
    }

    [Function(nameof(NotifyCustomer))]
    public async Task<Notification> NotifyCustomer([ActivityTrigger] NotifyArgs args)
    {
        _log.LogInformation("Notifying customer for {OrderId}", args.OrderId);
        return await _tools.NotifyCustomerAsync(args.OrderId, args.Message);
    }
}
