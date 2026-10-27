using System;
using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Text;
using System.Text.RegularExpressions;
using System.Windows.Forms;

[assembly: AssemblyTitle("SharePoint Facil")]
[assembly: AssemblyCompany("UTI DA INFORMATICA LTDA")]
[assembly: AssemblyVersion("1.1.8.0")]
[assembly: AssemblyFileVersion("1.1.8.0")]

internal static class Launcher
{
    // Windows command-line quoting, including paths ending in a backslash.
    internal static string Quote(string value)
    {
        StringBuilder result = new StringBuilder("\"");
        int slashes = 0;
        foreach (char c in value)
        {
            if (c == '\\') { slashes++; continue; }
            if (c == '"') { result.Append('\\', slashes * 2 + 1); }
            else { result.Append('\\', slashes); }
            result.Append(c);
            slashes = 0;
        }
        result.Append('\\', slashes * 2);
        return result.Append('"').ToString();
    }

    // Drive letters mapped by the current user. Read lexically so a double-click
    // on an unrelated document never waits for PowerShell.
    internal static bool IsMappedDrive(string path, string settingsFile)
    {
        if (!Regex.IsMatch(path, @"^[D-Zd-z]:\\") || !File.Exists(settingsFile)) return false;
        string letter = path.Substring(0, 1).ToUpperInvariant();
        foreach (Match match in Regex.Matches(File.ReadAllText(settingsFile), "\"drive\"\\s*:\\s*\"([D-Za-z])\""))
        {
            if (match.Groups[1].Value.ToUpperInvariant() == letter) return true;
        }
        return false;
    }

    internal static ProcessStartInfo CreateStartInfo(string directory, string[] args)
    {
        return CreateStartInfo(directory, args, Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), @"SharePointFacil\settings.json"));
    }

    internal static ProcessStartInfo CreateStartInfo(string directory, string[] args, string settingsFile)
    {
        string extra = "";
        if (args.Length == 2 && args[0].Equals("-OfficeOpen", StringComparison.OrdinalIgnoreCase))
        {
            if (String.IsNullOrWhiteSpace(args[1]) || args[1].IndexOfAny(new[] { '\0', '\r', '\n', '"' }) >= 0)
                throw new ArgumentException("Documento invalido.");
            // Outside our drives, hand the file to Office's own Open verb unchanged.
            if (!IsMappedDrive(args[1], settingsFile))
                return new ProcessStartInfo { FileName = args[1], Verb = "Open", UseShellExecute = true };
            extra = " -DocumentAction Auto -DocumentPath " + Quote(args[1]);
        }
        else if (args.Length == 1 && args[0].Equals("-AutoMount", StringComparison.OrdinalIgnoreCase))
        {
            extra = " -AutoMount";
        }
        else if (args.Length == 1 && args[0].Equals("-ShellWatcher", StringComparison.OrdinalIgnoreCase))
        {
            extra = " -ShellWatcher";
        }
        else if (args.Length == 4 && args[0].Equals("-DocumentAction", StringComparison.OrdinalIgnoreCase)
            && args[2].Equals("-DocumentPath", StringComparison.OrdinalIgnoreCase))
        {
            string action = Array.Find(new[] { "SharePoint" },
                delegate(string candidate) { return candidate.Equals(args[1], StringComparison.OrdinalIgnoreCase); });
            if (action == null || String.IsNullOrWhiteSpace(args[3]) || args[3].IndexOfAny(new[] { '\0', '\r', '\n', '"' }) >= 0)
                throw new ArgumentException("Comando de documento invalido.");
            extra = " -DocumentAction " + action + " -DocumentPath " + Quote(args[3]);
        }
        else if (args.Length != 0)
        {
            throw new ArgumentException("Argumentos de inicializacao invalidos.");
        }

        return new ProcessStartInfo
        {
            FileName = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), @"WindowsPowerShell\v1.0\powershell.exe"),
            Arguments = "-NoLogo -NoProfile -NonInteractive -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File "
                + Quote(Path.Combine(directory, "RcloneDriveManager.ps1")) + extra,
            WorkingDirectory = directory,
            UseShellExecute = false,
            CreateNoWindow = true,
            WindowStyle = ProcessWindowStyle.Hidden
        };
    }

    [STAThread]
    private static int Main(string[] args)
    {
        try
        {
            string directory = AppDomain.CurrentDomain.BaseDirectory;
            if (!File.Exists(Path.Combine(directory, "RcloneDriveManager.ps1")))
                throw new FileNotFoundException("A instalacao esta incompleta. Use Reparar no instalador.");
            using (Process process = Process.Start(CreateStartInfo(directory, args))) { }
            return 0;
        }
        catch (Exception error)
        {
            MessageBox.Show(error.Message, "SharePoint Facil", MessageBoxButtons.OK, MessageBoxIcon.Error);
            return 1;
        }
    }
}
