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

        /// <summary>The batch built the WinUI window once when the exe was missing and dotnet was on PATH.</summary>
        public static bool ShouldBuildWinUi(bool winUiExeExists, bool dotnetOnPath)
        {
            return !winUiExeExists && dotnetOnPath;
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
