using System.Reflection;

namespace ObjectStoreScenarioTest.Mcp.Services;

internal static class ScenarioResourceLocator
{
    private static readonly Lazy<ResourcePaths> ExtractedPaths = new(ExtractResources);

    public static string HarnessPath => ExtractedPaths.Value.HarnessPath;

    public static string StatusScriptPath => ExtractedPaths.Value.StatusScriptPath;

    private static ResourcePaths ExtractResources()
    {
        string extractionRoot = Path.Combine(
            Path.GetTempPath(),
            "ObjectStoreScenarioTest.Mcp",
            $"{Environment.ProcessId}-{Guid.NewGuid():N}");
        Directory.CreateDirectory(extractionRoot);

        Assembly assembly = typeof(ScenarioResourceLocator).Assembly;
        string harnessPath = ExtractResource(
            assembly,
            "ObjectStoreScenarioTest.Mcp.Resources.Invoke-DirectoryObjectStoreLongevity.ps1",
            extractionRoot,
            "Invoke-DirectoryObjectStoreLongevity.ps1");
        string statusScriptPath = ExtractResource(
            assembly,
            "ObjectStoreScenarioTest.Mcp.Resources.Get-DirectoryObjectStoreScenarioStatus.ps1",
            extractionRoot,
            "Get-DirectoryObjectStoreScenarioStatus.ps1");
        AppDomain.CurrentDomain.ProcessExit += (_, _) => TryDeleteExtractionRoot(extractionRoot);
        return new(harnessPath, statusScriptPath);
    }

    private static string ExtractResource(
        Assembly assembly,
        string resourceName,
        string extractionRoot,
        string fileName)
    {
        using Stream source = assembly.GetManifestResourceStream(resourceName)
            ?? throw new InvalidOperationException($"Embedded ScenarioTest resource is missing: {resourceName}");
        string destinationPath = Path.Combine(extractionRoot, fileName);
        using FileStream destination = new(
            destinationPath,
            FileMode.CreateNew,
            FileAccess.Write,
            FileShare.Read);
        source.CopyTo(destination);
        return destinationPath;
    }

    private static void TryDeleteExtractionRoot(string extractionRoot)
    {
        try
        {
            Directory.Delete(extractionRoot, recursive: true);
        }
        catch (IOException)
        {
        }
        catch (UnauthorizedAccessException)
        {
        }
    }

    private sealed record ResourcePaths(string HarnessPath, string StatusScriptPath);
}
