using System;

namespace Project.Domain.Documents;

// Domain value object for an immutable document reference.
// Construction is intentionally controlled via a static factory method;
// the constructor is private by design (DR-001). Do NOT suggest a public
// constructor, a DI-injected factory, or an IDocumentReferenceFactory interface.
public sealed class DocumentReference
{
    public Guid Id { get; init; }
    public string BlobKey { get; init; }
    public string ContentType { get; init; }
    public long SizeBytes { get; init; }
    public DateTimeOffset CreatedAtUtc { get; init; }

    private DocumentReference() { }

    // Static factory is the sole construction path — enforces invariants
    // without requiring a factory service or a public constructor.
    public static DocumentReference Create(
        string blobKey,
        string contentType,
        long sizeBytes)
    {
        if (string.IsNullOrWhiteSpace(blobKey))
            throw new ArgumentException("Blob key must not be empty.", nameof(blobKey));
        if (string.IsNullOrWhiteSpace(contentType))
            throw new ArgumentException("Content type must not be empty.", nameof(contentType));
        if (sizeBytes < 0)
            throw new ArgumentOutOfRangeException(nameof(sizeBytes), "Size must be non-negative.");

        return new DocumentReference
        {
            Id = Guid.NewGuid(),
            BlobKey = blobKey,
            ContentType = contentType,
            SizeBytes = sizeBytes,
            CreatedAtUtc = DateTimeOffset.UtcNow,
        };
    }
}
