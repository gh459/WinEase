using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using WinEase.Launcher;
using Xunit;

public class LauncherLogicTests
{
    private static readonly string Dir = Path.Combine("C:", "WinEase");

    [Fact]
    public void FindBuilder_prefers_the_plain_name()
    {
        string found = LauncherLogic.FindBuilder(Dir, p => true, (d, pat) => new[] { Path.Combine(d, "WinEasebuilder-x.ps1") });
        Assert.Equal(Path.Combine(Dir, "WinEasebuilder.ps1"), found);
    }

    [Fact]
    public void FindBuilder_falls_back_to_the_last_versioned_name()
    {
        string found = LauncherLogic.FindBuilder(Dir, p => false,
            (d, pat) => new[] { Path.Combine(d, "WinEasebuilder-b.ps1"), Path.Combine(d, "WinEasebuilder-a.ps1") });
        Assert.Equal(Path.Combine(Dir, "WinEasebuilder-b.ps1"), found);
    }

    [Fact]
    public void FindBuilder_returns_null_when_nothing_exists()
    {
        Assert.Null(LauncherLogic.FindBuilder(Dir, p => false, (d, pat) => Enumerable.Empty<string>()));
    }

    [Theory]
    [InlineData(false, true, null, null, true)]                    // exe missing, dotnet present
    [InlineData(false, false, null, null, false)]                  // exe missing, no dotnet
    [InlineData(true, true, "2026-10-24T20:00:00Z", "2026-10-26T06:30:00Z", true)]   // stale exe
    [InlineData(true, true, "2026-10-26T09:00:00Z", "2026-10-26T06:30:00Z", false)]  // up to date
    [InlineData(true, true, "2026-10-26T06:30:00Z", "2026-10-26T06:30:00Z", false)]  // same time is fresh
    [InlineData(true, false, "2026-10-24T20:00:00Z", "2026-10-26T06:30:00Z", false)] // stale but no dotnet
    [InlineData(true, true, "2026-10-24T20:00:00Z", null, false)]  // no readable source time
    public void ShouldBuildWinUi_when_exe_missing_or_stale_and_dotnet_present(
        bool exe, bool dotnet, string exeUtcText, string sourceUtcText, bool expected)
    {
        DateTime? exeUtc = exeUtcText == null ? null : DateTime.Parse(exeUtcText, System.Globalization.CultureInfo.InvariantCulture, System.Globalization.DateTimeStyles.RoundtripKind);
        DateTime? sourceUtc = sourceUtcText == null ? null : DateTime.Parse(sourceUtcText, System.Globalization.CultureInfo.InvariantCulture, System.Globalization.DateTimeStyles.RoundtripKind);
        Assert.Equal(expected, LauncherLogic.ShouldBuildWinUi(exe, dotnet, exeUtc, sourceUtc));
    }

    [Fact]
    public void NewestSourceWriteTimeUtc_ignores_bin_and_obj_and_keeps_the_newest_file()
    {
        string root = Path.Combine(Dir, "gui", "winui", "WinEaseGui");
        var files = new[]
        {
            Path.Combine(root, "MainWindow.xaml.cs"),
            Path.Combine(root, "obj", "Debug", "XamlTypeInfo.g.cs"),
            Path.Combine(root, "bin", "WinEaseGui.exe"),
            Path.Combine(root, "Bridge.cs"),
        };
        var times = new Dictionary<string, DateTime>
        {
            [files[0]] = new DateTime(2026, 10, 26, 6, 30, 0, DateTimeKind.Utc),
            [files[1]] = new DateTime(2026, 10, 27, 0, 0, 0, DateTimeKind.Utc),   // newest, but obj
            [files[2]] = new DateTime(2026, 10, 28, 0, 0, 0, DateTimeKind.Utc),   // newest, but bin
            [files[3]] = new DateTime(2026, 10, 24, 20, 0, 0, DateTimeKind.Utc),
        };
        DateTime? newest = LauncherLogic.NewestSourceWriteTimeUtc(root,
            d => d == root, (d, pattern, option) => files, f => times[f]);
        Assert.Equal(times[files[0]], newest);
    }

    [Fact]
    public void NewestSourceWriteTimeUtc_is_null_when_the_folder_is_missing()
    {
        Assert.Null(LauncherLogic.NewestSourceWriteTimeUtc(@"C:\nowhere", d => false, (d, pattern, option) => Enumerable.Empty<string>(), f => DateTime.UtcNow));
    }

    [Theory]
    [InlineData(null, false)]
    [InlineData("", false)]
    [InlineData("bin", true)]
    [InlineData("obj", true)]
    [InlineData("BIN", true)]
    [InlineData("OBJ", true)]
    [InlineData(@"bin\output.dll", true)]
    [InlineData(@"obj\Debug\app.dll", true)]
    [InlineData(@"C:\repo\gui\winui\WinEaseGui\bin\WinEaseGui.exe", true)]
    [InlineData(@"C:\repo\gui\winui\WinEaseGui\obj\Debug\XamlTypeInfo.g.cs", true)]
    [InlineData(@"gui/winui/WinEaseGui/bin/WinEaseGui.exe", true)]
    [InlineData(@"gui/winui/WinEaseGui/obj/Debug/XamlTypeInfo.g.cs", true)]
    [InlineData(@"C:\repo\bingo\app.exe", false)]
    [InlineData(@"C:\repo\object\app.exe", false)]
    [InlineData(@"C:\repo\gui\winui\WinEaseGui\Views\MainView.xaml.cs", false)]
    public void IsUnderBuildOutput_identifies_build_output_directories_correctly(string path, bool expected)
    {
        Assert.Equal(expected, LauncherLogic.IsUnderBuildOutput(path));
    }

    [Fact]
    public void BuilderArguments_pass_the_fixed_part_and_forward_arguments_in_order()
    {
        string a = LauncherLogic.BuildBuilderArguments(@"C:\WinEase\WinEasebuilder.ps1", new[] { "-ClassicGui", "-Profile", "gaming" });
        Assert.Equal(@"-NoProfile -ExecutionPolicy Bypass -File C:\WinEase\WinEasebuilder.ps1 -GUI -ClassicGui -Profile gaming", a);
    }

    [Fact]
    public void BuilderArguments_without_extra_arguments_match_the_batch()
    {
        Assert.Equal("-NoProfile -ExecutionPolicy Bypass -File \"C:\\Win Ease\\WinEasebuilder.ps1\" -GUI",
            LauncherLogic.BuildBuilderArguments(@"C:\Win Ease\WinEasebuilder.ps1", new string[0]));
    }

    [Theory]
    [InlineData("plain", "plain")]
    [InlineData("", "\"\"")]
    [InlineData("a b", "\"a b\"")]
    [InlineData("say \"hi\"", "\"say \\\"hi\\\"\"")]
    [InlineData("C:\\dir with space\\", "\"C:\\dir with space\\\\\"")]
    public void QuoteArgument_follows_command_line_rules(string input, string expected)
    {
        Assert.Equal(expected, LauncherLogic.QuoteArgument(input));
    }

    [Fact]
    public void JoinArguments_is_empty_for_no_arguments()
    {
        Assert.Equal("", LauncherLogic.JoinArguments(null));
        Assert.Equal("", LauncherLogic.JoinArguments(new string[0]));
    }

    [Fact]
    public void WinUiBuildArguments_run_the_build_script()
    {
        Assert.Equal(@"-NoProfile -ExecutionPolicy Bypass -File C:\x\build.ps1", LauncherLogic.BuildWinUiArguments(@"C:\x\build.ps1"));
    }

    [Fact]
    public void UnblockArguments_unblock_every_file_under_the_folder_without_needing_a_script_file()
    {
        string args = LauncherLogic.BuildUnblockArguments(@"C:\Users\O'Neil\WinEase\");
        Assert.StartsWith("-NoProfile -ExecutionPolicy Bypass -Command ", args);
        Assert.Contains(@"-LiteralPath 'C:\Users\O''Neil\WinEase'", args);
        Assert.Contains("Unblock-File", args);
    }

    [Theory]
    [InlineData(1223, true)]
    [InlineData(5, false)]
    [InlineData(0, false)]
    public void IsUacCancelled_matches_error_1223_only(int code, bool expected)
    {
        Assert.Equal(expected, LauncherLogic.IsUacCancelled(code));
    }

    [Theory]
    [InlineData(0, false)]
    [InlineData(1, true)]
    [InlineData(-1, true)]
    public void BuilderFailed_is_any_nonzero_exit(int code, bool expected)
    {
        Assert.Equal(expected, LauncherLogic.BuilderFailed(code));
        Assert.Equal(code, LauncherLogic.LauncherExitCode(code));
    }

    [Fact]
    public void LogsDirectory_is_below_the_install_folder()
    {
        Assert.Equal(Path.Combine(Dir, "logs"), LauncherLogic.LogsDirectory(Dir));
    }
}
