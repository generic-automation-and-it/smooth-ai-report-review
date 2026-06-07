using System.Linq;
using Microsoft.EntityFrameworkCore;

namespace Project.Infrastructure.Repositories;

public sealed class VoyageQueryRepository
{
    private readonly AppDbContext _db;

    public VoyageQueryRepository(AppDbContext db) => _db = db;

    // Returns an IQueryable projection. The lambda is compiled into an EF Core
    // expression tree and translated to SQL (LEFT JOINs with NULL propagation) —
    // it is NOT executed as runtime C#, so accessing v.Vessel.Name and
    // v.Charterer.Company.Name cannot throw a NullReferenceException here.
    // DO NOT add ?. on these navigation properties.
    public IQueryable<VoyageListItem> GetVoyageList()
    {
        return _db.Voyages
            .Where(v => !v.IsArchived)
            .OrderByDescending(v => v.DepartureUtc)
            .Select(v => new VoyageListItem
            {
                VoyageId = v.Id,
                VesselName = v.Vessel.Name,
                ChartererCompany = v.Charterer.Company.Name,
                DepartureUtc = v.DepartureUtc
            });
    }
}
