using Microsoft.Extensions.Options;

namespace Project.Infrastructure.Tenancy;

/// <summary>
/// Resolves the PostgreSQL connection string for the current tenant.
/// Tenants are isolated by database — see LADR-10 in Tenancy_AGENTS.md.
/// There is intentionally no discriminator column; each tenant gets its own
/// database instance addressed by its connection string.
/// </summary>
internal sealed class TenantConnectionResolver(
    ITenantContext tenantContext,
    IOptionsSnapshot<TenantConnectionOptions> options)
{
    public string Resolve()
    {
        var tenantId = tenantContext.TenantId
            ?? throw new InvalidOperationException("No tenant context is set for this request.");

        if (!options.Value.ConnectionStrings.TryGetValue(tenantId, out var connectionString))
        {
            throw new UnknownTenantException(tenantId);
        }

        return connectionString;
    }
}
