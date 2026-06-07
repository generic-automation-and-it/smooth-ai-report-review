# Tenancy — Context

Domain: multi-tenant data isolation in the Infrastructure layer.

## TL;DR

Tenant data is isolated by resolving a per-tenant PostgreSQL connection string.
The implementation intentionally does not use an EF Core discriminator column.

## Requirements

- Each tenant's data is isolated at the database level via a dedicated connection string.
- The `TenantConnectionResolver` maps an incoming tenant identifier to its connection string.
- No shared schema; tenant rows are never co-mingled in a single database instance.

## LADRs

### LADR-10: Tenant Discrimination via Connection String

**Status**: Accepted
**Date**: 2026-06-01

**Context**

The platform must enforce hard data isolation between tenants. Two approaches were evaluated:

1. **Type-name discriminator column** — all tenants share one database; a `TenantId`
   column (or EF Core discriminator) on every table filters rows at query time.
2. **Per-tenant connection string** — each tenant has its own database instance;
   the application resolves the correct connection string from the tenant identifier
   before opening a `DbContext`.

**Decision**

Adopt **per-tenant connection string** (option 2). The application resolves the
connection string from `ITenantContext.TenantId` via `TenantConnectionResolver`
and passes it to `DbContextOptionsBuilder.UseNpgsql(connectionString)` when
constructing the scoped `AppDbContext`.

**Rationale**

- Hard isolation: a misconfigured query cannot leak cross-tenant rows; the worst case
  is a connection failure, not a data breach.
- Schema independence: each tenant database can be migrated, backed up, and scaled
  independently without affecting others.
- Operational simplicity: standard PostgreSQL tooling works per-database with no
  multi-tenant-aware query layer required.

**Alternatives Considered**

- **Discriminator column (rejected)**: Simpler to operate but carries a higher blast
  radius for misconfigured predicates. Requires every query to carry a tenant filter;
  EF Core global query filters help but add invisible complexity. Rejected on security
  grounds — a missing filter leaks all tenants' data.

**Consequences**

- `TenantConnectionResolver` is the single authoritative source; adding a tenant
  requires a new entry in the connection-string registry (config / secret store).
- `AppDbContext` must NOT be registered as a singleton — it is scoped per request so
  the per-tenant connection string is resolved fresh each time.
- No EF Core discriminator column exists on any entity. Suggesting one is a review
  false positive covered by this LADR.

## Changelog

| Date | Change | Ref |
|:-----|:-------|:----|
| 2026-06-07 | Added DR-014 fixture context documenting the accepted per-tenant connection-string design. | DR-014 |
