using System.Net;
using System.Net.Http.Json;

namespace Orders.Tools.Core;

/// <summary>
/// A typed client over the action layer, shared by options 2 and 3.
///
/// This is a typed HTTP client over the SAME Orders.Tools app that Foundry reaches over MCP.
/// The handlers are identical; only the binding differs. docs/verification.md records why this
/// repo takes the HTTP route for options 2 and 3 rather than the MCP transport.
///
/// Every method throws on an unexpected status. The first version returned null instead, and
/// that cost an afternoon: when the function key went missing, every call quietly returned 401,
/// the client turned that into null, the agent reported "order could not be found", and the
/// notification activity did nothing and reported success. A failed call must look like a
/// failed call, especially inside a durable activity where the runtime is willing to retry it.
/// </summary>
public sealed class ToolLayerClient
{
    private readonly HttpClient _http;

    public ToolLayerClient(HttpClient http) => _http = http;

    private static async Task ThrowIfUnexpected(HttpResponseMessage res, string what)
    {
        if (res.IsSuccessStatusCode) { return; }

        var body = await res.Content.ReadAsStringAsync();
        var hint = res.StatusCode switch
        {
            HttpStatusCode.Unauthorized or HttpStatusCode.Forbidden =>
                " The action layer rejected the credential. TOOL_LAYER_KEY is missing or stale: " +
                "azd provision rewrites app settings from the Bicep, so re-run the postprovision hook.",
            _ => string.Empty
        };

        throw new HttpRequestException(
            $"{what} failed with {(int)res.StatusCode} {res.StatusCode}.{hint} Body: {body}");
    }

    public async Task<Order?> LookupOrderAsync(string orderId, CancellationToken ct = default)
    {
        var res = await _http.GetAsync($"api/tools/orders/{orderId}", ct);

        // 404 is a real answer here: the order genuinely does not exist.
        if (res.StatusCode == HttpStatusCode.NotFound) { return null; }

        await ThrowIfUnexpected(res, $"lookup_order({orderId})");
        return await res.Content.ReadFromJsonAsync<Order>(cancellationToken: ct);
    }

    public async Task<InventoryLevel?> CheckInventoryAsync(string sku, CancellationToken ct = default)
    {
        var res = await _http.GetAsync($"api/tools/inventory/{sku}", ct);
        await ThrowIfUnexpected(res, $"check_inventory({sku})");
        return await res.Content.ReadFromJsonAsync<InventoryLevel>(cancellationToken: ct);
    }

    public async Task<ReservationResult> ReserveStockAsync(
        string sku, int quantity, string reservationKey, CancellationToken ct = default)
    {
        var res = await _http.PostAsJsonAsync(
            "api/tools/reservations", new { sku, quantity, reservationKey }, ct);

        // 409 means not enough free stock. That is an answer, not a transport failure.
        if (res.StatusCode != HttpStatusCode.Conflict)
        {
            await ThrowIfUnexpected(res, $"reserve_stock({sku})");
        }

        return await res.Content.ReadFromJsonAsync<ReservationResult>(cancellationToken: ct)
            ?? new ReservationResult(null, false, "The action layer returned no body.");
    }

    public async Task<DeliveryBooking?> ArrangeDeliveryAsync(
        string orderId, string slot, CancellationToken ct = default)
    {
        var res = await _http.PostAsJsonAsync("api/tools/deliveries", new { orderId, slot }, ct);

        if (res.StatusCode == HttpStatusCode.NotFound) { return null; }

        await ThrowIfUnexpected(res, $"arrange_delivery({orderId})");
        return await res.Content.ReadFromJsonAsync<DeliveryBooking>(cancellationToken: ct);
    }

    public async Task<Notification> NotifyCustomerAsync(
        string orderId, string message, CancellationToken ct = default)
    {
        var res = await _http.PostAsJsonAsync(
            "api/tools/notifications", new { orderId, message }, ct);

        await ThrowIfUnexpected(res, $"notify_customer({orderId})");

        return await res.Content.ReadFromJsonAsync<Notification>(cancellationToken: ct)
            ?? throw new HttpRequestException("notify_customer returned no body.");
    }
}
