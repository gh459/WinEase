using System;
using System.Collections.Generic;

namespace WinEase.Plugins.Builtin.UpstreamSync
{
    /// <summary>
    /// The tweaks WinEase adopted from the tools it credits (docs/dev/upstream-sync-2026-10.md, decision "adopted"),
    /// as data: registry values and AppX packages. The builder applies them like the entries of config\registry
    /// and the AppxRemoval list of config\schema.psd1 (same tweak gate, same defaults). The definition of every
    /// tweak (key, alias, switch, default) stays in config\schema.psd1; only the values live here.
    /// Following the next upstream release means changing this data and raising Version.
    /// </summary>
    public sealed class UpstreamSyncPlugin : IWinEasePlugin, IRegistryContributor, IAppxRemovalRuleContributor
    {
        /// <summary>Plugin id; also the folder name below Windows\Setup\Scripts\Plugins.</summary>
        public const string PluginId = "winease.builtin.upstreamsync";
        /// <summary>The upstream sync this data stands for.</summary>
        public const string DataVersion = "2026.10.1";

        public string Id { get { return PluginId; } }
        public string Version { get { return DataVersion; } }

        public PluginDescription Describe()
        {
            PluginDescription d = new PluginDescription();
            d.Summary = "Tweaks adopted from the credited upstream tools (upstream sync 2026-10): registry values and AppX removals.";
            d.Tweaks = TweakKeys();
            return d;
        }

        public bool AppliesTo(ImageInfo image)
        {
            return true;
        }

        public void OnPhase(PhaseContext context)
        {
            // data only: the builder applies the contributions in phases 05-appx and 10-registry
        }

        public IEnumerable<RegistryEntry> GetRegistryEntries(ImageInfo image)
        {
            return RegistryData();
        }

        public IEnumerable<AppxRemovalRule> GetAppxRemovalRules(ImageInfo image)
        {
            return AppxData();
        }

        /// <summary>The tweak keys the registry entries are gated by.</summary>
        public static string[] TweakKeys()
        {
            // Use HashSet to avoid O(N^2) linear searching during key deduplication.
            var keys = new HashSet<string>(System.StringComparer.Ordinal);
            foreach (RegistryEntry entry in RegistryData())
            {
                keys.Add(entry.Tweak);
            }
            string[] result = new string[keys.Count];
            keys.CopyTo(result, 0);
            Array.Sort(result, System.StringComparer.Ordinal);
            return result;
        }

        public static IList<AppxRemovalRule> AppxData()
        {
            List<AppxRemovalRule> rules = new List<AppxRemovalRule>();
            // default removal list (RemoveAppxBloatware): Option is empty
            rules.Add(new AppxRemovalRule("*WidgetsPlatformRuntime*", "", false));
            rules.Add(new AppxRemovalRule("*RoyalRevolt*", "", false));
            rules.Add(new AppxRemovalRule("king.com.*", "", false));
            rules.Add(new AppxRemovalRule("*Microsoft.PCManager*", "", false));
            rules.Add(new AppxRemovalRule("*Microsoft.MicrosoftStickyNotes*", "", false));
            rules.Add(new AppxRemovalRule("*Microsoft.Office.OneNote*", "", false));
            rules.Add(new AppxRemovalRule("*Microsoft.SkypeApp*", "", false));
            rules.Add(new AppxRemovalRule("*Microsoft.Microsoft3DViewer*", "", false));
            rules.Add(new AppxRemovalRule("*Microsoft.Messaging*", "", false));
            rules.Add(new AppxRemovalRule("*Microsoft.Whiteboard*", "", false));
            return rules;
        }

        public static IList<RegistryEntry> RegistryData()
        {
            List<RegistryEntry> list = new List<RegistryEntry>();
            // --- from ai.psd1
            Add(list, "DisableWindowsAI", true, "zSOFTWARE", @"Policies\Microsoft\Windows\WindowsAI", @"DisableAgentConnectors", "REG_DWORD", @"2");
            Add(list, "DisableWindowsAI", true, "zSOFTWARE", @"Policies\Microsoft\Windows\WindowsAI", @"DisableAgentWorkspaces", "REG_DWORD", @"2");
            Add(list, "DisableWindowsAI", true, "zSOFTWARE", @"Policies\Microsoft\Windows\WindowsAI", @"DisableRemoteAgentConnectors", "REG_DWORD", @"2");
            Add(list, "DisableWindowsAI", true, "zSOFTWARE", @"Policies\WindowsNotepad", @"DisableAIFeatures", "REG_DWORD", @"1");
            Add(list, "DisableWindowsAI", true, "zSOFTWARE", @"Policies\Microsoft\Windows\WindowsAI", @"AllowRecallExport", "REG_DWORD", @"0");
            Add(list, "DisableWindowsAI", true, "zDEFAULT", @"Software\Policies\Microsoft\Windows\WindowsAI", @"DisableRecallDataProviders", "REG_DWORD", @"1");
            Add(list, "DisableWindowsAI", true, "zNTUSER", @"Software\Policies\Microsoft\Windows\WindowsAI", @"DisableRecallDataProviders", "REG_DWORD", @"1");
            Add(list, "DisableWindowsAI", true, "zSOFTWARE", @"Microsoft\Windows\CurrentVersion\Policies\Paint", @"DisableCocreator", "REG_DWORD", @"1");
            Add(list, "DisableWindowsAI", true, "zSOFTWARE", @"Microsoft\Windows\CurrentVersion\Policies\Paint", @"DisableGenerativeFill", "REG_DWORD", @"1");
            Add(list, "DisableWindowsAI", true, "zSOFTWARE", @"Microsoft\Windows\CurrentVersion\Policies\Paint", @"DisableImageCreator", "REG_DWORD", @"1");
            Add(list, "DisableWindowsAI", true, "zSOFTWARE", @"Policies\Microsoft\Windows\System", @"EnableSmartClipboard", "REG_DWORD", @"0");
            Add(list, "DisableWindowsAI", true, "zSOFTWARE", @"Policies\Microsoft\Windows\AppPrivacy", @"LetAppsAccessSystemAIModels", "REG_DWORD", @"2");
            Add(list, "DisableWindowsAI", true, "zSOFTWARE", @"Policies\Microsoft\Windows\AppPrivacy", @"LetAppsAccessGenerativeAI", "REG_DWORD", @"2");
            Add(list, "DisableCopilot", true, "zSOFTWARE", @"Policies\Microsoft\Edge", @"CopilotCDPPageContext", "REG_DWORD", @"0");
            Add(list, "DisableCopilot", true, "zSOFTWARE", @"Policies\Microsoft\Windows\WindowsAI", @"RemoveMicrosoftCopilotApp", "REG_DWORD", @"1");
            Add(list, "DisableCopilot", true, "zSOFTWARE", @"Policies\Microsoft\Edge", @"EdgeEntraCopilotPageContext", "REG_DWORD", @"0");
            Add(list, "DisableCopilot", true, "zSOFTWARE", @"Policies\Microsoft\Edge", @"Microsoft365CopilotChatIconEnabled", "REG_DWORD", @"0");
            Add(list, "DisableCopilot", true, "zSOFTWARE", @"Policies\Microsoft\Edge", @"EdgeHistoryAISearchEnabled", "REG_DWORD", @"0");
            Add(list, "DisableCopilot", true, "zSOFTWARE", @"Policies\Microsoft\Edge", @"ComposeInlineEnabled", "REG_DWORD", @"0");
            Add(list, "DisableCopilot", true, "zSOFTWARE", @"Policies\Microsoft\Edge", @"NewTabPageBingChatEnabled", "REG_DWORD", @"0");
            Add(list, "DisableCopilot", true, "zSOFTWARE", @"Policies\Microsoft\Edge", @"GenAILocalFoundationalModelSettings", "REG_DWORD", @"1");
            Add(list, "DisableCopilot", true, "zNTUSER", @"Software\Microsoft\Windows\Shell\Copilot", @"IsCopilotAvailable", "REG_DWORD", @"0");
            Add(list, "DisableCopilot", true, "zDEFAULT", @"Software\Microsoft\Windows\Shell\Copilot", @"IsCopilotAvailable", "REG_DWORD", @"0");
            // --- from cloud-content.psd1
            Add(list, "DisableCloudContent", true, "zSOFTWARE", @"Policies\Microsoft\Edge", @"DefaultBrowserSettingsCampaignEnabled", "REG_DWORD", @"0");
            Add(list, "DisableCloudContent", true, "zSOFTWARE", @"Policies\Microsoft\Edge", @"DefaultBrowserSettingEnabled", "REG_DWORD", @"0");
            Add(list, "DisableCloudContent", true, "zSOFTWARE", @"Policies\Microsoft\Edge", @"ShowRecommendationsEnabled", "REG_DWORD", @"0");
            Add(list, "DisableCloudContent", true, "zSOFTWARE", @"Policies\Microsoft\Edge", @"SpotlightExperiencesAndRecommendationsEnabled", "REG_DWORD", @"0");
            Add(list, "DisableCloudContent", true, "zSOFTWARE", @"Policies\Microsoft\Edge", @"UserFeedbackAllowed", "REG_DWORD", @"0");
            Add(list, "DisableCloudContent", true, "zSOFTWARE", @"Policies\Microsoft\Edge", @"ShowAcrobatSubscriptionButton", "REG_DWORD", @"0");
            Add(list, "DisableCloudContent", true, "zSOFTWARE", @"Policies\Microsoft\Edge", @"WalletDonationEnabled", "REG_DWORD", @"0");
            Add(list, "DisableCloudContent", true, "zNTUSER", @"Software\Microsoft\Windows\CurrentVersion\Notifications\Settings\Windows.SystemToast.BackupReminder", @"Enabled", "REG_DWORD", @"0");
            Add(list, "DisableCloudContent", true, "zDEFAULT", @"Software\Microsoft\Windows\CurrentVersion\Notifications\Settings\Windows.SystemToast.BackupReminder", @"Enabled", "REG_DWORD", @"0");
            Add(list, "DisableCloudContent", true, "zNTUSER", @"Software\Microsoft\Windows\CurrentVersion\UserProfileEngagement", @"ScoobeSystemSettingEnabled", "REG_DWORD", @"0");
            Add(list, "DisableCloudContent", true, "zDEFAULT", @"Software\Microsoft\Windows\CurrentVersion\UserProfileEngagement", @"ScoobeSystemSettingEnabled", "REG_DWORD", @"0");
            Add(list, "DisableCloudContent", true, "zNTUSER", @"Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced", @"Start_AccountNotifications", "REG_DWORD", @"0");
            Add(list, "DisableCloudContent", true, "zDEFAULT", @"Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced", @"Start_AccountNotifications", "REG_DWORD", @"0");
            Add(list, "DisableCloudContent", true, "zNTUSER", @"Software\Microsoft\Windows\CurrentVersion\SystemSettings\AccountNotifications", @"EnableAccountNotifications", "REG_DWORD", @"0");
            Add(list, "DisableCloudContent", true, "zDEFAULT", @"Software\Microsoft\Windows\CurrentVersion\SystemSettings\AccountNotifications", @"EnableAccountNotifications", "REG_DWORD", @"0");
            Add(list, "DisableCloudContent", true, "zSOFTWARE", @"Policies\Microsoft\Windows\CloudContent", @"DisableWindowsSpotlightOnDesktop", "REG_DWORD", @"1");
            Add(list, "DisableCloudContent", true, "zNTUSER", @"Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager", @"RotatingLockScreenOverlayEnabled", "REG_DWORD", @"0");
            Add(list, "DisableCloudContent", true, "zDEFAULT", @"Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager", @"RotatingLockScreenOverlayEnabled", "REG_DWORD", @"0");
            Add(list, "DisableCloudContent", true, "zNTUSER", @"Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager", @"RotatingLockScreenEnabled", "REG_DWORD", @"0");
            Add(list, "DisableCloudContent", true, "zDEFAULT", @"Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager", @"RotatingLockScreenEnabled", "REG_DWORD", @"0");
            Add(list, "DisableCloudContent", true, "zSOFTWARE", @"Policies\Microsoft\Edge", @"EdgeShoppingAssistantEnabled", "REG_DWORD", @"0");
            Add(list, "DisableCloudContent", true, "zSOFTWARE", @"Policies\Microsoft\Edge", @"StartupBoostEnabled", "REG_DWORD", @"0");
            Add(list, "DisableCloudContent", true, "zSOFTWARE", @"Policies\Microsoft\Edge", @"HideFirstRunExperience", "REG_DWORD", @"1");
            Add(list, "DisableCloudContent", true, "zSOFTWARE", @"Policies\Microsoft\WindowsMediaPlayer", @"DisableAutoUpdate", "REG_DWORD", @"1");
            // --- from cross-device.psd1
            Add(list, "DisableCrossDevice", true, "zSOFTWARE", @"Microsoft\Windows\CurrentVersion\Shell\ShellUIHosts\CrossDeviceResumeHost", @"ProcessPath", "REG_SZ", @"%SystemRoot%\system32\ShellHost.exe");
            // --- from performance.psd1
            Add(list, "DisableSuperfetch", true, "zSOFTWARE", @"Microsoft\Windows NT\CurrentVersion\EMDMgmt", @"GroupPolicyDisallowCaches", "REG_DWORD", @"1");
            Add(list, "DisableSuperfetch", true, "zSOFTWARE", @"Microsoft\Windows NT\CurrentVersion\EMDMgmt", @"AllowNewCachesByDefault", "REG_DWORD", @"0");
            // --- from privacy.psd1
            Add(list, "DisableTelemetryAndDiagnostics", true, "zNTUSER", @"Software\Microsoft\InputPersonalization\TrainedDataStore", @"HarvestContacts", "REG_DWORD", @"0");
            Add(list, "DisableTelemetryAndDiagnostics", true, "zDEFAULT", @"Software\Microsoft\InputPersonalization\TrainedDataStore", @"HarvestContacts", "REG_DWORD", @"0");
            Add(list, "DisableTelemetryAndDiagnostics", true, "zNTUSER", @"Software\Microsoft\Personalization\Settings", @"AcceptedPrivacyPolicy", "REG_DWORD", @"0");
            Add(list, "DisableTelemetryAndDiagnostics", true, "zDEFAULT", @"Software\Microsoft\Personalization\Settings", @"AcceptedPrivacyPolicy", "REG_DWORD", @"0");
            Add(list, "DisableTelemetryAndDiagnostics", true, "zNTUSER", @"Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced", @"Start_TrackProgs", "REG_DWORD", @"0");
            Add(list, "DisableTelemetryAndDiagnostics", true, "zDEFAULT", @"Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced", @"Start_TrackProgs", "REG_DWORD", @"0");
            Add(list, "DisableTelemetryAndDiagnostics", true, "zSOFTWARE", @"Policies\Microsoft\Edge", @"DiagnosticData", "REG_DWORD", @"0");
            Add(list, "DisableTelemetryAndDiagnostics", true, "zSOFTWARE", @"Policies\Microsoft\Edge", @"PersonalizationReportingEnabled", "REG_DWORD", @"0");
            Add(list, "DisableTelemetryAndDiagnostics", true, "zSOFTWARE", @"Policies\Microsoft\InputPersonalization", @"AllowInputPersonalization", "REG_DWORD", @"0");
            Add(list, "DisableTelemetryAndDiagnostics", true, "zNTUSER", @"Software\Policies\Microsoft\Windows\CloudContent", @"DisableTailoredExperiencesWithDiagnosticData", "REG_DWORD", @"1");
            Add(list, "DisableTelemetryAndDiagnostics", true, "zDEFAULT", @"Software\Policies\Microsoft\Windows\CloudContent", @"DisableTailoredExperiencesWithDiagnosticData", "REG_DWORD", @"1");
            Add(list, "DisableTelemetryAndDiagnostics", true, "zNTUSER", @"Software\Microsoft\Narrator\NoRoam", @"OnlineServicesEnabled", "REG_DWORD", @"0");
            Add(list, "DisableTelemetryAndDiagnostics", true, "zDEFAULT", @"Software\Microsoft\Narrator\NoRoam", @"OnlineServicesEnabled", "REG_DWORD", @"0");
            Add(list, "DisableTelemetryAndDiagnostics", true, "zSYSTEM", @"ControlSet001\Control\Session Manager\Power", @"SleepStudyDisabled", "REG_DWORD", @"1");
            Add(list, "DisableTelemetryAndDiagnostics", true, "zSOFTWARE", @"Policies\Microsoft\Edge", @"Edge3PSerpTelemetryEnabled", "REG_DWORD", @"0");
            Add(list, "DisableActivityHistory", true, "zSOFTWARE", @"Policies\Microsoft\Windows\WindowsBackup", @"DisableBackupUI", "REG_DWORD", @"1");
            Add(list, "DisableActivityHistory", true, "zSOFTWARE", @"Microsoft\Windows\CurrentVersion\WindowsBackup", @"DisableMonitoring", "REG_DWORD", @"1");
            Add(list, "DisableDiagnosticData", true, "zSOFTWARE", @"Policies\Microsoft\Windows Defender\Spynet", @"SubmitSamplesConsent", "REG_DWORD", @"2");
            Add(list, "DisableDiagnosticData", true, "zSOFTWARE", @"Policies\Microsoft\MRT", @"DontReportInfectionInformation", "REG_DWORD", @"1");
            // --- from start-search.psd1
            Add(list, "DisableWebSearch", true, "zNTUSER", @"Software\Microsoft\Windows\CurrentVersion\SearchSettings", @"IsDynamicSearchBoxEnabled", "REG_DWORD", @"0");
            Add(list, "DisableWebSearch", true, "zDEFAULT", @"Software\Microsoft\Windows\CurrentVersion\SearchSettings", @"IsDynamicSearchBoxEnabled", "REG_DWORD", @"0");
            Add(list, "DisableWebSearch", true, "zNTUSER", @"Software\Microsoft\Windows\CurrentVersion\SearchSettings", @"IsDeviceSearchHistoryEnabled", "REG_DWORD", @"0");
            Add(list, "DisableWebSearch", true, "zDEFAULT", @"Software\Microsoft\Windows\CurrentVersion\SearchSettings", @"IsDeviceSearchHistoryEnabled", "REG_DWORD", @"0");
            Add(list, "DisableWebSearch", true, "zNTUSER", @"Software\Microsoft\Windows\CurrentVersion\SearchSettings", @"IsWebSuggestionsEnabled", "REG_DWORD", @"0");
            Add(list, "DisableWebSearch", true, "zDEFAULT", @"Software\Microsoft\Windows\CurrentVersion\SearchSettings", @"IsWebSuggestionsEnabled", "REG_DWORD", @"0");
            Add(list, "DisableWebSearch", true, "zNTUSER", @"Software\Microsoft\Windows\CurrentVersion\SearchSettings", @"IsStoreSuggestionsEnabled", "REG_DWORD", @"0");
            Add(list, "DisableWebSearch", true, "zDEFAULT", @"Software\Microsoft\Windows\CurrentVersion\SearchSettings", @"IsStoreSuggestionsEnabled", "REG_DWORD", @"0");
            Add(list, "DisableWebSearch", true, "zSOFTWARE", @"Microsoft\WindowsRuntime\ActivatableClassId\WinStore.Tasks.WindowsSearchTask", @"ActivationType", "REG_DWORD", @"4294967295");
            Add(list, "DisableWebSearch", true, "zSOFTWARE", @"Microsoft\WindowsRuntime\ActivatableClassId\WinStore.Tasks.WindowsSearchTask", @"Server", "REG_SZ", @"");
            Add(list, "DisableWidgets", true, "zSOFTWARE", @"Policies\Microsoft\Windows\Windows Feeds", @"EnableFeeds", "REG_DWORD", @"0");
            Add(list, "HideRecommendedSection", true, "zNTUSER", @"Software\Microsoft\Windows\CurrentVersion\Start", @"ShowRecentList", "REG_DWORD", @"0");
            Add(list, "HideRecommendedSection", true, "zDEFAULT", @"Software\Microsoft\Windows\CurrentVersion\Start", @"ShowRecentList", "REG_DWORD", @"0");
            Add(list, "HideRecommendedSection", true, "zNTUSER", @"Software\Microsoft\Windows\CurrentVersion\Start", @"ShowFrequentList", "REG_DWORD", @"0");
            Add(list, "HideRecommendedSection", true, "zDEFAULT", @"Software\Microsoft\Windows\CurrentVersion\Start", @"ShowFrequentList", "REG_DWORD", @"0");
            Add(list, "HideRecommendedSection", true, "zNTUSER", @"Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced", @"Start_TrackDocs", "REG_DWORD", @"0");
            Add(list, "HideRecommendedSection", true, "zDEFAULT", @"Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced", @"Start_TrackDocs", "REG_DWORD", @"0");
            return list;
        }

        private static void Add(List<RegistryEntry> list, string tweak, bool defaultValue, string hive, string path, string name, string type, string data)
        {
            RegistryEntry entry = new RegistryEntry();
            entry.Tweak = tweak;
            entry.Default = defaultValue;
            entry.Hive = hive;
            entry.Path = path;
            entry.Name = name;
            entry.Type = type;
            entry.Data = data;
            list.Add(entry);
        }
    }
}
