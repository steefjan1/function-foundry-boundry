namespace Orders.Tools.Core;

/// <summary>
/// The action layer. Five discrete, testable operations over order fulfilment.
///
/// Nothing in this file knows which orchestration substrate is calling it. That is the
/// point of the sample: the same class is bound to MCP tool triggers for Foundry to call,
/// to HTTP triggers for a durable agent to call, and is unit tested with neither.
/// </summary>
public sealed class OrderTools
{
    private readonly IOrderStateStore _state;

    public OrderTools(IOrderStateStore state) => _state = state;

    /// <summary>Return a single order, or null when the id is unknown.</summary>
    public Order? LookupOrder(string orderId)
        => OrderCatalogue.Orders.TryGetValue(orderId, out var order) ? order : null;

    /// <summary>Return free stock for a SKU. Free stock is on hand minus everything reserved.</summary>
    public InventoryLevel CheckInventory(string sku)
    {
        var onHand = OrderCatalogue.Inventory.TryGetValue(sku, out var qty) ? qty : 0;
        var reserved = _state.ReservationsForSku(sku).Sum(r => r.Quantity);

        return new InventoryLevel(sku, onHand, reserved, Math.Max(0, onHand - reserved));
    }

    /// <summary>
    /// Reserve stock. Idempotent on <paramref name="reservationKey"/>: calling twice with the
    /// same key returns the first reservation rather than holding stock twice.
    ///
    /// The key is a deliberate part of the demo. An agent that retries a tool call, or a
    /// substrate that replays an orchestration, must not double book. Substrates differ in
    /// how likely that is, so the action layer refuses to care and enforces it itself.
    /// </summary>
    public ReservationResult ReserveStock(string sku, int quantity, string reservationKey)
    {
        if (quantity <= 0)
        {
            return new ReservationResult(null, false, "Quantity must be greater than zero.");
        }

        if (string.IsNullOrWhiteSpace(reservationKey))
        {
            return new ReservationResult(null, false, "A reservation key is required.");
        }

        // Check the key first. A replay must return the original reservation even when stock
        // has since run out, otherwise a retry of a successful call reports failure.
        var existing = _state.GetReservation(reservationKey);
        if (existing is not null)
        {
            return new ReservationResult(existing, false, "Replayed an existing reservation.");
        }

        var level = CheckInventory(sku);
        if (level.Available < quantity)
        {
            return new ReservationResult(
                null, false, $"Only {level.Available} unit(s) of {sku} are available.");
        }

        var (reservation, created) = _state.AddOrGetReservation(
            new Reservation(reservationKey, sku, quantity, ReservationStatus.Held));

        return new ReservationResult(
            reservation,
            created,
            created ? "Reservation held." : "Replayed an existing reservation.");
    }

    /// <summary>Book a delivery slot against an order.</summary>
    public DeliveryBooking ArrangeDelivery(string orderId, string slot)
    {
        var order = LookupOrder(orderId)
            ?? throw new KeyNotFoundException($"Unknown order '{orderId}'.");

        var booking = new DeliveryBooking(orderId, slot, $"DLV-{order.OrderId}-{slot}");
        _state.AddDelivery(booking);
        return booking;
    }

    /// <summary>
    /// Record a customer notification. This is the one tool with a side effect the customer
    /// can see, so the smoke tests assert it fires exactly once per fulfilled order.
    /// </summary>
    public Notification NotifyCustomer(string orderId, string message)
        => _state.AddNotification(orderId, message);

    /// <summary>Test and smoke-test hook. Not exposed as a tool.</summary>
    public IReadOnlyCollection<Notification> NotificationsFor(string orderId)
        => _state.NotificationsFor(orderId);
}
