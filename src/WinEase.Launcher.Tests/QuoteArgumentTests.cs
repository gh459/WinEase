#nullable enable
using System;
using System.Diagnostics;
using System.Text;
using WinEase.Launcher;
using Xunit;
using Xunit.Abstractions;

public class QuoteArgumentTests
{
    private readonly ITestOutputHelper _output;

    public QuoteArgumentTests(ITestOutputHelper output)
    {
        _output = output;
    }

    // Baseline implementation as previously written (allocating new char[] per call)
    private static string BaselineQuoteArgument(string arg)
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

    [Theory]
    [InlineData("plain")]
    [InlineData("")]
    [InlineData(null)]
    [InlineData("a b")]
    [InlineData("say \"hi\"")]
    [InlineData("C:\\dir with space\\")]
    [InlineData("\ttabbed")]
    [InlineData("line\nbreak")]
    [InlineData("vertical\vtab")]
    [InlineData("\"already quoted\"")]
    [InlineData(@"\\server\share\file with space.ps1")]
    public void QuoteArgument_matches_baseline_behavior_for_all_inputs(string? input)
    {
        string baseline = BaselineQuoteArgument(input!);
        string optimized = LauncherLogic.QuoteArgument(input!);
        Assert.Equal(baseline, optimized);
    }

    [Fact]
    public void Benchmark_QuoteArgument_allocation_and_speedup()
    {
        string[] testArgs =
        {
            "-NoProfile",
            "-ExecutionPolicy",
            "Bypass",
            @"-File",
            @"C:\Program Files\WinEase\WinEasebuilder.ps1",
            @"-GUI",
            @"-Profile",
            @"extreme",
            @"--switch-with-quotes=""value""",
            @"plain_arg"
        };

        const int iterations = 100000;

        // Warmup
        for (int i = 0; i < 1000; i++)
        {
            foreach (var arg in testArgs)
            {
                _ = BaselineQuoteArgument(arg);
                _ = LauncherLogic.QuoteArgument(arg);
            }
        }

        // Measure Baseline
        long baseMemBefore = GC.GetTotalAllocatedBytes(true);
        var swBase = Stopwatch.StartNew();
        for (int i = 0; i < iterations; i++)
        {
            for (int j = 0; j < testArgs.Length; j++)
            {
                _ = BaselineQuoteArgument(testArgs[j]);
            }
        }
        swBase.Stop();
        long baseMemAfter = GC.GetTotalAllocatedBytes(true);
        long baseAllocated = baseMemAfter - baseMemBefore;

        // Measure Optimized
        long optMemBefore = GC.GetTotalAllocatedBytes(true);
        var swOpt = Stopwatch.StartNew();
        for (int i = 0; i < iterations; i++)
        {
            for (int j = 0; j < testArgs.Length; j++)
            {
                _ = LauncherLogic.QuoteArgument(testArgs[j]);
            }
        }
        swOpt.Stop();
        long optMemAfter = GC.GetTotalAllocatedBytes(true);
        long optAllocated = optMemAfter - optMemBefore;

        _output.WriteLine($"Baseline:  {swBase.ElapsedMilliseconds} ms, {baseAllocated / 1024.0:F2} KB allocated");
        _output.WriteLine($"Optimized: {swOpt.ElapsedMilliseconds} ms, {optAllocated / 1024.0:F2} KB allocated");

        double speedup = (double)swBase.ElapsedTicks / Math.Max(1, swOpt.ElapsedTicks);
        _output.WriteLine($"Speedup: {speedup:F2}x");

        Assert.True(swOpt.ElapsedTicks <= swBase.ElapsedTicks, "Optimized QuoteArgument should run faster than or equal to baseline");
        Assert.True(optAllocated < baseAllocated, "Optimized QuoteArgument should allocate significantly less memory");
    }
}
