namespace WinEase.Plugins.Builtin.Latency
{
    /// <summary>
    /// The latency tweaks of phase 10-registry: hardware-accelerated GPU scheduling, power throttling, the
    /// foreground quantum and DPC thread settings, the Games and Pro Audio MMCSS task profiles, and the
    /// multimedia / MSMQ network settings (GamingNetworkTweaks). The definition of every tweak (key, alias,
    /// switch, default) stays in config\schema.psd1; this plugin only implements them. It writes through the
    /// host after phase 10-registry has run, while the offline hives are still loaded, so with DryRun the
    /// writes are recorded and do nothing.
    /// The NVIDIA PowerMizer / DPC profile writes (NvidiaLowLatency) stay in the builder.
    /// </summary>
    public sealed class LatencyPlugin : IWinEasePlugin
    {
        public const string PluginId = "winease.builtin.latency";
        public const string DataVersion = "1.0.0";
        public const string Phase = "10-registry";

        private const string SystemHive = "zSYSTEM";
        private const string Software = "zSOFTWARE";
        private const string MmcssProfile = @"Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile";
        private const string Dword = "REG_DWORD";
        private const string Sz = "REG_SZ";

        public string Id { get { return PluginId; } }
        public string Version { get { return DataVersion; } }

        public PluginDescription Describe()
        {
            PluginDescription d = new PluginDescription();
            d.Summary = "Latency tweaks: HAGS, power throttling, scheduler and DPC settings, MMCSS task profiles, gaming network settings.";
            d.Tweaks = new string[] { "DisablePowerThrottling", "ThreadDpcEnable", "LowLatencyAudioMMCSS", "MMCSSGaming", "EnableHAGS", "GamingNetworkTweaks" };
            d.Phases = new string[] { Phase };
            return d;
        }

        public bool AppliesTo(ImageInfo image)
        {
            return true;
        }

        public void OnPhase(PhaseContext context)
        {
            if (context.Phase != Phase || context.Stage != PhaseStage.After) return;
            IWinEaseHost host = context.Host;

            // The umbrella switch of the AtlasOS / ReviOS low-latency work: foreground quantum scheduling
            // plus the Games MMCSS profile, even without the individual tweaks.
            bool atlasReviOS = host.IsComponentEnabled("AtlasReviOSMode", false);

            // --- power and scheduler ---
            if (host.IsTweakEnabled("DisablePowerThrottling", true))
            {
                Set(host, SystemHive, @"ControlSet001\Control\Power\PowerThrottling", "PowerThrottlingOff", Dword, "1");
            }
            if (host.IsTweakEnabled("ThreadDpcEnable", false))
            {
                Set(host, SystemHive, @"ControlSet001\Control\Session Manager\Kernel", "ThreadDpcEnable", Dword, "1");
                Set(host, SystemHive, @"ControlSet001\Control\PriorityControl", "Win32PrioritySeparation", Dword, "38");
            }
            else if (atlasReviOS)
            {
                // Atlas/ReviOS baseline: foreground quantum scheduling without the DPC tweak.
                Set(host, SystemHive, @"ControlSet001\Control\PriorityControl", "Win32PrioritySeparation", Dword, "38");
            }

            // --- MMCSS: Pro Audio ---
            if (host.IsComponentEnabled("KeepAudioTweaks", false) || host.IsComponentEnabled("DAWMode", false) || host.IsTweakEnabled("LowLatencyAudioMMCSS", false))
            {
                host.Log(LogLevel.Info, "[Audio DAW] Configuring low-latency Pro Audio MMCSS task profile...");
                string path = MmcssProfile + @"\Tasks\Pro Audio";
                Set(host, Software, path, "Priority", Dword, "1");
                Set(host, Software, path, "Scheduling Category", Sz, "High");
                Set(host, Software, path, "SFIO Priority", Sz, "High");
                Set(host, Software, path, "Background Only", Sz, "False");
                Set(host, Software, path, "Clock Rate", Dword, "10000");
                Set(host, Software, path, "GPU Priority", Dword, "8");
            }

            // --- MMCSS: Games ---
            if (host.IsComponentEnabled("MMCSSGaming", false) || host.IsTweakEnabled("MMCSSGaming", false) || atlasReviOS)
            {
                host.Log(LogLevel.Info, "[Gaming] Configuring Games MMCSS task profile...");
                string path = MmcssProfile + @"\Tasks\Games";
                Set(host, Software, path, "Priority", Dword, "6");
                Set(host, Software, path, "Scheduling Category", Sz, "High");
                Set(host, Software, path, "SFIO Priority", Sz, "High");
                Set(host, Software, path, "GPU Priority", Dword, "8");
                Set(host, Software, path, "Affinity", Dword, "0");
                Set(host, Software, path, "Background Only", Sz, "False");
                Set(host, Software, path, "Clock Rate", Dword, "10000");
            }

            // --- GPU scheduling (HAGS) ---
            if (host.IsTweakGroupEnabled("GPULatency", false) || host.IsTweakEnabled("EnableHAGS", true))
            {
                Set(host, SystemHive, @"ControlSet001\Control\GraphicsDrivers", "HwSchMode", Dword, "2");
            }

            // --- GamingNetworkTweaks ---
            // Per-adapter TcpAckFrequency needs interface GUIDs that only exist online; these are the offline-safe parts.
            if (host.IsTweakEnabled("GamingNetworkTweaks", true))
            {
                Set(host, Software, MmcssProfile, "NetworkThrottlingIndex", Dword, "0xffffffff");
                Set(host, Software, @"Microsoft\MSMQ\Parameters", "TCPNoDelay", Dword, "1");
            }
        }

        private static void Set(IWinEaseHost host, string hive, string path, string name, string type, string data)
        {
            host.SetOfflineRegistry(hive, path, name, type, data);
        }
    }
}
