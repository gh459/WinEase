# Benchmarking WinEase

**Status: no published results exist yet.** This project has not measured latency,
stutter, frame time, input lag or throughput for any preset or option. Wording in the
README such as "intended to reduce micro-stutter" describes what a setting is meant to
do, not a measured outcome. The effect of any setting depends on the hardware, the
Windows build and the drivers.

Until results are published here, treat every performance statement in this repository
as a hypothesis you can test on your own machine.

## What the bundled tools measure

| Tool | What it does |
|---|---|
| `tools/Measure-WinEaseGuestBaseline.ps1` | Runs inside the installed system (VM or physical). Writes one JSON report per run |
| `tools/Compare-WinEaseBenchmarks.ps1` | Reads history files from several runs and writes a Markdown comparison (median, IQR, standard deviation, percent change) of a baseline against an optimized (and optionally an experimental) series |
| `lib/WinEaseBenchmarks.ps1` | The statistics helpers used by the comparison (median, sample standard deviation, interquartile range) |

`Measure-WinEaseGuestBaseline.ps1` records:

- OS and hardware description (caption, version, build, architecture, RAM, CPU name and core counts).
- Disk footprint of the system drive (capacity, used, free).
- Memory and process load: used/free/committed/cached memory, process, thread and handle counts, and idle CPU percentage (average, minimum, maximum) over a sampling window (`-SampleSeconds`, default 15, range 5 to 120).
- Boot timing taken from the Diagnostics-Performance event 100 (main path and post-boot time), when that event exists. It may be missing until the system has restarted cleanly.
- Pass/fail health checks: network, audio service, IME, Windows Update and the Settings app.
- Process launch time of `cmd.exe` and `reg.exe`, cold and warm (skip with `-SkipResponseProbes`).

It labels each run with `-ConfigurationRole` (`Baseline`, `WinEase Standard`, `WinEase Experimental`, `Custom`), `-MeasurementPhase` (`ImmediatePostOOBE`, `StabilizedSteadyState`, `PostUpdate`) and `-RunIndex`, and can append the run to a history file (`-HistoryPath`).

### What they do not measure

- Frame time, FPS, 1% / 0.1% lows or any in-game behavior.
- Input latency, DPC/ISR latency, timer resolution or scheduler jitter.
- Network latency or throughput.
- Storage throughput or application launch time beyond the two small `cmd.exe` / `reg.exe` probes.
- Power use, temperature or battery life.

So the tools can support claims about footprint, idle load and boot time. They cannot
support claims about latency or stutter. Those need other instruments (for example
LatencyMon for DPC/ISR latency, or PresentMon / CapFrameX for frame times), used
the same way for the baseline and the optimized system.

## How to run a comparison

1. Install the baseline system (stock Windows, or the `none` preset) and the optimized system on identical hardware or identical VM settings. Use the same Windows ISO for both.
2. Let each system finish setup, restart once, and wait for it to settle (use `-MeasurementPhase StabilizedSteadyState`).
3. On each system run the tool several times (at least 5 runs per configuration; more is better), changing `-RunIndex` and using `-HistoryPath` to collect the runs, for example:

   ```powershell
   .\tools\Measure-WinEaseGuestBaseline.ps1 -ConfigurationRole Baseline -RunIndex 1 -HistoryPath .\baseline-history.json
   ```

4. Compare the history files:

   ```powershell
   .\tools\Compare-WinEaseBenchmarks.ps1 -BaselineHistoryPath .\baseline-history.json -OptimizedHistoryPath .\optimized-history.json
   ```

5. If you add your own latency or frame-time measurement, record it with the same run count and report median and spread for it too.

Reboot between runs if you measure boot time; a boot time is only one sample per boot.

## Required reporting fields

A result is not comparable, and should not be quoted, unless it states all of these:

| Field | Example / note |
|---|---|
| Windows build and edition | e.g. Windows 11 Pro 24H2, build number from `winver` |
| Source ISO | name, build, language |
| Hardware | CPU model, GPU model, RAM size and speed, storage model; or VM host and VM settings (vCPU, RAM, disk type) |
| Power plan | for both systems; the optimized preset may switch the plan, so state the active one at measurement time |
| Drivers | GPU driver version, chipset driver, audio driver; state whether they are identical on both systems |
| Baseline vs optimized | what the baseline is (stock ISO, `none` preset) and which WinEase preset and options the optimized system used (attach the profile JSON if possible) |
| Method | tool and version, `-SampleSeconds`, `-MeasurementPhase`, background load, whether the system was online, whether Defender/Windows Update were active |
| Run count | number of runs per configuration |
| Result | median and a spread (IQR and/or standard deviation) per metric, not a single best run |
| Caveats | anything that differed between the systems |

Quote medians with their spread. Do not quote a percentage improvement computed from
a single run, and do not quote a best case.

## Results template

Copy this block for each comparison.

```markdown
### <short title, date>

- Windows: <edition, version, build>   ISO: <name>
- Hardware: <CPU / GPU / RAM / storage>  (or VM: <host, vCPU, RAM, disk>)
- Drivers: <GPU, chipset, audio versions>
- Power plan: baseline <name> / optimized <name>
- Baseline: <stock ISO | none preset>   Optimized: <preset + changed options, profile attached?>
- Method: <tool + version, SampleSeconds, MeasurementPhase, other instruments>
- Runs: baseline <n>, optimized <n>

| Metric | Baseline median | Baseline IQR | Optimized median | Optimized IQR | Change |
|---|---|---|---|---|---|
| <metric> | | | | | |

Notes / caveats: <...>
```

## Published results

None yet. If you publish results, add them below this line using the template above,
with the raw JSON history files attached.
