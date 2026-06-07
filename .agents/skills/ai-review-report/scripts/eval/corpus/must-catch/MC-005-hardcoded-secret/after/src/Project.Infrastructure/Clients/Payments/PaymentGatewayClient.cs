using System.Net.Http;
using System.Net.Http.Headers;
using System.Text;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;

namespace Project.Infrastructure.Clients.Payments;

public sealed class PaymentGatewayClient
{
    // Hardcoded production API key — this value will be stored in git history
    // and exposed to anyone with repository read access.
    // Should be injected from IConfiguration / environment secret instead.
    private const string ApiKey = "sk-live-4f8a2c1d9e7b3f6a0c5d8e2b4f7a1c3d";

    private readonly HttpClient _http;

    public PaymentGatewayClient(HttpClient http)
    {
        _http = http;
        _http.BaseAddress = new Uri("https://api.payments.example.com/v2/");
        _http.DefaultRequestHeaders.Authorization =
            new AuthenticationHeaderValue("Bearer", ApiKey);
    }

    public async Task<PaymentResult> ChargeAsync(
        ChargeRequest request, CancellationToken ct = default)
    {
        var body = new StringContent(
            JsonSerializer.Serialize(request),
            Encoding.UTF8,
            "application/json");

        var response = await _http.PostAsync("charges", body, ct);
        response.EnsureSuccessStatusCode();

        var json = await response.Content.ReadAsStringAsync(ct);
        return JsonSerializer.Deserialize<PaymentResult>(json)!;
    }
}
