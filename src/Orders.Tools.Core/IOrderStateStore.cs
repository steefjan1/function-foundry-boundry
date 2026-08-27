using System.Collections.Concurrent;

namespace Orders.Tools.Core;

/// <summary>
/// The mutable half of the action layer's state: reservations, deliveries and notifications.
///
/// This exists because of a failure that took a while to see. The first version kept
/// everything in a singleton dictionary, which is fine on one machine and wrong on Flex
/// Consumption, where the action layer scales to many instances. The durable agent wrote a
/// notification on one instance and the smoke test read from another, so the count came back
/// zero and the orchestration looked broken when it had done its job perfectly.
///
/// Orders and inventory stay in memory, because they are read only reference data seeded
/// identically on every instance. Anything a caller can change goes through here.
/// </summary>
public interface IOrderStateStore
{
    Reservation? GetReservation(string reservationKey);

    /// <summary>
    /// Insert a reservation if the key is unused, otherwise return the existing one.
    /// The bool is true when this call created it. Implementations must make this atomic:
    /// it is the whole idempotency guarantee, and every substrate above depends on it.
    /// </summary>
    (Reservation Reservation, bool Created) AddOrGetReservation(Reservation reservation);

    IReadOnlyCollection<Reservation> ReservationsForSku(string sku);

    void AddDelivery(DeliveryBooking booking);

    Notification AddNotification(string orderId, string message);

    IReadOnlyCollection<Notification> NotificationsFor(string orderId);
}

/// <summary>
/// In-memory implementation, for unit tests and local runs only.
/// Correct on exactly one instance, which is why the deployed app does not use it.
/// </summary>
public sealed class InMemoryOrderStateStore : IOrderStateStore
{
    private readonly object _lock = new();
    private readonly ConcurrentDictionary<string, Reservation> _reservations = new();
    private readonly ConcurrentDictionary<string, DeliveryBooking> _deliveries = new();
    private readonly ConcurrentBag<Notification> _notifications = new();
    private int _sequence;

    public Reservation? GetReservation(string reservationKey)
        => _reservations.TryGetValue(reservationKey, out var r) ? r : null;

    public (Reservation Reservation, bool Created) AddOrGetReservation(Reservation reservation)
    {
        lock (_lock)
        {
            if (_reservations.TryGetValue(reservation.ReservationKey, out var existing))
            {
                return (existing, false);
            }

            _reservations[reservation.ReservationKey] = reservation;
            return (reservation, true);
        }
    }

    public IReadOnlyCollection<Reservation> ReservationsForSku(string sku)
        => _reservations.Values.Where(r => r.Sku == sku && r.Status == ReservationStatus.Held).ToList();

    public void AddDelivery(DeliveryBooking booking) => _deliveries[booking.OrderId] = booking;

    public Notification AddNotification(string orderId, string message)
    {
        var n = new Notification(orderId, message, Interlocked.Increment(ref _sequence));
        _notifications.Add(n);
        return n;
    }

    public IReadOnlyCollection<Notification> NotificationsFor(string orderId)
        => _notifications.Where(n => n.OrderId == orderId).OrderBy(n => n.Sequence).ToList();
}

/// <summary>Read only reference data. Identical on every instance, so it stays in memory.</summary>
public static class OrderCatalogue
{
    public static readonly IReadOnlyDictionary<string, Order> Orders = new Dictionary<string, Order>
    {
        ["ORD-1001"] = new("ORD-1001", "Ada Lovelace", "SKU-KEYBOARD", 2, "Pending"),
        ["ORD-1002"] = new("ORD-1002", "Grace Hopper", "SKU-MONITOR", 1, "Pending"),
        ["ORD-1003"] = new("ORD-1003", "Alan Turing", "SKU-DOCK", 5, "Pending"),
    };

    public static readonly IReadOnlyDictionary<string, int> Inventory = new Dictionary<string, int>
    {
        ["SKU-KEYBOARD"] = 12,
        ["SKU-MONITOR"] = 3,
        ["SKU-DOCK"] = 2,   // deliberately short of ORD-1003, so the unhappy path is reachable

        // Probe stock, for health checks and the smoke suite's idempotency test. Reservations
        // in this sample are held forever, so anything that reserves per-call drains whatever
        // SKU it touches. The health probe used SKU-KEYBOARD and, one unit per call, quietly
        // starved ORD-1001 until the durable agent started refusing a fulfillable order.
        // Probes now spend from this pile, and the narrative SKUs stay at their seeded levels.
        ["SKU-PROBE"] = 1_000_000,
    };
}
