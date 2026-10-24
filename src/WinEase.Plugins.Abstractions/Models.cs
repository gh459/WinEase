using System;
using System.Collections.Generic;

namespace WinEase.Plugins
{
    /// <summary>Version of the plugin contract. A plugin built against another major version is not loaded.</summary>
    public static class PluginApi
    {
        public const string AssemblyName = "WinEase.Plugins.Abstractions";
        public const int Major = 1;
    }

    /// <summary>Before / After the builder runs a phase. A plugin cannot replace a phase.</summary>
    public enum PhaseStage
    {
        Before = 0,
        After = 1
    }

    /// <summary>What the builder knows about the image that is being built.</summary>
    public sealed class ImageInfo
    {
        public ImageInfo(int build, int ubr, string edition, string architecture)
        {
            Build = build;
            Ubr = ubr;
            Edition = edition ?? string.Empty;
            Architecture = architecture ?? string.Empty;
        }

        /// <summary>Windows build number (for example 26100); 0 when it is not known (yet).</summary>
        public int Build { get; private set; }
        /// <summary>Update build revision; 0 when it is not known.</summary>
        public int Ubr { get; private set; }
        public string Edition { get; private set; }
        public string Architecture { get; private set; }
    }

    /// <summary>What a plugin says about itself.</summary>
    public sealed class PluginDescription
    {
        public PluginDescription()
        {
            Summary = string.Empty;
            Tweaks = new string[0];
            Phases = new string[0];
            ReplacesPhases = new string[0];
        }

        public string Summary { get; set; }
        /// <summary>Tweak keys the plugin implements or reads.</summary>
        public string[] Tweaks { get; set; }
        /// <summary>First build the plugin supports (inclusive); 0 = no limit.</summary>
        public int MinBuild { get; set; }
        /// <summary>Last build the plugin supports (inclusive); 0 = no limit.</summary>
        public int MaxBuild { get; set; }
        /// <summary>Phases OnPhase wants to be called for, for example "05-appx"; empty = all.</summary>
        public string[] Phases { get; set; }
        /// <summary>Reserved. A plugin that lists phases here is refused: phases cannot be replaced,
        /// because that would bypass the safety gates and the mount handling.</summary>
        public string[] ReplacesPhases { get; set; }
    }

    /// <summary>The argument of IWinEasePlugin.OnPhase.</summary>
    public sealed class PhaseContext
    {
        public PhaseContext(string phase, PhaseStage stage, IWinEaseHost host)
        {
            Phase = phase;
            Stage = stage;
            Host = host;
        }

        /// <summary>Phase name, for example "05-appx".</summary>
        public string Phase { get; private set; }
        public PhaseStage Stage { get; private set; }
        public IWinEaseHost Host { get; private set; }
    }

    // ---- data the contributor interfaces return -------------------------------------------------

    public sealed class RegistryEntry
    {
        public RegistryEntry()
        {
            Type = "REG_DWORD";
            Default = true;
        }

        /// <summary>Setting that gates the entry (IWinEaseHost.IsTweakEnabled); empty = always.</summary>
        public string Tweak { get; set; }
        /// <summary>Value of the setting when no profile sets it.</summary>
        public bool Default { get; set; }
        /// <summary>zSYSTEM, zSOFTWARE, zDEFAULT, zNTUSER or zCOMPONENTS.</summary>
        public string Hive { get; set; }
        public string Path { get; set; }
        /// <summary>Empty or "(default)" = the unnamed value.</summary>
        public string Name { get; set; }
        public string Type { get; set; }
        public string Data { get; set; }
        public int MinBuild { get; set; }
        public int MaxBuild { get; set; }
    }

    public sealed class FodRemoval
    {
        public FodRemoval() { Kind = "Package"; }
        public FodRemoval(string kind, string name) { Kind = kind; Name = name; }

        /// <summary>Package, Capability or Feature.</summary>
        public string Kind { get; set; }
        /// <summary>Name or wildcard pattern.</summary>
        public string Name { get; set; }
    }

    public sealed class ServiceStart
    {
        public ServiceStart() { }
        public ServiceStart(string name, int start) { Name = name; Start = start; }

        public string Name { get; set; }
        /// <summary>0 boot, 1 system, 2 automatic, 3 manual, 4 disabled.</summary>
        public int Start { get; set; }
    }

    /// <summary>The folders of the image a plugin file can be placed in. A plugin never names a folder itself.</summary>
    public enum ImageFileRoot
    {
        /// <summary>Windows\Setup\Scripts\Plugins\&lt;plugin id&gt; (default).</summary>
        PluginFolder = 0,
        /// <summary>Windows\Setup\Tools, where the post-install tools of WinEase live.</summary>
        SetupTools = 1
    }

    /// <summary>A file the builder puts into the image, by default below Windows\Setup\Scripts\Plugins\&lt;plugin id&gt;.</summary>
    public sealed class ImageFile
    {
        public ImageFile()
        {
            Root = ImageFileRoot.PluginFolder;
            WhenEnabled = true;
        }

        public ImageFile(string relativePath, byte[] content) : this()
        {
            RelativePath = relativePath;
            Content = content;
        }

        public string RelativePath { get; set; }
        public byte[] Content { get; set; }
        public ImageFileRoot Root { get; set; }
        /// <summary>Setting that gates the file: a component of config\schema.psd1 when the key names one, otherwise a tweak. Empty = always.</summary>
        public string Setting { get; set; }
        /// <summary>Value of the setting when nothing sets it.</summary>
        public bool SettingDefault { get; set; }
        /// <summary>The file is written when the setting has this value (false = written while the setting is off, like NoPostInstallAssets).</summary>
        public bool WhenEnabled { get; set; }
    }

    /// <summary>An AppX removal pattern with the setting that controls it (same meaning as AppxRemoval in config\schema.psd1).</summary>
    public sealed class AppxRemovalRule
    {
        public AppxRemovalRule() { }
        public AppxRemovalRule(string pattern, string option, bool invert)
        {
            Pattern = pattern;
            Option = option;
            Invert = invert;
        }

        /// <summary>Package name or wildcard pattern.</summary>
        public string Pattern { get; set; }
        /// <summary>Setting key of config\schema.psd1; empty = part of the default removal list (RemoveAppxBloatware).</summary>
        public string Option { get; set; }
        /// <summary>The setting is a "Keep..." option: the pattern applies while it is off.</summary>
        public bool Invert { get; set; }
    }

    public sealed class DismResult
    {
        public DismResult(int exitCode, string output)
        {
            ExitCode = exitCode;
            Output = output ?? string.Empty;
        }

        public int ExitCode { get; private set; }
        public string Output { get; private set; }
        public bool Succeeded { get { return ExitCode == 0 || ExitCode == 3010; } }
    }

    public enum LogLevel
    {
        Info = 0,
        Warning = 1,
        Error = 2
    }
}
