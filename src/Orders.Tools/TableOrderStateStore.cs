using Azure;
using Azure.Data.Tables;
using Azure.Identity;
using Orders.Tools.Core;

namespace Orders.Tools;

/// <summary>
/// Azure Table Storage backing for the action layer's mutable state.
///
/// Uses the same managed identity and storage account as AzureWebJobsStorage, so it needs no
/// extra configuration and no secrets. The Storage Table Data Contributor role that Durable
/// Functions already required covers it.
///
/// The reservation insert is the important part. Table Storage rejects a duplicate row key
/// with 409 Conflict, which gives atomic insert-if-absent across every instance for free.
/// That is a stronger idempotency guarantee than a lock in one process, and it is the reason
/// this class exists rather than a distributed cache.
/// </summary>
public sealed class TableOrderStateStore : IOrderStateStore
{
    private const string ReservationsTable = "reservations";
    private const string DeliveriesTable = "deliveries";
    private const string NotificationsTable = "notifications";
    internal const string OrdersPartition = "orders";

    private readonly TableClient _reservations;
    private readonly TableClient _deliveries;
    private readonly TableClient _notifications;

    public TableOrderStateStore(string accountName)
    {
        var uri = new Uri($"https://{accountName}.table.core.windows.net");
        var credential = new DefaultAzureCredential();

        var service = new TableServiceClient(uri, credential);

        _reservations = service.GetTableClient(ReservationsTable);
        _deliveries = service.GetTableClient(DeliveriesTable);
        _notifications = service.GetTableClient(NotificationsTable);

        _reservations.CreateIfNotExists();
        _deliveries.CreateIfNotExists();
        _notifications.CreateIfNotExists();
    }

    // --- reservations --------------------------------------------------------


    public Reservation? GetReservation(string reservationKey)
    {
        try
        {
            var entity = _reservations.GetEntity<ReservationEntity>(OrdersPartition, reservationKey);
            return entity.Value.ToReservation();
        }
        catch (RequestFailedException ex) when (ex.Status == 404)
        {
            return null;
        }
    }

    public (Reservation Reservation, bool Created) AddOrGetReservation(Reservation reservation)
    {
        var entity = new ReservationEntity
        {
            RowKey = reservation.ReservationKey,
            Sku = reservation.Sku,
            Quantity = reservation.Quantity,
            Status = reservation.Status.ToString()
        };

        try
        {
            _reservations.AddEntity(entity);
            return (reservation, true);
        }
        catch (RequestFailedException ex) when (ex.Status == 409)
        {
            // Someone else inserted this key first. Their row wins, and the caller is told
            // it did not create anything. This is the race the whole sample turns on.
            var existing = GetReservation(reservation.ReservationKey);
            return (existing ?? reservation, false);
        }
    }

    public IReadOnlyCollection<Reservation> ReservationsForSku(string sku)
        => _reservations
            .Query<ReservationEntity>(e => e.PartitionKey == OrdersPartition && e.Sku == sku)
            .Select(e => e.ToReservation())
            .Where(r => r.Status == ReservationStatus.Held)
            .ToList();

    // --- deliveries ----------------------------------------------------------


    public void AddDelivery(DeliveryBooking booking)
        => _deliveries.UpsertEntity(new DeliveryEntity
        {
            RowKey = booking.OrderId,
            Slot = booking.Slot,
            BookingReference = booking.BookingReference
        });

    // --- notifications -------------------------------------------------------


    public Notification AddNotification(string orderId, string message)
    {
        var existing = NotificationsFor(orderId);
        var sequence = existing.Count + 1;

        // Row key sorts by sequence so reads come back in order without a sort.
        _notifications.AddEntity(new NotificationEntity
        {
            PartitionKey = orderId,
            RowKey = sequence.ToString("D6") + "-" + Guid.NewGuid().ToString("N")[..8],
            Message = message,
            Sequence = sequence
        });

        return new Notification(orderId, message, sequence);
    }

    public IReadOnlyCollection<Notification> NotificationsFor(string orderId)
        => _notifications
            .Query<NotificationEntity>(e => e.PartitionKey == orderId)
            .Select(e => new Notification(e.PartitionKey, e.Message, e.Sequence))
            .OrderBy(n => n.Sequence)
            .ToList();
}

// Table entity types are PUBLIC and top level, not private nested classes.
//
// Azure.Data.Tables maps custom properties by reflection. With private nested types the
// query returns the right number of rows with every custom property left at its default,
// which looked exactly like a working store returning empty notifications.

public sealed class ReservationEntity : ITableEntity
{
    public string PartitionKey { get; set; } = TableOrderStateStore.OrdersPartition;
    public string RowKey { get; set; } = string.Empty;
    public DateTimeOffset? Timestamp { get; set; }
    public ETag ETag { get; set; }

    public string Sku { get; set; } = string.Empty;
    public int Quantity { get; set; }
    public string Status { get; set; } = nameof(ReservationStatus.Held);

    public Reservation ToReservation() => new(
        RowKey, Sku, Quantity, Enum.Parse<ReservationStatus>(Status));
}

public sealed class DeliveryEntity : ITableEntity
{
    public string PartitionKey { get; set; } = TableOrderStateStore.OrdersPartition;
    public string RowKey { get; set; } = string.Empty;
    public DateTimeOffset? Timestamp { get; set; }
    public ETag ETag { get; set; }

    public string Slot { get; set; } = string.Empty;
    public string BookingReference { get; set; } = string.Empty;
}

public sealed class NotificationEntity : ITableEntity
{
    public string PartitionKey { get; set; } = string.Empty;   // orderId
    public string RowKey { get; set; } = string.Empty;         // ordered id
    public DateTimeOffset? Timestamp { get; set; }
    public ETag ETag { get; set; }

    public string Message { get; set; } = string.Empty;
    public int Sequence { get; set; }
}
