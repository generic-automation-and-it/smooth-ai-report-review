using System.Threading;
using System.Threading.Tasks;
using Microsoft.EntityFrameworkCore;

namespace Project.Application.Features.Vessels;

// Handler that loads several aggregates for a vessel summary. Queries run
// sequentially on the single injected DbContext — the correct default pattern
// (DbContext is not thread-safe). DO NOT suggest Task.WhenAll here.
public sealed class GetVesselSummaryHandler
{
    private readonly AppDbContext _db;

    public GetVesselSummaryHandler(AppDbContext db) => _db = db;

    public async Task<VesselSummary> Handle(GetVesselSummary request, CancellationToken ct)
    {
        var vessel = await _db.Vessels
            .FirstAsync(v => v.Id == request.VesselId, ct);

        var voyages = await _db.Voyages
            .Where(v => v.VesselId == request.VesselId)
            .OrderByDescending(v => v.DepartureUtc)
            .Take(10)
            .ToListAsync(ct);

        var openClaims = await _db.Claims
            .CountAsync(c => c.VesselId == request.VesselId && !c.IsClosed, ct);

        return new VesselSummary(vessel.Name, voyages.Count, openClaims);
    }
}
