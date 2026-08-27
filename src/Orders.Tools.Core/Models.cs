using System.Text.Json.Serialization;

namespace Orders.Tools.Core;

public record Order(
    [property: JsonPropertyName("orderId")] string OrderId,
    [property: JsonPropertyName("customer")] string Customer,
    [property: JsonPropertyName("sku")] string Sku,
    [property: JsonPropertyName("quantity")] int Quantity,
    [property: JsonPropertyName("status")] string Status);

public record InventoryLevel(
    [property: JsonPropertyName("sku")] string Sku,
    [property: JsonPropertyName("onHand")] int OnHand,
    [property: JsonPropertyName("reserved")] int Reserved,
    [property: JsonPropertyName("available")] int Available);

public enum ReservationStatus
{
    Held,
    Released
}

public record Reservation(
    [property: JsonPropertyName("reservationKey")] string ReservationKey,
    [property: JsonPropertyName("sku")] string Sku,
    [property: JsonPropertyName("quantity")] int Quantity,
    [property: JsonPropertyName("status")] ReservationStatus Status);

public record ReservationResult(
    [property: JsonPropertyName("reservation")] Reservation? Reservation,
    [property: JsonPropertyName("created")] bool Created,
    [property: JsonPropertyName("detail")] string Detail);

public record DeliveryBooking(
    [property: JsonPropertyName("orderId")] string OrderId,
    [property: JsonPropertyName("slot")] string Slot,
    [property: JsonPropertyName("bookingReference")] string BookingReference);

public record Notification(
    [property: JsonPropertyName("orderId")] string OrderId,
    [property: JsonPropertyName("message")] string Message,
    [property: JsonPropertyName("sequence")] int Sequence);

/// <summary>The shape the durable agent asks the model to produce, and the shape the smoke tests assert on.</summary>
public record FulfilmentOutcome(
    [property: JsonPropertyName("orderId")] string OrderId,
    [property: JsonPropertyName("fulfilled")] bool Fulfilled,
    [property: JsonPropertyName("reservationKey")] string? ReservationKey,
    [property: JsonPropertyName("bookingReference")] string? BookingReference,
    [property: JsonPropertyName("reason")] string Reason);
