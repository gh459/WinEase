using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Linq;
using Xunit;
using Xunit.Abstractions;

public class IssueFilteringTests
{
    private readonly ITestOutputHelper _output;

    public IssueFilteringTests(ITestOutputHelper output)
    {
        _output = output;
    }

    public record InputIssue(string Field, string Severity, string Text, bool Confirm);

    // Baseline implementation in ShowIssues()
    private static int BaselineShowIssues(List<InputIssue> issues, string[] fieldKeys)
    {
        int processedCount = 0;
        foreach (var key in fieldKeys)
        {
            var mine = issues.Where(i => i.Field == key || (key == "WorkDir" && i.Field == "OutputDir")).ToList();
            if (mine.Count == 0)
            {
                continue;
            }
            processedCount += mine.Count;
        }
        return processedCount;
    }

    // Optimized implementation in ShowIssues()
    private static int OptimizedShowIssues(List<InputIssue> issues, string[] fieldKeys)
    {
        int processedCount = 0;
        var issuesByField = issues.ToLookup(i => i.Field == "OutputDir" ? "WorkDir" : i.Field, StringComparer.Ordinal);
        foreach (var key in fieldKeys)
        {
            var mine = issuesByField[key];
            if (!mine.Any())
            {
                continue;
            }
            processedCount += mine.Count();
        }
        return processedCount;
    }

    [Fact]
    public void LookupFilter_matches_baseline_behavior_exactly()
    {
        var issues = new List<InputIssue>
        {
            new("SourceDrive", "Error", "Invalid source drive", false),
            new("WorkDir", "Warning", "Disk space low", false),
            new("OutputDir", "Error", "Output path non-existent", false),
            new("Index", "Warning", "Index out of range", false),
            new("InjectDrivers", "Error", "Driver inf missing", false),
            new("OutputDir", "Warning", "Permission check warning", false),
            new("UserName", "Error", "Username reserved", false),
        };

        var fields = new[] { "SourceDrive", "WorkDir", "Index", "InjectDrivers", "UserName", "ComputerName" };
        var issuesByField = issues.ToLookup(i => i.Field == "OutputDir" ? "WorkDir" : i.Field, StringComparer.Ordinal);

        foreach (var field in fields)
        {
            var baseline = issues.Where(i => i.Field == field || (field == "WorkDir" && i.Field == "OutputDir")).ToList();
            var optimized = issuesByField[field].ToList();

            Assert.Equal(baseline.Count, optimized.Count);
            for (int i = 0; i < baseline.Count; i++)
            {
                Assert.Equal(baseline[i].Field, optimized[i].Field);
                Assert.Equal(baseline[i].Severity, optimized[i].Severity);
                Assert.Equal(baseline[i].Text, optimized[i].Text);
            }
        }
    }

    [Fact]
    public void Benchmark_lookup_filter_performance_vs_baseline()
    {
        var fields = new[] { "SourceDrive", "WorkDir", "Index", "InjectDrivers", "UserName", "ComputerName" };

        // Realistic issue list size from input validation (5-10 issues)
        var issues = new List<InputIssue>
        {
            new("SourceDrive", "Error", "Invalid path", false),
            new("WorkDir", "Warning", "Space low", false),
            new("OutputDir", "Error", "Permission denied", false),
            new("UserName", "Error", "Invalid character", false)
        };

        const int iterations = 100000;

        // Warm up
        for (int i = 0; i < 1000; i++)
        {
            _ = BaselineShowIssues(issues, fields);
            _ = OptimizedShowIssues(issues, fields);
        }

        // Measure Baseline
        long baseMemBefore = GC.GetTotalAllocatedBytes(true);
        var swBase = Stopwatch.StartNew();
        for (int i = 0; i < iterations; i++)
        {
            _ = BaselineShowIssues(issues, fields);
        }
        swBase.Stop();
        long baseMemAfter = GC.GetTotalAllocatedBytes(true);
        long baseAllocated = baseMemAfter - baseMemBefore;

        // Measure Optimized
        long optMemBefore = GC.GetTotalAllocatedBytes(true);
        var swOpt = Stopwatch.StartNew();
        for (int i = 0; i < iterations; i++)
        {
            _ = OptimizedShowIssues(issues, fields);
        }
        swOpt.Stop();
        long optMemAfter = GC.GetTotalAllocatedBytes(true);
        long optAllocated = optMemAfter - optMemBefore;

        _output.WriteLine($"Baseline:  {swBase.ElapsedMilliseconds} ms, {baseAllocated / 1024.0:F2} KB allocated");
        _output.WriteLine($"Optimized: {swOpt.ElapsedMilliseconds} ms, {optAllocated / 1024.0:F2} KB allocated");

        double speedup = (double)swBase.ElapsedTicks / Math.Max(1, swOpt.ElapsedTicks);
        _output.WriteLine($"Speedup: {speedup:F2}x");

        Assert.True(swOpt.ElapsedTicks <= swBase.ElapsedTicks, "Optimized lookup filter should be faster or equal to baseline filtering");
        Assert.True(optAllocated < baseAllocated, "Optimized lookup filter should allocate significantly less memory");
    }
}
