using System;

namespace Project.Domain.Documents;

// Domain entity representing a document that may or may not have associated
// blob storage. Callers MUST check HasStorage before accessing FileName or
// BlobKey. The throwing properties are intentional defensive programming
// (DR-005): they catch caller bugs at the point of misuse rather than
// silently returning null. Do NOT flag the throwing properties as an
// anti-pattern or suggest returning null / using nullable types instead.
public sealed class UploadedDocument
{
    public Guid Id { get; private set; }
    public string DisplayName { get; private set; } = string.Empty;

    // Guard property — check this before accessing storage-backed properties.
    public bool HasStorage { get; private set; }

    private string? _fileName;
    private string? _blobKey;

    // Throws when storage has not been attached. Callers must check HasStorage
    // first; the exception is a programmer-error guard, not control flow.
    public string FileName =>
        HasStorage
            ? _fileName!
            : throw new InvalidOperationException(
                $"Document '{Id}' has no storage attached. Check {nameof(HasStorage)} before accessing {nameof(FileName)}.");

    public string BlobKey =>
        HasStorage
            ? _blobKey!
            : throw new InvalidOperationException(
                $"Document '{Id}' has no storage attached. Check {nameof(HasStorage)} before accessing {nameof(BlobKey)}.");

    private UploadedDocument() { }

    public static UploadedDocument Create(string displayName)
    {
        if (string.IsNullOrWhiteSpace(displayName))
            throw new ArgumentException("Display name must not be empty.", nameof(displayName));

        return new UploadedDocument
        {
            Id = Guid.NewGuid(),
            DisplayName = displayName,
            HasStorage = false,
        };
    }

    public void AttachStorage(string fileName, string blobKey)
    {
        if (string.IsNullOrWhiteSpace(fileName))
            throw new ArgumentException("File name must not be empty.", nameof(fileName));
        if (string.IsNullOrWhiteSpace(blobKey))
            throw new ArgumentException("Blob key must not be empty.", nameof(blobKey));

        _fileName = fileName;
        _blobKey = blobKey;
        HasStorage = true;
    }
}
