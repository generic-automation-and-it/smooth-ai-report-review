using System;
using Microsoft.Extensions.Logging;

namespace Project.Infrastructure.Ftp;

// One-shot mode has been removed — the worker only ever runs continuously now.
// The ContinueWorking flag and the conditional rethrow it gated are deleted
// together. In continuous mode the rethrow was already unreachable, so behaviour
// is unchanged.
public sealed class FtpConfig
{
    public string Host { get; set; } = string.Empty;
}

public sealed class FtpHelper
{
    private readonly FtpConfig _config;
    private readonly ILogger<FtpHelper> _logger;

    public FtpHelper(FtpConfig config, ILogger<FtpHelper> logger)
    {
        _config = config;
        _logger = logger;
    }

    public void TransferFile(string path)
    {
        try
        {
            DoTransfer(path);
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "Transfer failed for {Path}", path);
        }
    }

    private void DoTransfer(string path) { /* ... */ }
}
