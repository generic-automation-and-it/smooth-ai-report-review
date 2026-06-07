using Microsoft.EntityFrameworkCore.Migrations;

#nullable disable

namespace Project.Infrastructure.Migrations;

/// <inheritdoc />
public partial class DropLegacyColumn_Migration : Migration
{
    /// <inheritdoc />
    protected override void Up(MigrationBuilder migrationBuilder)
    {
        // Drops the column and all data it contains.
        // There is no prior data-migration step to archive or copy the values,
        // so any data stored in LegacyExternalRef is permanently lost once this runs.
        migrationBuilder.DropColumn(
            name: "LegacyExternalRef",
            table: "Orders");
    }

    /// <inheritdoc />
    protected override void Down(MigrationBuilder migrationBuilder)
    {
        // Down() is empty — the migration cannot be rolled back.
        // After applying Up(), reverting the deployment is impossible without
        // restoring from a database backup.
    }
}
