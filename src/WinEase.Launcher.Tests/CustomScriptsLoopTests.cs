#nullable enable
using System;
using System.Collections.Generic;
using System.Diagnostics;
using Xunit;
using Xunit.Abstractions;

public class CustomScriptsLoopTests
{
    private readonly ITestOutputHelper _output;

    public CustomScriptsLoopTests(ITestOutputHelper output)
    {
        _output = output;
    }

    private class MockUiStrings
    {
        public string Get(string key, string? fallback = null)
        {
            return key switch
            {
                "CS.Column.Name" => "Name",
                "CS.Column.Order" => "Order",
                "CS.Column.Type" => "Type",
                "CS.Column.Size" => "Size",
                "CS.Column.Condition" => "Condition",
                "CS.Column.OnError" => "On Error",
                "CS.Column.Description" => "Description",
                "CS.OnError.Warn" => "Warn",
                "CS.OnError.Stop" => "Stop",
                "CS.Legacy" => "Legacy",
                _ => fallback ?? key,
            };
        }
    }

    private sealed record ScriptData(string Name, string Order, string Type, string Size, string Condition, string OnError, string Description, string Location);

    // Baseline implementation as previously written in LoadCustomScriptsAsync
    private static List<string> BaselineScriptSummaries(List<ScriptData> scripts, MockUiStrings s)
    {
        string[] headers = { "CS.Column.Name", "CS.Column.Order", "CS.Column.Type", "CS.Column.Size", "CS.Column.Condition", "CS.Column.OnError", "CS.Column.Description" };
        string[] fields = { "Name", "Order", "Type", "Size", "Condition", "OnError", "Description" };

        var buttonHelpTexts = new List<string>(scripts.Count);
        for (int i = 0; i < scripts.Count; i++)
        {
            var script = scripts[i];
            bool legacy = script.Location == "Legacy";
            var summary = new List<string>();

            for (int c = 0; c < fields.Length; c++)
            {
                string value = fields[c] switch
                {
                    "Name" => script.Name,
                    "Order" => script.Order,
                    "Type" => script.Type,
                    "Size" => script.Size,
                    "Condition" => script.Condition,
                    "OnError" => script.OnError,
                    "Description" => script.Description,
                    _ => "",
                };
                if (fields[c] == "OnError") value = s.Get("CS.OnError." + value, value);
                if (c == 0 && legacy) value += " (" + s.Get("CS.Legacy") + ")";
                if (c > 0) summary.Add(s.Get(headers[c]) + ": " + value);
            }
            buttonHelpTexts.Add(string.Join(", ", summary));
        }
        return buttonHelpTexts;
    }

    // Optimized implementation matching the new code in LoadCustomScriptsAsync
    private static List<string> OptimizedScriptSummaries(List<ScriptData> scripts, MockUiStrings s)
    {
        string[] headers = { "CS.Column.Name", "CS.Column.Order", "CS.Column.Type", "CS.Column.Size", "CS.Column.Condition", "CS.Column.OnError", "CS.Column.Description" };
        string[] fields = { "Name", "Order", "Type", "Size", "Condition", "OnError", "Description" };

        var headerPrefixes = new string[headers.Length];
        for (int c = 1; c < headers.Length; c++)
        {
            headerPrefixes[c] = s.Get(headers[c]) + ": ";
        }
        string legacySuffix = " (" + s.Get("CS.Legacy") + ")";

        var buttonHelpTexts = new List<string>(scripts.Count);
        for (int i = 0; i < scripts.Count; i++)
        {
            var script = scripts[i];
            bool legacy = script.Location == "Legacy";
            var summary = new List<string>();

            for (int c = 0; c < fields.Length; c++)
            {
                string value = fields[c] switch
                {
                    "Name" => script.Name,
                    "Order" => script.Order,
                    "Type" => script.Type,
                    "Size" => script.Size,
                    "Condition" => script.Condition,
                    "OnError" => script.OnError,
                    "Description" => script.Description,
                    _ => "",
                };
                if (fields[c] == "OnError") value = s.Get("CS.OnError." + value, value);
                if (c == 0 && legacy) value += legacySuffix;
                if (c > 0) summary.Add(string.Concat(headerPrefixes[c], value));
            }
            buttonHelpTexts.Add(string.Join(", ", summary));
        }
        return buttonHelpTexts;
    }

    [Fact]
    public void OptimizedScriptSummaries_matches_baseline_behavior_exactly()
    {
        var s = new MockUiStrings();
        var scripts = new List<ScriptData>
        {
            new("Setup.ps1", "10", "PowerShell", "1.2 KB", "Always", "Warn", "Initial setup script", "Standard"),
            new("LegacyInit.bat", "20", "Batch", "500 B", "Never", "Stop", "Legacy initialization", "Legacy"),
            new("Cleanup.cmd", "30", "CMD", "2.1 KB", "OnSuccess", "Ignore", "Cleanup workspace", "Standard"),
        };

        var baseline = BaselineScriptSummaries(scripts, s);
        var optimized = OptimizedScriptSummaries(scripts, s);

        Assert.Equal(baseline.Count, optimized.Count);
        for (int i = 0; i < baseline.Count; i++)
        {
            Assert.Equal(baseline[i], optimized[i]);
        }
    }

    [Fact]
    public void Benchmark_custom_script_summary_performance_vs_baseline()
    {
        var s = new MockUiStrings();
        var scripts = new List<ScriptData>();
        for (int i = 0; i < 50; i++)
        {
            scripts.Add(new ScriptData($"Script_{i}.ps1", i.ToString(), "PowerShell", "1.5 KB", "Always", i % 2 == 0 ? "Warn" : "Stop", $"Script description {i}", i % 5 == 0 ? "Legacy" : "Standard"));
        }

        const int iterations = 10000;

        // Warm up
        for (int i = 0; i < 100; i++)
        {
            _ = BaselineScriptSummaries(scripts, s);
            _ = OptimizedScriptSummaries(scripts, s);
        }

        // Measure Baseline
        long baseMemBefore = GC.GetTotalAllocatedBytes(true);
        var swBase = Stopwatch.StartNew();
        for (int i = 0; i < iterations; i++)
        {
            _ = BaselineScriptSummaries(scripts, s);
        }
        swBase.Stop();
        long baseMemAfter = GC.GetTotalAllocatedBytes(true);
        long baseAllocated = baseMemAfter - baseMemBefore;

        // Measure Optimized
        long optMemBefore = GC.GetTotalAllocatedBytes(true);
        var swOpt = Stopwatch.StartNew();
        for (int i = 0; i < iterations; i++)
        {
            _ = OptimizedScriptSummaries(scripts, s);
        }
        swOpt.Stop();
        long optMemAfter = GC.GetTotalAllocatedBytes(true);
        long optAllocated = optMemAfter - optMemBefore;

        _output.WriteLine($"Baseline:  {swBase.ElapsedMilliseconds} ms, {baseAllocated / 1024.0:F2} KB allocated");
        _output.WriteLine($"Optimized: {swOpt.ElapsedMilliseconds} ms, {optAllocated / 1024.0:F2} KB allocated");

        double speedup = (double)swBase.ElapsedTicks / Math.Max(1, swOpt.ElapsedTicks);
        _output.WriteLine($"Speedup: {speedup:F2}x");

        Assert.True(swOpt.ElapsedTicks <= swBase.ElapsedTicks, "Optimized loop should be faster or equal to baseline");
        Assert.True(optAllocated < baseAllocated, "Optimized loop should allocate less memory than baseline");
    }
}
