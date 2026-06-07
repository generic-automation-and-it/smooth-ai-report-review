using System.Threading;
using System.Threading.Tasks;
using System.Collections.Generic;
using System.Linq;
using Microsoft.EntityFrameworkCore;

namespace Project.Application.Features.Orders;

public sealed record GetOrderSummary(Guid OrderId);

public sealed record OrderSummaryDto(string CustomerName, decimal TotalAmount);

public sealed class GetOrderSummaryHandler
{
    private readonly AppDbContext _db;

    public GetOrderSummaryHandler(AppDbContext db) => _db = db;

    public async Task<IReadOnlyList<OrderSummaryDto>> Handle(
        GetOrderSummary request, CancellationToken ct)
    {
        // Materialize first — no EF expression-tree restrictions below this line.
        var orders = await _db.Orders
            .Where(o => o.Id == request.OrderId)
            .ToListAsync(ct);

        // Customer is a navigation property that was NOT eagerly loaded (no Include).
        // EF sets it to null when lazy-loading is disabled (default in this project).
        // This will throw NullReferenceException at runtime whenever Customer is null.
        return orders
            .Select(o => new OrderSummaryDto(
                o.Customer.Name,        // NRE: Customer can be null
                o.TotalAmount))
            .ToList();
    }
}
