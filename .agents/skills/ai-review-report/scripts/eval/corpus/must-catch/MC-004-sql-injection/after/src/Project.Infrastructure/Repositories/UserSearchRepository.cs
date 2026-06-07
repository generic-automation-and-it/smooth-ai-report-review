using System.Collections.Generic;
using System.Threading;
using System.Threading.Tasks;
using Microsoft.EntityFrameworkCore;

namespace Project.Infrastructure.Repositories;

public sealed class UserSearchRepository
{
    private readonly AppDbContext _db;

    public UserSearchRepository(AppDbContext db) => _db = db;

    /// <summary>
    /// Returns users whose display name matches the caller-supplied search term.
    /// </summary>
    public async Task<List<User>> FindByNameAsync(string name, CancellationToken ct = default)
    {
        // Caller-controlled 'name' is interpolated directly into the SQL string.
        // ExecuteSqlRaw does NOT treat an interpolated string as parameterized —
        // it receives the fully-expanded string, so a value like
        //   ' OR '1'='1
        // will cause the query to return every row, and more complex payloads
        // can execute arbitrary statements (DROP TABLE, xp_cmdshell, etc.).
        // Fix: use FromSqlInterpolated, or pass name as a SqlParameter.
        var sql = $"SELECT * FROM Users WHERE DisplayName = '{name}'";
        return await _db.Users
            .FromSqlRaw(sql)
            .ToListAsync(ct);
    }
}
