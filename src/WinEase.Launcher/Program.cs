using System;
using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Security.Principal;
using System.Windows.Forms;

namespace WinEase.Launcher
{
    internal static class Program
    {
        private const string Title = "WinEase Builder";

        [STAThread]
        private static int Main(string[] args)
        {
            Application.EnableVisualStyles();
            string baseDir = AppDomain.CurrentDomain.BaseDirectory;

            string builder = LauncherLogic.FindBuilder(baseDir, File.Exists,
                (dir, pattern) => Directory.Exists(dir) ? Directory.GetFiles(dir, pattern) : new string[0]);
            if (builder == null)
            {
                Error("Builder script not found.\r\nExpected file: " + Path.Combine(baseDir, "WinEasebuilder.ps1"));
                return 1;
            }

            // Build the WinUI 3 window when it is missing or older than its sources (needs the .NET SDK).
            // Without it the builder shows the classic window.
            string winUiExe = Path.Combine(baseDir, "gui", "winui", "bin", "WinEaseGui.exe");
            string winUiSources = Path.Combine(baseDir, "gui", "winui", "WinEaseGui");
            bool winUiExists = File.Exists(winUiExe);
            DateTime? winUiExeUtc = winUiExists ? File.GetLastWriteTimeUtc(winUiExe) : (DateTime?)null;
            DateTime? newestSourceUtc = LauncherLogic.NewestSourceWriteTimeUtc(winUiSources,
                Directory.Exists, (dir, pattern, option) => Directory.Exists(dir) ? Directory.EnumerateFiles(dir, pattern, option).ToArray() : new string[0],
                File.GetLastWriteTimeUtc);
            if (LauncherLogic.ShouldBuildWinUi(winUiExists, DotnetOnPath(), winUiExeUtc, newestSourceUtc))
            {
                // Result ignored on purpose: a failed build only means the classic window is used.
                RunHidden(LauncherLogic.BuildWinUiArguments(Path.Combine(baseDir, "gui", "winui", "build.ps1")), baseDir);
            }

            if (!IsAdministrator())
            {
                return Elevate(args);
            }

            int exit = RunHidden(LauncherLogic.BuildBuilderArguments(builder, args), baseDir);
            if (LauncherLogic.BuilderFailed(exit))
            {
                string logs = LauncherLogic.LogsDirectory(baseDir);
                DialogResult answer = MessageBox.Show(
                    "WinEase builder exited with code " + exit + ".\r\nCheck the latest log file in the logs folder for details.\r\n\r\nOpen the logs folder?",
                    Title, MessageBoxButtons.YesNo, MessageBoxIcon.Error);
                if (answer == DialogResult.Yes)
                {
                    Directory.CreateDirectory(logs);
                    Process.Start(new ProcessStartInfo("explorer.exe", LauncherLogic.QuoteArgument(logs)) { UseShellExecute = true });
                }
            }
            return LauncherLogic.LauncherExitCode(exit);
        }

        private static int Elevate(string[] args)
        {
            try
            {
                var psi = new ProcessStartInfo(Process.GetCurrentProcess().MainModule.FileName, LauncherLogic.JoinArguments(args))
                {
                    UseShellExecute = true,
                    Verb = "runas",
                    WorkingDirectory = AppDomain.CurrentDomain.BaseDirectory
                };
                Process.Start(psi);
                return 0;
            }
            catch (Win32Exception ex)
            {
                if (LauncherLogic.IsUacCancelled(ex.NativeErrorCode))
                {
                    Error("Admin privileges were not granted (UAC cancelled).\r\nWinEase Builder requires administrator privileges to run.");
                    return LauncherLogic.UacCancelledErrorCode;
                }
                Error("Could not restart with administrator privileges: " + ex.Message);
                return 1;
            }
        }

        private static int RunHidden(string arguments, string workingDirectory)
        {
            var psi = new ProcessStartInfo("powershell.exe", arguments)
            {
                UseShellExecute = false,
                CreateNoWindow = true,
                WorkingDirectory = workingDirectory
            };
            using (Process p = Process.Start(psi))
            {
                p.WaitForExit();
                return p.ExitCode;
            }
        }

        private static bool IsAdministrator()
        {
            using (WindowsIdentity id = WindowsIdentity.GetCurrent())
            {
                return new WindowsPrincipal(id).IsInRole(WindowsBuiltInRole.Administrator);
            }
        }

        private static bool DotnetOnPath()
        {
            string path = Environment.GetEnvironmentVariable("PATH") ?? "";
            return path.Split(Path.PathSeparator).Any(d =>
            {
                try { return d.Length > 0 && File.Exists(Path.Combine(d.Trim('"'), "dotnet.exe")); }
                catch (ArgumentException) { return false; }
            });
        }

        private static void Error(string message)
        {
            MessageBox.Show(message, Title, MessageBoxButtons.OK, MessageBoxIcon.Error);
        }
    }
}
