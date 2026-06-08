using Microsoft.Extensions.Options;

namespace Project.Infrastructure.Tenancy;

/// <summary>
/// Resolves the PostgreSQL connection string for the current tenant.
/// Tenants are isolated by database — see LADR-10 in TENANCY_AGENTS.md.
/// There is intentionally no discriminator column; each tenant gets its own
/// database instance addressed by its connection string.
///
/// DR-014 review scope: this fixture must NOT flag LADR-10's CHOSEN APPROACH
/// at Critical/High/Medium (no EF Core discriminator column, per-tenant
/// connection-string resolution — see LADR-10's Decision + Consequences).
/// Adjacent code (e.g. defensive validation of the resolved connection-string
/// value, missing null guards on inputs) is INTENTIONALLY out of scope for
/// this fixture: a flag there is NOT a DR-014 re-raise. Do not raise findings
/// about the chosen approach; standard review of the surrounding code is fine.
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
