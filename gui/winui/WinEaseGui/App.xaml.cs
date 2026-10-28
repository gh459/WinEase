using System;
using System.IO;
using System.Text.Json.Nodes;
using Microsoft.UI.Xaml;

namespace WinEaseGui;

// Command line:
//   --stdio          started by WinEasebuilder.ps1 (gui\WinEaseWinUiHost.ps1): init message and replies on stdin,
//                    requests and the result on stdout
//   --init <file>    standalone preview: the init message from a file, requests answered locally
public partial class App : Application
{
    private MainWindow? _window;

    public App()
    {
        InitializeComponent();
        UnhandledException += (_, e) =>
        {
            LogError(e.Exception);
            e.Handled = true;
        };
    }

    // %TEMP%\WinEase-winui-error-<process id>.log (the window has no console). The name is per process, so a
    // file left by another process or user in the shared temp folder is never appended to.
    public static void LogError(Exception ex)
    {
        try
        {
            File.AppendAllText(Path.Combine(Path.GetTempPath(), $"WinEase-winui-error-{Environment.ProcessId}.log"), $"[{DateTime.Now:s}] {ex}\n\n");
        }
        catch
        {
            // Nothing else to report to
        }
    }

    protected override async void OnLaunched(LaunchActivatedEventArgs args)
    {
        string[] argv = Environment.GetCommandLineArgs();
        Bridge bridge;
        JsonObject? init = null;
        try
        {
            string? initFile = null;
            for (int i = 1; i < argv.Length; i++)
            {
                if (string.Equals(argv[i], "--init", StringComparison.OrdinalIgnoreCase) && i + 1 < argv.Length) initFile = argv[++i];
            }
            if (initFile != null)
            {
                bridge = Bridge.CreateOffline();
                init = JsonNode.Parse(File.ReadAllText(initFile))?.AsObject();
            }
            else
            {
                bridge = Bridge.CreateStdio();
                init = await bridge.ReadInitAsync();
            }
        }
        catch (Exception ex)
        {
            LogError(ex);
            init = null;
            bridge = Bridge.CreateOffline();
        }
        if (init == null)
        {
            // Nothing to show without the definitions from the builder
            Exit();
            return;
        }
        try
        {
            _window = new MainWindow(new InitData(init), bridge);
            _window.Activate();
        }
        catch (Exception ex)
        {
            LogError(ex);
            Exit();
        }
    }
}
