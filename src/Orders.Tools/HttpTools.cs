using System.Net;
using Microsoft.Azure.Functions.Worker;
using Microsoft.Azure.Functions.Worker.Http;
using Orders.Tools.Core;

namespace Orders.Tools;

/// <summary>
/// The HTTP face of the same action layer.
///
/// Why two faces. Foundry consumes tools over MCP, which is the right binding when the
/// service is doing the calling. An in-process Agent Framework agent (options 2 and 3) can
/// consume MCP too, but it can equally call a typed HTTP endpoint and expose it to the model
/// as an AIFunction. Both routes land in the same <see cref="OrderTools"/> instance, which is
/// the claim the sample exists to demonstrate: the substrate above the boundary changes, and
/// nothing below it does.
///
/// See docs/verification.md for why option 2 in this repo takes the HTTP route.
/// </summary>
public class HttpTools
{
    private readonly OrderTools _tools;

    public HttpTools(OrderTools tools) => _tools = tools;

    [Function("http_lookup_order")]
    public async Task<HttpResponseData> LookupOrder(
        [HttpTrigger(AuthorizationLevel.Function, "get", Route = "tools/orders/{orderId}")]
            HttpRequestData req,
        string orderId)
    {
        var order = _tools.LookupOrder(orderId);
        if (order is null)
        {
            var missing = req.CreateResponse(HttpStatusCode.NotFound);
            await missing.WriteAsJsonAsync(new { error = $"Unknown order '{orderId}'." });
            return missing;
        }

        var res = req.CreateResponse(HttpStatusCode.OK);
        await res.WriteAsJsonAsync(order);
        return res;
    }

    [Function("http_check_inventory")]
    public async Task<HttpResponseData> CheckInventory(
        [HttpTrigger(AuthorizationLevel.Function, "get", Route = "tools/inventory/{sku}")]
            HttpRequestData req,
        string sku)
    {
        var res = req.CreateResponse(HttpStatusCode.OK);
        await res.WriteAsJsonAsync(_tools.CheckInventory(sku));
        return res;
    }

    public record ReserveRequest(string Sku, int Quantity, string ReservationKey);

    [Function("http_reserve_stock")]
    public async Task<HttpResponseData> ReserveStock(
        [HttpTrigger(AuthorizationLevel.Function, "post", Route = "tools/reservations")]
            HttpRequestData req)
    {
        var body = await req.ReadFromJsonAsync<ReserveRequest>();
        if (body is null)
        {
            var bad = req.CreateResponse(HttpStatusCode.BadRequest);
            await bad.WriteAsJsonAsync(new { error = "A JSON body is required." });
            return bad;
        }

        var result = _tools.ReserveStock(body.Sku, body.Quantity, body.ReservationKey);

        // 201 on a genuinely new reservation, 200 on a replay. The smoke test asserts on this,
        // because it is the cheapest observable proof that the idempotency key did its job.
        var res = req.CreateResponse(
            result.Reservation is null ? HttpStatusCode.Conflict
            : result.Created ? HttpStatusCode.Created
            : HttpStatusCode.OK);

        await res.WriteAsJsonAsync(result);
        return res;
    }

    public record DeliveryRequest(string OrderId, string Slot);

    [Function("http_arrange_delivery")]
    public async Task<HttpResponseData> ArrangeDelivery(
        [HttpTrigger(AuthorizationLevel.Function, "post", Route = "tools/deliveries")]
            HttpRequestData req)
    {
        var body = await req.ReadFromJsonAsync<DeliveryRequest>();
        if (body is null)
        {
            var bad = req.CreateResponse(HttpStatusCode.BadRequest);
            await bad.WriteAsJsonAsync(new { error = "A JSON body is required." });
            return bad;
        }

        try
        {
            var res = req.CreateResponse(HttpStatusCode.Created);
            await res.WriteAsJsonAsync(_tools.ArrangeDelivery(body.OrderId, body.Slot));
            return res;
        }
        catch (KeyNotFoundException ex)
        {
            var missing = req.CreateResponse(HttpStatusCode.NotFound);
            await missing.WriteAsJsonAsync(new { error = ex.Message });
            return missing;
        }
    }

    public record NotifyRequest(string OrderId, string Message);

    [Function("http_notify_customer")]
    public async Task<HttpResponseData> NotifyCustomer(
        [HttpTrigger(AuthorizationLevel.Function, "post", Route = "tools/notifications")]
            HttpRequestData req)
    {
        var body = await req.ReadFromJsonAsync<NotifyRequest>();
        if (body is null)
        {
            var bad = req.CreateResponse(HttpStatusCode.BadRequest);
            await bad.WriteAsJsonAsync(new { error = "A JSON body is required." });
            return bad;
        }

        var res = req.CreateResponse(HttpStatusCode.Created);
        await res.WriteAsJsonAsync(_tools.NotifyCustomer(body.OrderId, body.Message));
        return res;
    }

    /// <summary>
    /// Reports which state store is live and whether it can actually round trip a write.
    ///
    /// Exists because an empty store and a working store are indistinguishable from the
    /// outside: both answer 200, both return [], and every smoke test passes. This endpoint
    /// makes the difference visible in one request.
    /// </summary>
    [Function("http_health")]
    public async Task<HttpResponseData> Health(
        [HttpTrigger(AuthorizationLevel.Function, "get", Route = "tools/health")]
            HttpRequestData req,
        FunctionContext ctx)
    {
        var store = ctx.InstanceServices.GetService(typeof(IOrderStateStore));
        var storeName = store?.GetType().Name ?? "none";

        // Round trip a probe so "configured" and "working" are not confused.
        string roundTrip;
        try
        {
            // SKU-PROBE, never a narrative SKU. Reservations are held forever in this sample,
            // so a probe that spends real stock starves the orders the demo is about, one
            // health check at a time. It did: ORD-1001 became unfulfillable after an
            // afternoon of diagnostics, each of which called this endpoint once.
            var probeKey = $"health-{Guid.NewGuid():N}";
            var first = _tools.ReserveStock("SKU-PROBE", 1, probeKey);
            var replay = _tools.ReserveStock("SKU-PROBE", 1, probeKey);

            roundTrip = first.Created && !replay.Created
                ? "ok: write then replay behaved idempotently"
                : $"SUSPECT: created={first.Created} then created={replay.Created}";
        }
        catch (Exception ex)
        {
            roundTrip = $"FAILED: {ex.GetType().Name}: {ex.Message}";
        }

        var res = req.CreateResponse(HttpStatusCode.OK);
        await res.WriteAsJsonAsync(new
        {
            stateStore = storeName,
            persistent = storeName == "TableOrderStateStore",
            roundTrip,
            warning = storeName == "InMemoryOrderStateStore"
                ? "In-memory store: state does not persist and is not shared across instances."
                : null
        });
        return res;
    }

    /// <summary>Smoke test hook. Counts notifications so a test can prove one, and only one, was sent.</summary>
    [Function("http_notifications_for")]
    public async Task<HttpResponseData> NotificationsFor(
        [HttpTrigger(AuthorizationLevel.Function, "get", Route = "tools/notifications/{orderId}")]
            HttpRequestData req,
        string orderId)
    {
        var res = req.CreateResponse(HttpStatusCode.OK);
        await res.WriteAsJsonAsync(_tools.NotificationsFor(orderId));
        return res;
    }
}
