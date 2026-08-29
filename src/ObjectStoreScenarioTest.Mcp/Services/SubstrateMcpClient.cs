using System.Text.Json;
using Microsoft.Extensions.Logging;
using ModelContextProtocol;
using ModelContextProtocol.Client;
using ModelContextProtocol.Protocol;

namespace ObjectStoreScenarioTest.Mcp.Services;

internal sealed class SubstrateMcpClient(
    SubstrateMcpOptions options,
    ILoggerFactory loggerFactory,
    ILogger<SubstrateMcpClient> logger) : IAsyncDisposable
{
    private const int MaximumErrorCharacters = 16384;
    private readonly SemaphoreSlim initializationLock = new(1, 1);
    private McpClient? client;

    public async Task<JsonElement> CallToolAsync(
        string toolName,
        IReadOnlyDictionary<string, object?> arguments,
        CancellationToken cancellationToken)
    {
        McpClient connectedClient = await GetClientAsync(cancellationToken).ConfigureAwait(false);
        CallToolResult result = await connectedClient.CallToolAsync(
            toolName,
            arguments,
            cancellationToken: cancellationToken).ConfigureAwait(false);
        string text = string.Join(
            Environment.NewLine,
            result.Content.OfType<TextContentBlock>().Select(content => content.Text));
        if (result.IsError == true)
        {
            throw new McpException(
                string.IsNullOrWhiteSpace(text)
                    ? $"SubstrateMCP tool '{toolName}' failed."
                    : BoundText(text));
        }
        if (string.IsNullOrWhiteSpace(text))
        {
            throw new McpException($"SubstrateMCP tool '{toolName}' returned no text content.");
        }

        JsonDocument document;
        try
        {
            document = JsonDocument.Parse(text);
        }
        catch (JsonException)
        {
            throw new McpException(
                $"SubstrateMCP tool '{toolName}' returned invalid JSON: {BoundText(text)}");
        }
        using (document)
        {
            JsonElement root = document.RootElement.Clone();
            if (root.TryGetProperty("success", out JsonElement success) &&
                success.ValueKind == JsonValueKind.False)
            {
                string message = root.TryGetProperty("message", out JsonElement messageElement)
                    ? messageElement.GetString() ?? text
                    : text;
                throw new McpException(BoundText(message));
            }

            return root;
        }
    }

    public async ValueTask DisposeAsync()
    {
        if (client is not null)
        {
            await client.DisposeAsync().ConfigureAwait(false);
        }
        initializationLock.Dispose();
    }

    private async Task<McpClient> GetClientAsync(CancellationToken cancellationToken)
    {
        if (client is not null)
        {
            return client;
        }

        await initializationLock.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            if (client is null)
            {
                StdioClientTransport transport = new(new StdioClientTransportOptions
                {
                    Name = "SubstrateMCP",
                    Command = options.Command,
                    Arguments = options.Arguments.ToArray(),
                    StandardErrorLines = line => logger.LogDebug("SubstrateMCP: {Line}", line),
                }, loggerFactory);
                client = await McpClient.CreateAsync(
                    transport,
                    loggerFactory: loggerFactory,
                    cancellationToken: cancellationToken).ConfigureAwait(false);
            }

            return client;
        }
        finally
        {
            initializationLock.Release();
        }
    }

    private static string BoundText(string text)
    {
        return text.Length <= MaximumErrorCharacters
            ? text
            : $"{text[..MaximumErrorCharacters]}... [truncated]";
    }
}
