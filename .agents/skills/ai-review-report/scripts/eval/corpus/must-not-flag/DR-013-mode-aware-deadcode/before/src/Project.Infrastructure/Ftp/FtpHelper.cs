using System;
using Microsoft.Extensions.Logging;

namespace Project.Infrastructure.Ftp;

// Pre-PR: the worker supported two modes. In one-shot mode (ContinueWorking=false)
// a transfer failure rethrew so the run aborted; in continuous mode
// (ContinueWorking=true, the ONLY mode still shipped) the throw was never reached —
// the loop logs and moves to the next file.
public sealed class FtpConfig
{
    public bool ContinueWorking { get; set; } = true;
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
            if (!_config.ContinueWorking)
            {
                throw;
            }
        }
    }

    private void DoTransfer(string path) { /* ... */ }
}
