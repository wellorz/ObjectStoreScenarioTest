using System.Text.RegularExpressions;

namespace ObjectStoreScenarioTest.Mcp.Services;

internal static partial class ScenarioInputValidator
{
    public static void ValidateStart(
        string machineNameOrIp,
        string organization,
        string objectPrefix,
        string side,
        string objectStoreDestination,
        int randomSeed,
        int initialReportIntervalMinutes,
        int steadyReportIntervalMinutes,
        int steadyIntervalAfterMinutes)
    {
        ValidateMachine(machineNameOrIp);
        if (!OrganizationRegex().IsMatch(organization))
        {
            throw new ArgumentException("Organization must be a DNS-style name.", nameof(organization));
        }
        if (!ObjectPrefixRegex().IsMatch(objectPrefix))
        {
            throw new ArgumentException("Object prefix must contain 3-32 letters, numbers, or hyphens.", nameof(objectPrefix));
        }
        if (!string.Equals(side, "A", StringComparison.OrdinalIgnoreCase) &&
            !string.Equals(side, "B", StringComparison.OrdinalIgnoreCase))
        {
            throw new ArgumentException("Side must be A or B.", nameof(side));
        }
        _ = NormalizeObjectStoreDestination(objectStoreDestination);
        if (randomSeed is < 1 or > 100000)
        {
            throw new ArgumentOutOfRangeException(nameof(randomSeed));
        }
        ValidateReportingIntervals(
            initialReportIntervalMinutes,
            steadyReportIntervalMinutes,
            steadyIntervalAfterMinutes);
    }

    public static void ValidateReportingIntervals(
        int initialReportIntervalMinutes,
        int steadyReportIntervalMinutes,
        int steadyIntervalAfterMinutes)
    {
        ValidateInterval(initialReportIntervalMinutes, nameof(initialReportIntervalMinutes));
        ValidateInterval(steadyReportIntervalMinutes, nameof(steadyReportIntervalMinutes));
        if (steadyIntervalAfterMinutes is < 1 or > 1440)
        {
            throw new ArgumentOutOfRangeException(nameof(steadyIntervalAfterMinutes));
        }
    }

    public static void ValidateMachine(string machineNameOrIp)
    {
        if (!MachineRegex().IsMatch(machineNameOrIp))
        {
            throw new ArgumentException("Machine must be a hostname or IPv4 address.", nameof(machineNameOrIp));
        }
    }

    public static string NormalizeRunDirectory(string runDirectory, string trustedRemoteRoot)
    {
        string normalizedRunDirectory = NormalizeTrustedWindowsPath(runDirectory, nameof(runDirectory));
        string normalizedRunsRoot = NormalizeTrustedWindowsPath(
            Path.Combine(trustedRemoteRoot, "Runs"),
            nameof(trustedRemoteRoot));
        DirectoryInfo? parent = Directory.GetParent(normalizedRunDirectory);
        if (parent is null ||
            !string.Equals(
                NormalizeTrustedWindowsPath(parent.FullName, nameof(runDirectory)),
                normalizedRunsRoot,
                StringComparison.OrdinalIgnoreCase))
        {
            throw new ArgumentException(
                $"Run directory must be an immediate child of {normalizedRunsRoot}.",
                nameof(runDirectory));
        }

        return normalizedRunDirectory;
    }

    public static string NormalizeObjectStoreDestination(string objectStoreDestination)
    {
        string[] destinations = ["Test", "TDF", "Canary", "CanaryInt"];
        return destinations.FirstOrDefault(
            destination => string.Equals(destination, objectStoreDestination, StringComparison.OrdinalIgnoreCase))
            ?? throw new ArgumentException(
                "Unsupported Object Store destination.",
                nameof(objectStoreDestination));
    }

    public static string QuotePowerShell(string value)
    {
        if (value.IndexOfAny(['\0', '\r', '\n']) >= 0)
        {
            throw new ArgumentException("PowerShell values cannot contain nulls or newlines.", nameof(value));
        }

        return $"'{value.Replace("'", "''", StringComparison.Ordinal)}'";
    }

    public static void ValidateLaunchToken(string launchToken)
    {
        if (!LaunchTokenRegex().IsMatch(launchToken))
        {
            throw new ArgumentException(
                "Launch token must contain exactly 32 hexadecimal characters.",
                nameof(launchToken));
        }
    }

    public static string NormalizeTrustedWindowsPath(string path, string parameterName)
    {
        if (string.IsNullOrWhiteSpace(path) ||
            path.IndexOfAny(['\0', '\r', '\n', '"', '*', '?']) >= 0)
        {
            throw new ArgumentException("A fully-qualified local Windows path is required.", parameterName);
        }

        string normalizedPath;
        try
        {
            normalizedPath = Path.GetFullPath(path);
        }
        catch (Exception exception) when (
            exception is ArgumentException or NotSupportedException or PathTooLongException)
        {
            throw new ArgumentException("A valid fully-qualified local Windows path is required.", parameterName, exception);
        }

        if (!DriveQualifiedPathRegex().IsMatch(normalizedPath) ||
            normalizedPath.AsSpan(2).Contains(':'))
        {
            throw new ArgumentException(
                "UNC, device, relative, and alternate-data-stream paths are not allowed.",
                parameterName);
        }

        string root = Path.GetPathRoot(normalizedPath)!;
        return normalizedPath.Length == root.Length
            ? normalizedPath
            : normalizedPath.TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
    }

    private static void ValidateInterval(int value, string parameterName)
    {
        if (value is < 1 or > 60)
        {
            throw new ArgumentOutOfRangeException(parameterName, "Reporting interval must be 1-60 minutes.");
        }
    }

    [GeneratedRegex(@"^[A-Za-z0-9][A-Za-z0-9.-]{0,127}$", RegexOptions.CultureInvariant)]
    private static partial Regex MachineRegex();

    [GeneratedRegex(@"^[A-Za-z0-9][A-Za-z0-9.-]{0,253}$", RegexOptions.CultureInvariant)]
    private static partial Regex OrganizationRegex();

    [GeneratedRegex(@"^[A-Za-z0-9-]{3,32}$", RegexOptions.CultureInvariant)]
    private static partial Regex ObjectPrefixRegex();

    [GeneratedRegex(@"^[A-Za-z]:\\", RegexOptions.CultureInvariant)]
    private static partial Regex DriveQualifiedPathRegex();

    [GeneratedRegex(@"^[A-Fa-f0-9]{32}$", RegexOptions.CultureInvariant)]
    private static partial Regex LaunchTokenRegex();
}
