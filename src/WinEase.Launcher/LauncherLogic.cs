using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text;

namespace WinEase.Launcher
{
    /// <summary>
    /// The decisions WinEase-GUI.bat made, as pure functions (no UI, no process start) so they can be tested.
    /// </summary>
    public static class LauncherLogic
    {
        public const int UacCancelledErrorCode = 1223;

        /// <summary>
        /// WinEasebuilder.ps1 first, else a WinEasebuilder-*.ps1. Like the batch "for" loop, the last match in
        /// name order wins when there are several. Returns null when nothing is found.
        /// </summary>
        public static string FindBuilder(string baseDir, Func<string, bool> fileExists, Func<string, string, IEnumerable<string>> listFiles)
        {
            string primary = Path.Combine(baseDir, "WinEasebuilder.ps1");
            if (fileExists(primary)) return primary;
            string last = null;
            foreach (string f in listFiles(baseDir, "WinEasebuilder-*.ps1").OrderBy(x => x, StringComparer.OrdinalIgnoreCase))
            {
                last = f;
            }
            return last;
        }

        /// <summary>
        /// The launcher builds the WinUI window when the published exe is missing or older than its sources
        /// (a stale exe would run outdated GUI code without fixes made since it was compiled), and dotnet is
        /// on PATH. Times are UTC last-write times; null means "missing / not readable".
        /// </summary>
        public static bool ShouldBuildWinUi(bool winUiExeExists, bool dotnetOnPath, DateTime? winUiExeUtc, DateTime? newestSourceUtc)
        {
            if (!dotnetOnPath) return false;
            if (!winUiExeExists) return true;
            return newestSourceUtc.HasValue && winUiExeUtc.HasValue && newestSourceUtc.Value > winUiExeUtc.Value;
        }

        /// <summary>The newest last-write time of the WinUI sources (everything under gui\winui\WinEaseGui
        /// except the bin and obj build outputs). Null when nothing exists.</summary>
        public static DateTime? NewestSourceWriteTimeUtc(string sourceRoot, Func<string, bool> dirExists, Func<string, string, SearchOption, IEnumerable<string>> listFiles, Func<string, DateTime> lastWriteTimeUtc)
        {
            if (!dirExists(sourceRoot)) return null;
            DateTime? newest = null;
            foreach (string file in listFiles(sourceRoot, "*", SearchOption.AllDirectories))
            {
                if (IsUnderBuildOutput(file)) continue;
                DateTime t = lastWriteTimeUtc(file);
                if (newest == null || t > newest) newest = t;
            }
            return newest;
        }

        /// <summary>gui\winui\WinEaseGui\bin and \obj are build outputs, not sources.</summary>
        public static bool IsUnderBuildOutput(string path)
        {
            if (string.IsNullOrEmpty(path)) return false;

            // Zero-allocation segment scanning to avoid string array allocations when checking source files.
            int len = path.Length;
            int start = 0;
            while (start < len)
            {
                int end = start;
                while (end < len && path[end] != '\\' && path[end] != '/')
                {
                    end++;
                }

                int segmentLen = end - start;
                if (segmentLen == 3)
                {
                    char c0 = path[start];
                    char c1 = path[start + 1];
                    char c2 = path[start + 2];

                    bool isBin = (c0 == 'b' || c0 == 'B') &&
                                 (c1 == 'i' || c1 == 'I') &&
                                 (c2 == 'n' || c2 == 'N');

                    bool isObj = (c0 == 'o' || c0 == 'O') &&
                                 (c1 == 'b' || c1 == 'B') &&
                                 (c2 == 'j' || c2 == 'J');

                    if (isBin || isObj) return true;
                }

                start = end + 1;
            }

            return false;
        }

        /// <summary>Quotes one argument for a Windows command line (CommandLineToArgvW rules).</summary>
        public static string QuoteArgument(string arg)
        {
            if (arg == null) arg = "";
            if (arg.Length > 0 && arg.IndexOfAny(new[] { ' ', '\t', '\n', '\v', '"' }) < 0) return arg;
            var sb = new StringBuilder("\"");
            int backslashes = 0;
            foreach (char c in arg)
            {
                if (c == '\\')
                {
                    backslashes++;
                }
                else if (c == '"')
                {
                    sb.Append('\\', backslashes * 2 + 1).Append('"');
                    backslashes = 0;
                }
                else
                {
                    sb.Append('\\', backslashes).Append(c);
                    backslashes = 0;
                }
            }
            sb.Append('\\', backslashes * 2).Append('"');
            return sb.ToString();
        }

        public static string JoinArguments(IEnumerable<string> args)
        {
            return string.Join(" ", (args ?? new string[0]).Select(QuoteArgument));
        }

        /// <summary>
        /// powershell.exe arguments: the batch's fixed part plus -GUI, then every argument given to the exe
        /// (for example -ClassicGui) unchanged and in order.
        /// </summary>
        public static string BuildBuilderArguments(string builderPath, IEnumerable<string> passthrough)
        {
            string head = "-NoProfile -ExecutionPolicy Bypass -File " + QuoteArgument(builderPath) + " -GUI";
            string rest = JoinArguments(passthrough);
            return rest.Length == 0 ? head : head + " " + rest;
        }

        /// <summary>The WinUI build step the batch ran: powershell.exe -File gui\winui\build.ps1.</summary>
        public static string BuildWinUiArguments(string buildScriptPath)
        {
            return "-NoProfile -ExecutionPolicy Bypass -File " + QuoteArgument(buildScriptPath);
        }

        /// <summary>ERROR_CANCELLED (1223) is what Windows reports when the UAC prompt is dismissed.</summary>
        public static bool IsUacCancelled(int win32ErrorCode)
        {
            return win32ErrorCode == UacCancelledErrorCode;
        }

        /// <summary>Exit code the launcher itself returns: the builder's, unchanged.</summary>
        public static int LauncherExitCode(int builderExitCode)
        {
            return builderExitCode;
        }

        public static bool BuilderFailed(int exitCode)
        {
            return exitCode != 0;
        }

        public static string LogsDirectory(string baseDir)
        {
            return Path.Combine(baseDir, "logs");
        }
    }
}
