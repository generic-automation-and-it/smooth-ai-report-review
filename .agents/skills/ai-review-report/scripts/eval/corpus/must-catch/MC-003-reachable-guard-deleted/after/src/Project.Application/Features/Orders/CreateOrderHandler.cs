using System;
using System.Threading;
using System.Threading.Tasks;

namespace Project.Application.Features.Orders;

public sealed record CreateOrderRequest(CustomerInfo? Customer, IReadOnlyList<OrderLineItem> Lines);

public sealed class CreateOrderHandler
{
    private readonly AppDbContext _db;

    public CreateOrderHandler(AppDbContext db) => _db = db;

    public async Task<Guid> Handle(CreateOrderRequest request, CancellationToken ct)
    {
        // Guard removed during refactor — Customer is still nullable and still
        // dereferenced below, so callers that omit it will get NullReferenceException.
        var order = new Order
        {
            Id = Guid.NewGuid(),
            CustomerId = request.Customer.Id,   // NRE if Customer is null
            Lines = request.Lines.Select(l => new OrderLine(l.ProductId, l.Quantity)).ToList(),
            CreatedAt = DateTime.UtcNow,
        };

        _db.Orders.Add(order);
        await _db.SaveChangesAsync(ct);

        return order.Id;
    }
}
