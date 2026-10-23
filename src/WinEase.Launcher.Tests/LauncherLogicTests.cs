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
    [InlineData(false, true, true)]
    [InlineData(false, false, false)]
    [InlineData(true, true, false)]
    [InlineData(true, false, false)]
    public void ShouldBuildWinUi_only_when_exe_missing_and_dotnet_present(bool exe, bool dotnet, bool expected)
    {
        Assert.Equal(expected, LauncherLogic.ShouldBuildWinUi(exe, dotnet));
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
