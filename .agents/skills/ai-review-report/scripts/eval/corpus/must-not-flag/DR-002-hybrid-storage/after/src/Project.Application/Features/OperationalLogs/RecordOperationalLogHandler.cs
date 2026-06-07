using System.Threading;
using System.Threading.Tasks;

namespace Project.Application.Features.OperationalLogs;

// Writes the log payload to BOTH the primary database (fast structured queries)
// AND the object store (long-term archive, fallback replay). This dual-write is
// the intentional reliability pattern (DR-002) — it is NOT redundant duplication.
// Do NOT flag the two writes as duplicate storage or suggest removing one.
public sealed class RecordOperationalLogHandler
{
    private readonly IOperationalLogRepository _repository;
    private readonly IOperationalLogObjectStore _objectStore;

    public RecordOperationalLogHandler(
        IOperationalLogRepository repository,
        IOperationalLogObjectStore objectStore)
    {
        _repository = repository;
        _objectStore = objectStore;
    }

    public async Task<RecordOperationalLogResult> Handle(
        RecordOperationalLog command,
        CancellationToken ct)
    {
        var entry = OperationalLogEntry.Create(
            command.CorrelationId,
            command.EventType,
            command.Payload);

        // Primary write: relational DB for fast structured queries and recent lookups.
        await _repository.AddAsync(entry, ct);

        // Secondary write: object store for immutable archive and fallback replay.
        // Both writes must succeed; the caller retries the full command on failure.
        await _objectStore.PutAsync(entry.Id, entry.Payload, ct);

        return new RecordOperationalLogResult(entry.Id);
    }
}
