using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Hosting;
using Microsoft.Extensions.Logging;
using ObjectStoreScenarioTest.Mcp.Services;
using ObjectStoreScenarioTest.Mcp.Tools;

var builder = Host.CreateApplicationBuilder(args);

builder.Logging.AddConsole(o => o.LogToStandardErrorThreshold = LogLevel.Trace);
builder.Services.AddSingleton(SubstrateMcpOptions.FromEnvironment());
builder.Services.AddSingleton(ScenarioRemoteOptions.FromEnvironment());
builder.Services.AddSingleton<SubstrateMcpClient>();
builder.Services.AddSingleton<ScenarioService>();

builder.Services
    .AddMcpServer()
    .WithStdioServerTransport()
    .WithTools<ScenarioTools>();

await builder.Build().RunAsync();
