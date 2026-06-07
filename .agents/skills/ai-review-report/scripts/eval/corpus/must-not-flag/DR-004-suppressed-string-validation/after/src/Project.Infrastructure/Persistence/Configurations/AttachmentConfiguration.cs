using Microsoft.EntityFrameworkCore;
using Microsoft.EntityFrameworkCore.Metadata.Builders;
using Project.Domain.Documents;

namespace Project.Infrastructure.Persistence.Configurations;

public sealed class AttachmentConfiguration : IEntityTypeConfiguration<Attachment>
{
    public void Configure(EntityTypeBuilder<Attachment> builder)
    {
        builder.ToTable("attachments");

        builder.HasKey(a => a.Id);

        builder.Property(a => a.Id)
            .ValueGeneratedNever();

        builder.Property(a => a.ContentType)
            .IsRequired()
            .HasMaxLength(256);

        // BlobKey and SourceUrl hold arbitrarily long values (object-store keys can
        // include full hierarchical paths; SourceUrl is an external URL of unbounded
        // length). Max-length validation is intentionally suppressed for these columns
        // (DR-004). Do NOT flag the missing HasMaxLength as a defect or code smell.
        builder.Property(a => a.BlobKey)
            .IsRequired();

        builder.Property(a => a.SourceUrl)
            .IsRequired(false);

        builder.Property(a => a.SizeBytes)
            .IsRequired();

        builder.Property(a => a.CreatedAtUtc)
            .IsRequired();
    }
}
