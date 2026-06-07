using System.Threading;
using System.Threading.Tasks;
using Microsoft.EntityFrameworkCore;

namespace Project.Application.Features.Vessels;

public sealed class GetVesselDashboardHandler
{
    private readonly AppDbContext _db;

    public GetVesselDashboardHandler(AppDbContext db) => _db = db;

    public async Task<VesselDashboard> Handle(GetVesselDashboard request, CancellationToken ct)
    {
        // BUG: both queries are issued concurrently against the SAME DbContext
        // instance. EF Core's DbContext is not thread-safe — concurrent use
        // throws InvalidOperationException ("A second operation was started on
        // this context...") or corrupts the change tracker.
        var voyagesTask = _db.Voyages
            .Where(v => v.VesselId == request.VesselId)
            .ToListAsync(ct);

        var claimsTask = _db.Claims
            .Where(c => c.VesselId == request.VesselId)
            .ToListAsync(ct);

        await Task.WhenAll(voyagesTask, claimsTask);

        return new VesselDashboard(voyagesTask.Result, claimsTask.Result);
    }
}
