using System;
using System.Collections.Generic;
using System.Linq;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;
using System.Threading.Tasks;
using Microsoft.UI;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.Windows.Storage.Pickers;
using Windows.Graphics;

namespace WinEaseGui;

// The WinEase settings window. Everything the user chooses lives in the fields below (not in the controls), so a
// page is simply built again from them: when it is opened, and when the display language changes.
public sealed partial class MainWindow : Window
{
    private static readonly string[] BuiltinTweakCategories = { "Security", "Privacy", "Performance", "UI" };
    // The built-in presets by key with the ui-strings key of their label; user presets (config\user\presets)
    // come after them in _init.Presets and show the ProfileName they were saved with.
    private static readonly (string Key, string LabelKey)[] BuiltinPresetLabels =
    {
        ("extreme", "Media.Preset.Extreme"), ("balanced", "Media.Preset.Balanced"), ("fat32", "Media.Preset.Fat32"),
        ("handheld", "Media.Preset.Handheld"), ("vm", "Media.Preset.VM"), ("audio", "Media.Preset.Audio"),
    };
    private static readonly string[] MigrationFolders = { "Documents", "Desktop", "Pictures", "Videos", "Music", "Downloads", "Saved Games" };
    private static readonly string[] ConflictPolicies = { "BackupExisting", "Skip", "OverwriteIfNewer", "Overwrite" };
    private const string CurrentSettingsId = "__current__";

    private readonly InitData _init;
    private readonly Bridge _bridge;
    private readonly UiStrings _s;

    // --- state -------------------------------------------------------------------------------------------
    private string _source = "", _workDir = "", _index = "", _drivers = "", _userName = "User", _computerName = "*";
    private int _presetIndex;
    private string? _basePresetKey;
    // Preset state. The rules (what counts as "modified") live in Get-WinEaseGuiPresetState (lib\WinEaseGuiCore.ps1);
    // the window only asks for them through the "presetState" request and shows the answer.
    private bool _presetModified;        // last answer; true when unknown (conservative: the result then reports Custom)
    private int _presetDiffCount;        // number of differing settings in the last answer, -1 unknown
    private bool _forcedCustom;          // the user picked the "Custom" entry
    private bool _applyingPreset;        // guard: programmatic changes while a preset is applied must not recompute / recurse
    private int _presetStateSeq;         // only the newest answer counts
    private ComboBox? _presetCombo;
    private TextBlock? _presetStatusText;
    private Button? _revertButton;
    private Button? _savePresetButton;
    private DispatcherTimer? _presetStateTimer;
    // Input check (PowerShell: Test-WinEaseBuildInputs): the issue of each media field is shown under its control
    private readonly Dictionary<string, TextBlock> _fieldMsgs = new();
    private List<InputIssue> _issues = new();
    private DispatcherTimer? _validateTimer;
    private bool _validating;
    private sealed record InputIssue(string Field, string Severity, string Text, bool Confirm);
    private string _payload = "WIM";
    private bool _useVhdx;
    private CheckBox? _vhdxCheck;
    private readonly Dictionary<string, bool> _tweaks = new(StringComparer.OrdinalIgnoreCase);
    private readonly Dictionary<string, bool> _components = new(StringComparer.OrdinalIgnoreCase);
    private readonly HashSet<string> _debloatStd = new();
    private readonly HashSet<string> _debloatExp = new();
    // The engine (PowerShell / Rust) the user picked for an Advanced Debloat target
    private readonly Dictionary<string, string> _debloatEngines = new(StringComparer.Ordinal);
    private List<string> _sources;
    private string _migRoot;
    private readonly HashSet<string> _migFolders = new() { "Documents", "Desktop", "Pictures" };
    private bool _migExcludeSecrets = true;
    private string _migConflict = ConflictPolicies[0];
    private string _migCustomPaths = "";
    private string? _migStatus;
    private List<(string Id, string Name)>? _migRules;
    private readonly HashSet<string> _migRuleIds = new();

    private string _page = "media";
    private bool _busy;
    private bool _resultSent;
    // True while the Start confirmations run. The dialogs do not set _busy, so a second click (or the
    // keyboard accelerator) could otherwise start a second confirmation flow and send two results.
    private bool _starting;
    // Build progress / cancel (D2): the builder advertises cancel support in its 'hello' event; nothing is assumed.
    private bool _progressActive, _buildFinished, _cancelSupported, _cancelRequested, _allowClose, _closeDialogOpen;
    private string _cancelRequestPath = "";
    private Func<string?>? _requestCancel;
    private bool _suppressLanguage;
    private readonly List<RadioButton> _payloadRadios = new();

    public MainWindow(InitData init, Bridge bridge)
    {
        InitializeComponent();
        _init = init;
        _bridge = bridge;
        _s = new UiStrings(init.StringsDir, init.Languages.Contains(init.Language) ? init.Language : "en");
        _sources = init.Sources;
        _migRoot = init.DefaultMigrationRoot;
        LoadInitialState();

        ExtendsContentIntoTitleBar = true;
        SetTitleBar(AppTitleBar);
        SizeAndCenter(1200, 880);
        InstallMinimumSize();
        UpdateThemeKey();
        RootGrid.ActualThemeChanged += RootGrid_ActualThemeChanged;
        AppWindow.Closing += AppWindow_Closing;
        // Enter = Start (only when the input is valid), Escape = Cancel; see RootGrid_KeyDown
        RootGrid.KeyDown += RootGrid_KeyDown;

        ApplyLanguage();
        _ = RefreshPresetStateAsync();
    }

    // =======================================================================================================
    // Start-up state (InitialSettings of Invoke-WinEaseGuiSession)
    // =======================================================================================================
    private void LoadInitialState()
    {
        JsonObject ini = _init.Initial;
        _source = InitData.Str(ini["SourceDrive"]);
        if (_source.Length == 0) _source = _sources.FirstOrDefault() ?? "E:\\";
        _workDir = InitData.Str(ini["WorkDir"]);
        if (_workDir.Length == 0) _workDir = _init.DefaultWorkDir;
        _index = InitData.Str(ini["Index"]);
        _drivers = InitData.Str(ini["InjectDrivers"]);
        string u = InitData.Str(ini["UserName"]);
        if (u.Length > 0) _userName = u;
        string c = InitData.Str(ini["ComputerName"]);
        if (c.Length > 0) _computerName = c;
        _useVhdx = InitData.Bool(ini["UseVHDX"]);
        _payload = InitData.Bool(ini["ExportESDMode"]) ? "ESD" : InitData.Bool(ini["SplitWIMMode"]) ? "SWM" : "WIM";

        var initTweaks = InitData.BoolMap(ini["TweakSettings"]);
        foreach (var t in _init.Tweaks) _tweaks[t.Key] = initTweaks.TryGetValue(t.Key, out bool v) ? v : t.Default;
        var initComponents = InitData.BoolMap(ini["Components"]);
        foreach (var cd in _init.Components) _components[cd.Key] = initComponents.TryGetValue(cd.Key, out bool v) ? v : cd.Default;
        foreach (var s in InitData.StrList(ini["AdvancedDebloatStandard"])) _debloatStd.Add(s);
        foreach (var s in InitData.StrList(ini["AdvancedDebloatExperimental"])) _debloatExp.Add(s);
        // The engine the user picked for a target (the rest runs on the registered default)
        foreach (var kv in (ini["DebloatEngineSelection"] as JsonObject) ?? new JsonObject())
        {
            if (kv.Value is JsonValue v && v.TryGetValue(out string? engine) && engine is not null) _debloatEngines[kv.Key] = engine;
        }

        // Preset: a built-in key selects that entry, any other name selects Custom, nothing selects the safe one
        string presetKey = InitData.Str(ini["PresetKey"]).Trim().ToLowerInvariant();
        int idx = _init.Presets.FindIndex(p => p.Key == presetKey);
        // No preset was chosen yet: start on the safe "balanced" preset (index 1); every debloat
        // target then runs on the safe PowerShell engine. An explicit preset is never overridden.
        if (idx < 0) idx = presetKey.Length > 0 ? _init.Presets.Count : 1;
        _presetIndex = idx;
        _basePresetKey = idx < _init.Presets.Count ? _init.Presets[idx].Key : null;
    }

    private void SizeAndCenter(int width, int height)
    {
        try
        {
            IntPtr hwnd = WinRT.Interop.WindowNative.GetWindowHandle(this);
            double scale = GetDpiForWindow(hwnd) / 96.0;
            var area = DisplayArea.GetFromWindowId(AppWindow.Id, DisplayAreaFallback.Primary).WorkArea;
            int w = Math.Min((int)(width * scale), area.Width);
            int h = Math.Min((int)(height * scale), area.Height);
            AppWindow.MoveAndResize(new RectInt32(area.X + (area.Width - w) / 2, area.Y + (area.Height - h) / 2, w, h));
        }
        catch
        {
            // Default size and position
        }
    }

    [System.Runtime.InteropServices.DllImport("user32.dll")]
    private static extern uint GetDpiForWindow(IntPtr hwnd);

    // --- Minimum window size ------------------------------------------------------------------------------
    // WinUI 3 has no MinWidth / MinHeight for a window and the presenter offers none, so the window procedure
    // answers WM_GETMINMAXINFO. The minimum is in device-independent pixels (scaled with the monitor DPI, so
    // 150-200% scaling keeps the same layout width) and is clamped to the work area of a small screen.
    private const int MinWindowWidthDip = 640;
    private const int MinWindowHeightDip = 560;
    private const int WM_GETMINMAXINFO = 0x0024;
    private const int GWLP_WNDPROC = -4;
    private delegate IntPtr WndProcDelegate(IntPtr hwnd, uint msg, IntPtr wParam, IntPtr lParam);
    private WndProcDelegate? _wndProc;      // kept in a field: the native side holds only the pointer
    private IntPtr _oldWndProc = IntPtr.Zero;

    [System.Runtime.InteropServices.StructLayout(System.Runtime.InteropServices.LayoutKind.Sequential)]
    private struct NativePoint { public int X, Y; }

    [System.Runtime.InteropServices.StructLayout(System.Runtime.InteropServices.LayoutKind.Sequential)]
    private struct MinMaxInfo
    {
        public NativePoint Reserved, MaxSize, MaxPosition, MinTrackSize, MaxTrackSize;
    }

    [System.Runtime.InteropServices.DllImport("user32.dll", EntryPoint = "SetWindowLongPtrW")]
    private static extern IntPtr SetWindowLongPtr(IntPtr hwnd, int index, WndProcDelegate newProc);

    [System.Runtime.InteropServices.DllImport("user32.dll")]
    private static extern IntPtr CallWindowProcW(IntPtr previous, IntPtr hwnd, uint msg, IntPtr wParam, IntPtr lParam);

    private void InstallMinimumSize()
    {
        try
        {
            IntPtr hwnd = WinRT.Interop.WindowNative.GetWindowHandle(this);
            _wndProc = MinimumSizeWndProc;
            _oldWndProc = SetWindowLongPtr(hwnd, GWLP_WNDPROC, _wndProc);
        }
        catch
        {
            // No minimum size: the window stays usable, only the lower bound is missing
            _wndProc = null;
        }
    }

    private IntPtr MinimumSizeWndProc(IntPtr hwnd, uint msg, IntPtr wParam, IntPtr lParam)
    {
        if (msg == WM_GETMINMAXINFO && lParam != IntPtr.Zero)
        {
            try
            {
                var info = System.Runtime.InteropServices.Marshal.PtrToStructure<MinMaxInfo>(lParam);
                double scale = GetDpiForWindow(hwnd) / 96.0;
                var area = DisplayArea.GetFromWindowId(AppWindow.Id, DisplayAreaFallback.Nearest).WorkArea;
                info.MinTrackSize.X = Math.Min((int)(MinWindowWidthDip * scale), area.Width);
                info.MinTrackSize.Y = Math.Min((int)(MinWindowHeightDip * scale), area.Height);
                System.Runtime.InteropServices.Marshal.StructureToPtr(info, lParam, false);
            }
            catch
            {
                // Fall through to the default handling
            }
        }
        return CallWindowProcW(_oldWndProc, hwnd, msg, wParam, lParam);
    }

    // --- Keyboard: Enter = Start (when valid), Escape = Cancel --------------------------------------------
    // Controls that use Enter / Escape themselves (buttons, combo boxes, lists, text boxes with several lines) and
    // any open popup or dialog get the key first; only a key nobody handled reaches this method.
    private void RootGrid_KeyDown(object sender, Microsoft.UI.Xaml.Input.KeyRoutedEventArgs e)
    {
        if (e.Handled || _busy || _resultSent) return;
        if (Content?.XamlRoot != null && Microsoft.UI.Xaml.Media.VisualTreeHelper.GetOpenPopupsForXamlRoot(Content.XamlRoot).Count > 0) return;
        var source = e.OriginalSource as DependencyObject;
        if (e.Key == Windows.System.VirtualKey.Enter)
        {
            if (source is Button || source is ComboBox || source is ComboBoxItem || source is NavigationViewItem || source is ToggleSwitch ||
                source is CheckBox || source is RadioButton || source is ListViewItem) return;
            if (source is TextBox tb && tb.AcceptsReturn) return;
            // Start only when the last input check found no error (Start itself checks again and asks to confirm)
            if (StartButton.IsEnabled && !_issues.Any(i => i.Severity == "Error"))
            {
                e.Handled = true;
                StartButton_Click(StartButton, new RoutedEventArgs());
            }
        }
        else if (e.Key == Windows.System.VirtualKey.Escape)
        {
            if (CancelButton.IsEnabled)
            {
                e.Handled = true;
                CancelButton_Click(CancelButton, new RoutedEventArgs());
            }
        }
    }

    // Wide: status and buttons share one row. Narrow (small window or a large display scale): the buttons move
    // below the status and wrap onto more rows, so no command ever leaves the window.
    private const double CommandBarWideWidth = 1100;
    private void CommandBar_SizeChanged(object sender, SizeChangedEventArgs e)
    {
        bool wide = e.NewSize.Width >= CommandBarWideWidth;
        Grid.SetColumnSpan(StatusArea, wide ? 1 : 2);
        Grid.SetRow(ButtonArea, wide ? 0 : 1);
        Grid.SetColumn(ButtonArea, wide ? 1 : 0);
        Grid.SetColumnSpan(ButtonArea, wide ? 1 : 2);
        ButtonArea.HorizontalAlignment = HorizontalAlignment.Right;
    }

    // =======================================================================================================
    // Language: every visible text comes from config\ui-strings; switching rebuilds the shell and the page
    // =======================================================================================================
    private void ApplyLanguage()
    {
        Title = _s.Get("Main.WindowTitle");
        TitleText.Text = _s.Get("Main.WindowTitle");
        LanguageLabel.Text = _s.Get("Main.Language").TrimEnd(':', '：', ' ');
        _suppressLanguage = true;
        LanguageCombo.Items.Clear();
        foreach (string lang in _init.Languages) LanguageCombo.Items.Add(_s.Get("Language.Name", lang, lang));
        LanguageCombo.SelectedIndex = Math.Max(0, _init.Languages.IndexOf(_s.Language));
        _suppressLanguage = false;

        DryRunCheck.Content = _s.Get("Main.DryRun");
        PresetDiffButton.Content = _s.Get("Button.PresetDiff");
        DependenciesButton.Content = _s.Get("Button.CheckDependencies");
        StartButton.Content = _s.Get("Button.StartBuild");
        CancelButton.Content = _s.Get("Button.Cancel");
        StatusText.Text = _bridge.IsConnected ? "" : _s.Get("Main.Status.Standalone");

        // Name = what it is, HelpText = what it does (also the tooltip). Keyboard shortcuts are shown in the help.
        void Describe(DependencyObject element, string name, string? help)
        {
            AutomationProperties.SetName(element, name);
            if (!string.IsNullOrEmpty(help))
            {
                AutomationProperties.SetHelpText(element, help);
                ToolTipService.SetToolTip(element, help);
            }
            else
            {
                ToolTipService.SetToolTip(element, name);
            }
        }
        Describe(DryRunCheck, _s.Get("Main.DryRun"), _s.Get("Main.DryRun.Help"));
        Describe(LanguageCombo, LanguageLabel.Text, _s.Get("Main.Language.Help"));
        Describe(PresetDiffButton, _s.Get("Button.PresetDiff"), _s.Get("Button.PresetDiff.Help"));
        Describe(DependenciesButton, _s.Get("Button.CheckDependencies"), _s.Get("Button.CheckDependencies.Help"));
        Describe(StartButton, _s.Get("Button.StartBuild"), _s.Get("Button.StartBuild.Help"));
        Describe(CancelButton, _s.Get("Button.Cancel"), _s.Get("Button.Cancel.Help"));
        Describe(BusyRing, _s.Get("Main.Busy"), null);
        Describe(Nav, _s.Get("Main.Nav.Name"), null);

        BuildNav();
        UpdateEstimate();
    }

    private async void LanguageCombo_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (_suppressLanguage || LanguageCombo.SelectedIndex < 0) return;
        string lang = _init.Languages[LanguageCombo.SelectedIndex];
        if (lang == _s.Language) return;
        _s.Language = lang;
        // The combo is rebuilt by ApplyLanguage, so do it after this event
        DispatcherQueue.TryEnqueue(ApplyLanguage);
        await _bridge.RequestAsync("saveLanguage", lang, new JsonObject { ["Language"] = lang });
    }

    private void BuildNav()
    {
        var items = new List<(string Tag, string Text, string Glyph)>
        {
            ("media", _s.Get("Tab.Media"), "\uE8B7"),
            ("security", _s.Get("Tab.Security"), "\uE72E"),
            ("privacy", _s.Get("Tab.Privacy"), "\uE890"),
            ("performance", _s.Get("Tab.Performance"), "\uEC4A"),
            ("ui", _s.Get("Tab.UI"), "\uE771"),
            ("services", _s.Get("Tab.Services"), "\uE713"),
            ("debloat", _s.Get("Tab.Debloat"), "\uE74D"),
            ("migration", _s.Get("Tab.Migration"), "\uE895"),
            ("customscripts", _s.Get("Tab.CustomScripts"), "\uE8C8"),
            ("user", _s.Get("Tab.UserTweaks"), "\uE77B"),
        };
        Nav.MenuItems.Clear();
        NavigationViewItem? selected = null;
        foreach (var (tag, text, glyph) in items)
        {
            string cleanText = CleanTabText(text);
            var icon = new FontIcon { Glyph = glyph };
            AutomationProperties.SetAccessibilityView(icon, Microsoft.UI.Xaml.Automation.Peers.AccessibilityView.Raw);
            var item = new NavigationViewItem { Content = cleanText, Tag = tag, Icon = icon };
            AutomationProperties.SetName(item, cleanText);
            ToolTipService.SetToolTip(item, cleanText);
            Nav.MenuItems.Add(item);
            if (tag == _page) selected = item;
        }
        Nav.SelectedItem = selected ?? Nav.MenuItems[0];
        ShowPage(_page);
    }

    // The WinForms tab texts start with "1. ", "2. " ...; the navigation pane does not need the numbers
    private static string CleanTabText(string text) => Regex.Replace(text.Trim(), @"^\d+\.\s*", "");

    private void Nav_SelectionChanged(NavigationView sender, NavigationViewSelectionChangedEventArgs args)
    {
        if (args.SelectedItem is NavigationViewItem item && item.Tag is string tag && tag != _page)
        {
            ShowPage(tag);
        }
    }

    private void ShowPage(string tag)
    {
        _page = tag;
        PageHost.Children.Clear();
        _payloadRadios.Clear();
        PageSubtitle.Text = "";
        PageSubtitle.Visibility = Visibility.Collapsed;
        switch (tag)
        {
            case "media": BuildMediaPage(); break;
            case "security": BuildTweakPage("Security", "Tab.Security"); break;
            case "privacy": BuildTweakPage("Privacy", "Tab.Privacy"); break;
            case "performance": BuildTweakPage("Performance", "Tab.Performance"); break;
            case "ui": BuildTweakPage("UI", "Tab.UI"); break;
            case "services": BuildServicesPage(); break;
            case "debloat": BuildDebloatPage(); break;
            case "migration": BuildMigrationPage(); break;
            case "customscripts": BuildCustomScriptsPage(); break;
            case "user": BuildUserTweaksPage(); break;
        }
        PageScroll.ChangeView(null, 0, null, true);
    }

    private void SetSubtitle(string text)
    {
        PageSubtitle.Text = text;
        PageSubtitle.Visibility = string.IsNullOrWhiteSpace(text) ? Visibility.Collapsed : Visibility.Visible;
    }

    // =======================================================================================================
    // Small control factories (Windows 11 settings-card look)
    // =======================================================================================================
    // Brushes created in code are looked up in the theme dictionary that matches the window's CURRENT theme
    // (Light / Dark / HighContrast), exactly what {ThemeResource} does in XAML. A plain Application.Resources[key]
    // lookup would keep the theme the application started with. The page is built again when the theme changes
    // (RootGrid_ActualThemeChanged), so these brushes follow light, dark and high contrast.
    private static string _themeKey = "Default";

    private static Brush Res(string key) => FindThemedBrush(Application.Current.Resources, key) ?? (Brush)Application.Current.Resources[key];

    private static Brush? FindThemedBrush(ResourceDictionary dictionary, string key)
    {
        try
        {
            if (dictionary.ThemeDictionaries.TryGetValue(_themeKey, out object? themed) &&
                themed is ResourceDictionary themeDictionary &&
                themeDictionary.TryGetValue(key, out object? value) && value is Brush brush)
            {
                return brush;
            }
            foreach (var merged in dictionary.MergedDictionaries)
            {
                var found = FindThemedBrush(merged, key);
                if (found != null) return found;
            }
        }
        catch
        {
            // Fall back to the application-level lookup
        }
        return null;
    }

    private void UpdateThemeKey()
    {
        bool highContrast = false;
        try
        {
            highContrast = new Windows.UI.ViewManagement.AccessibilitySettings().HighContrast;
        }
        catch (Exception ex)
        {
            // Accessibility settings retrieval may fail on unsupported environments or uninitialized WinRT contexts.
            // Fall back to standard theme selection (Dark/Light).
            System.Diagnostics.Debug.WriteLine($"Failed to retrieve accessibility settings for HighContrast theme: {ex.Message}");
        }
        _themeKey = highContrast ? "HighContrast" : RootGrid.ActualTheme == ElementTheme.Dark ? "Dark" : "Light";
    }

    private void RootGrid_ActualThemeChanged(FrameworkElement sender, object args)
    {
        UpdateThemeKey();
        if (!_resultSent) ShowPage(_page);
    }

    private static TextBlock Section(string text)
    {
        var t = new TextBlock
        {
            Text = text.Trim(),
            Style = (Style)Application.Current.Resources["BodyStrongTextBlockStyle"],
            Margin = new Thickness(1, 18, 0, 4),
            TextWrapping = TextWrapping.Wrap,
        };
        AutomationProperties.SetHeadingLevel(t, Microsoft.UI.Xaml.Automation.Peers.AutomationHeadingLevel.Level2);
        return t;
    }

    // A row of buttons / small controls that wraps onto more rows instead of leaving the window
    private static WrapPanel WrapRow(params UIElement[] items)
    {
        var w = new WrapPanel { HorizontalSpacing = 8, VerticalSpacing = 4, HorizontalAlignment = HorizontalAlignment.Left };
        foreach (var item in items) w.Children.Add(item);
        return w;
    }

    // A path / long value is shown wrapped and in full in a tooltip
    private static void PathTip(FrameworkElement element, Func<string> text)
    {
        ToolTipService.SetToolTip(element, null);
        element.PointerEntered += (_, _) =>
        {
            string t = text();
            ToolTipService.SetToolTip(element, string.IsNullOrWhiteSpace(t) ? null : new ToolTip { Content = new TextBlock { Text = t, TextWrapping = TextWrapping.Wrap, MaxWidth = 480 } });
        };
    }

    private static Border Card(UIElement content, Thickness? padding = null) => new()
    {
        Background = Res("CardBackgroundFillColorDefaultBrush"),
        BorderBrush = Res("CardStrokeColorDefaultBrush"),
        BorderThickness = new Thickness(1),
        CornerRadius = new CornerRadius(6),
        Padding = padding ?? new Thickness(16, 12, 16, 12),
        Child = content,
    };

    // Header / description on the left, the control on the right
    private static Border SettingCard(string header, string? description, UIElement? control, string? glyph = null)
    {
        var grid = new Grid { ColumnSpacing = 16 };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        if (glyph != null)
        {
            var icon = new FontIcon { Glyph = glyph, FontSize = 18, VerticalAlignment = VerticalAlignment.Center };
            AutomationProperties.SetAccessibilityView(icon, Microsoft.UI.Xaml.Automation.Peers.AccessibilityView.Raw);
            grid.Children.Add(icon);
        }
        var text = new StackPanel { VerticalAlignment = VerticalAlignment.Center };
        text.Children.Add(new TextBlock { Text = header, TextWrapping = TextWrapping.Wrap });
        if (!string.IsNullOrWhiteSpace(description))
        {
            text.Children.Add(new TextBlock
            {
                Text = description,
                TextWrapping = TextWrapping.Wrap,
                Style = (Style)Application.Current.Resources["CaptionTextBlockStyle"],
                Foreground = Res("TextFillColorSecondaryBrush"),
            });
        }
        Grid.SetColumn(text, 1);
        grid.Children.Add(text);
        if (control is FrameworkElement fe)
        {
            fe.VerticalAlignment = VerticalAlignment.Center;
            Grid.SetColumn(fe, 2);
            grid.Children.Add(fe);
            AutomationProperties.SetName(fe, header);
            if (!string.IsNullOrWhiteSpace(description))
            {
                AutomationProperties.SetHelpText(fe, description);
                ToolTipService.SetToolTip(fe, description);
            }
        }
        return Card(grid);
    }

    // A labelled row inside a card: label column, then the field, then optional buttons
    private static Grid FieldRow(string label, FrameworkElement field, params FrameworkElement[] buttons)
    {
        string cleanLabel = label.Trim().TrimEnd(':', '：', ' ');
        var g = new Grid { ColumnSpacing = 8, Margin = new Thickness(0, 4, 0, 4) };
        g.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(190) });
        g.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        g.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        for (int r = 0; r < 3; r++) g.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        var lbl = new TextBlock { Text = cleanLabel, VerticalAlignment = VerticalAlignment.Center, TextWrapping = TextWrapping.Wrap };
        g.Children.Add(lbl);
        Grid.SetColumn(field, 1);
        g.Children.Add(field);
        AutomationProperties.SetName(field, cleanLabel);
        WrapPanel? btnPanel = null;
        if (buttons.Length > 0)
        {
            var wrap = new WrapPanel { HorizontalSpacing = 8, VerticalSpacing = 4, VerticalAlignment = VerticalAlignment.Center };
            foreach (var b in buttons) wrap.Children.Add(b);
            Grid.SetColumn(wrap, 2);
            g.Children.Add(wrap);
            btnPanel = wrap;
        }
        // Narrow (small window, large scale): label above the field, the buttons below it, nothing is cut off.
        // The layout turns narrow when the field would get less than 160 px; it turns wide again once the row is
        // as wide as it was missing at that moment (the width of the buttons depends on the language and scale).
        bool narrow = false;
        double wideAgainAt = double.MaxValue;
        void Evaluate()
        {
            double width = g.ActualWidth;
            if (width <= 0) return;
            bool n = narrow;
            if (!narrow && field.ActualWidth < 160) { n = true; wideAgainAt = width + (160 - field.ActualWidth) + 4; }
            else if (narrow && width >= wideAgainAt) n = false;
            if (n == narrow) return;
            narrow = n;
            Grid.SetColumnSpan(lbl, n ? 3 : 1);
            Grid.SetRow(field, n ? 1 : 0);
            Grid.SetColumn(field, n ? 0 : 1);
            Grid.SetColumnSpan(field, n ? 3 : 1);
            field.Margin = new Thickness(0, n ? 4 : 0, 0, 0);
            if (btnPanel != null)
            {
                Grid.SetRow(btnPanel, n ? 2 : 0);
                Grid.SetColumn(btnPanel, n ? 0 : 2);
                Grid.SetColumnSpan(btnPanel, n ? 3 : 1);
                btnPanel.Margin = new Thickness(0, n ? 4 : 0, 0, 0);
                btnPanel.HorizontalAlignment = HorizontalAlignment.Left;
            }
        }
        g.SizeChanged += (_, _) => Evaluate();
        field.SizeChanged += (_, _) => Evaluate();
        return g;
    }

    private static Button Btn(string text, RoutedEventHandler click, bool accent = false)
    {
        var b = new Button { Content = text.Trim() };
        AutomationProperties.SetName(b, text.Trim());
        ToolTipService.SetToolTip(b, text.Trim());
        if (accent) b.Style = (Style)Application.Current.Resources["AccentButtonStyle"];
        b.Click += click;
        return b;
    }

    // Text field; the full value is available as a tooltip because a path can be longer than the box
    private static TextBox Box(string text, Action<string> changed, string? placeholder = null)
    {
        var t = new TextBox { Text = text, PlaceholderText = placeholder ?? "", TextWrapping = TextWrapping.NoWrap };
        t.TextChanged += (_, _) => changed(t.Text);
        PathTip(t, () => t.Text);
        return t;
    }

    // Switch without on/off text (the card shows the setting name); the accessible name is set here so a switch
    // that is not placed in a SettingCard is never nameless. SettingCard sets the same name and the help text.
    private static ToggleSwitch Toggle(bool on, Action<bool> changed, string? name = null)
    {
        var t = new ToggleSwitch { IsOn = on, MinWidth = 0, OnContent = "", OffContent = "" };
        if (!string.IsNullOrWhiteSpace(name)) AutomationProperties.SetName(t, name);
        t.Toggled += (_, _) => changed(t.IsOn);
        return t;
    }

    private UIElement SelectButtons(Action<bool> setAll)
    {
        var p = WrapRow(
            Btn(_s.Get("Button.SelectAll"), (_, _) => setAll(true)),
            Btn(_s.Get("Button.ClearAll"), (_, _) => setAll(false)));
        p.Margin = new Thickness(0, 0, 0, 4);
        return p;
    }

    // =======================================================================================================
    // Page 1: media, workspace, account, preset and payload format
    // =======================================================================================================
    private void BuildMediaPage()
    {
        PageTitle.Text = CleanTabText(_s.Get("Tab.Media"));
        SetSubtitle(_s.Get("Main.Subtitle"));
        _fieldMsgs.Clear();

        BuildSourceMediaSection();
        BuildPresetSection();
        BuildPayloadSection();
    }

    private void BuildSourceMediaSection()
    {
        PageHost.Children.Add(Section(_s.Get("Media.Group.Source")));
        var srcPanel = new StackPanel();
        var source = new AutoSuggestBox { Text = _source, HorizontalAlignment = HorizontalAlignment.Stretch, QueryIcon = new SymbolIcon(Symbol.Find) };
        source.ItemsSource = _sources;
        source.TextChanged += (s, a) =>
        {
            _source = s.Text;
            if (a.Reason == AutoSuggestionBoxTextChangeReason.UserInput)
            {
                s.ItemsSource = _sources.Where(x => x.Contains(s.Text, StringComparison.OrdinalIgnoreCase)).ToList();
            }
        };
        source.SuggestionChosen += (s, a) => { if (a.SelectedItem is string chosen) { s.Text = chosen; _source = chosen; } };
        source.GotFocus += (s, _) => { var box = (AutoSuggestBox)s; box.ItemsSource = _sources; box.IsSuggestionListOpen = _sources.Count > 0; };
        var browseDrive = Btn(_s.Get("Button.BrowseDrive"), async (_, _) =>
        {
            string? p = await PickFolderAsync();
            if (p == null) return;
            if (Regex.IsMatch(p, @"^[A-Za-z]:\\?$")) p = p.Substring(0, 2) + "\\";
            source.Text = p;
        });
        var browseIso = Btn(_s.Get("Button.BrowseISO"), async (_, _) =>
        {
            string? p = await PickFileAsync(".iso");
            if (p != null) source.Text = p;
        });
        var rescan = Btn(_s.Get("Button.Rescan"), async (_, _) =>
        {
            var r = await RunAsync("sources", null, quiet: true);
            if (r?["Data"] is JsonNode d) _sources = InitData.StrList(d);
            source.ItemsSource = _sources;
            source.IsSuggestionListOpen = _sources.Count > 0;
        });
        source.TextChanged += (_, _) => ScheduleValidation();
        PathTip(source, () => source.Text);
        srcPanel.Children.Add(WithMessage("SourceDrive", FieldRow(_s.Get("Media.Label.Source"), source, browseDrive, browseIso, rescan)));

        var work = Box(_workDir, v => _workDir = v, _init.DefaultWorkDir);
        work.TextChanged += (_, _) => ScheduleValidation();
        srcPanel.Children.Add(WithMessage("WorkDir", FieldRow(_s.Get("Media.Label.Workspace"), work, Btn(_s.Get("Button.BrowseFolder"), async (_, _) =>
        {
            string? p = await PickFolderAsync();
            if (p != null) work.Text = p;
        }))));

        var index = Box(_index, v => _index = v);
        index.HorizontalAlignment = HorizontalAlignment.Left;
        index.Width = 120;
        index.TextChanged += (_, _) => ScheduleValidation();
        srcPanel.Children.Add(WithMessage("Index", FieldRow(_s.Get("Media.Label.Index"), index)));

        var drivers = Box(_drivers, v => _drivers = v);
        drivers.TextChanged += (_, _) => ScheduleValidation();
        srcPanel.Children.Add(WithMessage("InjectDrivers", FieldRow(_s.Get("Media.Label.Drivers"), drivers, Btn(_s.Get("Button.Browse"), async (_, _) =>
        {
            string? p = await PickFolderAsync();
            if (p != null) drivers.Text = p;
        }))));

        var user = Box(_userName, v => _userName = v);
        user.MaxLength = 20;
        user.TextChanged += (_, _) => ScheduleValidation();
        srcPanel.Children.Add(WithMessage("UserName", FieldRow(_s.Get("Media.Label.UserName"), user)));
        var computer = Box(_computerName, v => _computerName = v);
        computer.MaxLength = 15;
        computer.TextChanged += (_, _) => ScheduleValidation();
        srcPanel.Children.Add(WithMessage("ComputerName", FieldRow(_s.Get("Media.Label.ComputerName"), computer)));
        PageHost.Children.Add(Card(srcPanel));
        ShowIssues();
    }

    private void BuildPresetSection()
    {
        PageHost.Children.Add(Section(_s.Get("Media.Group.Preset")));
        var preset = new ComboBox { HorizontalAlignment = HorizontalAlignment.Stretch };
        AutomationProperties.SetName(preset, _s.Get("Media.Group.Preset").Trim());
        foreach (var p in _init.Presets) preset.Items.Add(PresetDisplayLabel(p));
        preset.Items.Add(_s.Get("Media.Preset.Custom"));
        _applyingPreset = true;
        preset.SelectedIndex = _presetIndex;
        _applyingPreset = false;
        preset.SelectionChanged += (_, _) =>
        {
            if (_applyingPreset || preset.SelectedIndex < 0 || preset.SelectedIndex == _presetIndex) return;
            _presetIndex = preset.SelectedIndex;
            if (_presetIndex < _init.Presets.Count)
            {
                _forcedCustom = false;
                ApplyPreset(_init.Presets[_presetIndex]);
            }
            else
            {
                // "Custom": nothing is applied, the current values stay as they are
                _forcedCustom = true;
                UpdatePresetStatus();
            }
        };
        _presetCombo = preset;

        // State line ("<Base> + modified" / "Custom"), "Revert to preset" and "Save as preset"
        _presetStatusText = new TextBlock { TextWrapping = TextWrapping.Wrap, Foreground = Res("TextFillColorSecondaryBrush") };
        AutomationProperties.SetLiveSetting(_presetStatusText, Microsoft.UI.Xaml.Automation.Peers.AutomationLiveSetting.Polite);
        _revertButton = Btn(_s.Get("Button.RevertPreset"), (_, _) => RevertToPreset());
        ToolTipService.SetToolTip(_revertButton, _s.Get("Button.RevertPreset.Tooltip"));
        AutomationProperties.SetHelpText(_revertButton, _s.Get("Button.RevertPreset.Tooltip"));
        _savePresetButton = Btn(_s.Get("Button.SavePreset"), async (_, _) => await SaveAsPresetAsync());
        ToolTipService.SetToolTip(_savePresetButton, _s.Get("Button.SavePreset.Tooltip"));
        AutomationProperties.SetHelpText(_savePresetButton, _s.Get("Button.SavePreset.Tooltip"));
        var presetBox = new StackPanel { Spacing = 8 };
        presetBox.Children.Add(preset);
        presetBox.Children.Add(_revertButton);
        presetBox.Children.Add(_savePresetButton);
        presetBox.Children.Add(_presetStatusText);
        PageHost.Children.Add(Card(presetBox));
        UpdatePresetStatus();
    }

    private void BuildPayloadSection()
    {
        PageHost.Children.Add(Section(_s.Get("Media.Group.Payload")));
        var payload = new StackPanel { Spacing = 4 };
        var radios = new WrapPanel { HorizontalSpacing = 24, VerticalSpacing = 4, HorizontalAlignment = HorizontalAlignment.Left };
        foreach (var (fmt, key) in new[] { ("WIM", "Media.Radio.WIM"), ("ESD", "Media.Radio.ESD"), ("SWM", "Media.Radio.SWM") })
        {
            var rb = new RadioButton { Content = _s.Get(key), GroupName = "payload", Tag = fmt, IsChecked = _payload == fmt };
            AutomationProperties.SetName(rb, _s.Get(key));
            rb.Checked += (s, _) => { _payload = (string)((RadioButton)s).Tag; UpdateEstimate(); OnSettingChanged(); };
            radios.Children.Add(rb);
            _payloadRadios.Add(rb);
        }
        payload.Children.Add(radios);
        var vhdx = new CheckBox { Content = _s.Get("Media.Check.VHDX"), IsChecked = _useVhdx };
        AutomationProperties.SetName(vhdx, _s.Get("Media.Check.VHDX"));
        vhdx.Checked += (_, _) => { _useVhdx = true; OnSettingChanged(); };
        vhdx.Unchecked += (_, _) => { _useVhdx = false; OnSettingChanged(); };
        _vhdxCheck = vhdx;
        payload.Children.Add(vhdx);
        PageHost.Children.Add(Card(payload));
    }

    // Built-in preset -> every switch (Set-WinEaseGuiPreset)
    // Switching presets sets components, tweaks and the payload format. It does NOT touch the Advanced Debloat
    // selection or its engines: built-in presets define none, so those choices survive a switch exactly as they
    // were (docs\GUI_PRESET_STATE.md). Components a preset does not name keep their value. "Revert to preset"
    // is the action that also puts the Advanced Debloat selection back to what the preset defines.
    private void ApplyPreset(PresetDef p, bool includeDebloat = false)
    {
        _applyingPreset = true;
        try
        {
            foreach (var kv in p.Components) if (_components.ContainsKey(kv.Key)) _components[kv.Key] = kv.Value;
            foreach (var t in _init.Tweaks) _tweaks[t.Key] = p.Tweaks.TryGetValue(t.Key, out bool v) ? v : t.Default;
            _payload = p.PayloadFormat is "ESD" or "SWM" ? p.PayloadFormat : "WIM";
            foreach (var rb in _payloadRadios) rb.IsChecked = (string)rb.Tag == _payload;
            // The preset's VHDX switch is applied like the payload format (the state rules do not
            // compare it - docs\GUI_PRESET_STATE.md). Every built-in preset carries false.
            _useVhdx = p.UseVHDX;
            if (_vhdxCheck != null) _vhdxCheck.IsChecked = p.UseVHDX;
            if (includeDebloat)
            {
                _debloatStd.Clear();
                foreach (string s in p.DebloatStandard) _debloatStd.Add(s);
                _debloatExp.Clear();
                foreach (string s in p.DebloatExperimental) _debloatExp.Add(s);
                _debloatEngines.Clear();
                foreach (var kv in p.DebloatEngines) _debloatEngines[kv.Key] = kv.Value;
            }
            _basePresetKey = p.Key;
        }
        finally
        {
            _applyingPreset = false;
        }
        UpdateEstimate();
        _ = RefreshPresetStateAsync();
    }

    // "Revert to preset": every preset-controlled value, including the Advanced Debloat selection, back to the base preset
    private void RevertToPreset()
    {
        int idx = _basePresetKey == null ? -1 : _init.Presets.FindIndex(p => p.Key == _basePresetKey);
        if (idx < 0) return;
        _forcedCustom = false;
        _presetIndex = idx;
        if (_presetCombo != null)
        {
            _applyingPreset = true;
            _presetCombo.SelectedIndex = idx;
            _applyingPreset = false;
        }
        ApplyPreset(_init.Presets[idx], includeDebloat: true);
    }

    // =======================================================================================================
    // "Save as preset": the current settings become a user preset (config\user\presets\<key>.psd1).
    // The rules (name validation, built-in collision, atomic write, read-back) run in the host
    // through Save-WinEaseGuiUserPreset (lib\WinEaseGuiCore.ps1), shared with the WinForms window.
    // An existing preset is confirmed here (ReasonKey 'SavePreset.Reason.Exists'); a success
    // refreshes the combo and selects the new preset, whose state then reads "(unmodified)".
    // =======================================================================================================
    private async Task SaveAsPresetAsync()
    {
        if (_busy || _applyingPreset) return;
        var (name, description, ok) = await ShowSavePresetDialogAsync();
        if (!ok) return;
        await SendSavePresetAsync(name, description, overwrite: false, askWhenExists: true);
    }

    private async Task<(string Name, string Description, bool Ok)> ShowSavePresetDialogAsync()
    {
        string nameLabel = _s.Get("Dlg.SavePreset.Name").Trim();
        string descLabel = _s.Get("Dlg.SavePreset.Description").Trim();
        var name = new TextBox { MaxLength = 40, PlaceholderText = nameLabel };
        AutomationProperties.SetName(name, nameLabel);
        AutomationProperties.SetHelpText(name, nameLabel);
        var description = new TextBox { MaxLength = 200, PlaceholderText = descLabel };
        AutomationProperties.SetName(description, descLabel);
        AutomationProperties.SetHelpText(description, descLabel);
        var panel = new StackPanel { Spacing = 8 };
        panel.Children.Add(new TextBlock { Text = _s.Get("Dlg.SavePreset.Name") });
        panel.Children.Add(name);
        panel.Children.Add(new TextBlock { Text = _s.Get("Dlg.SavePreset.Description") });
        panel.Children.Add(description);
        var dlg = new ContentDialog
        {
            XamlRoot = Content.XamlRoot,
            Title = _s.Get("Dlg.SavePreset.Title"),
            Content = panel,
            PrimaryButtonText = _s.Get("Dlg.SavePreset.Save"),
            CloseButtonText = _s.Get("Button.Cancel"),
            DefaultButton = ContentDialogButton.Primary,
            IsPrimaryButtonEnabled = false,
        };
        name.TextChanged += (_, _) => dlg.IsPrimaryButtonEnabled = name.Text.Trim().Length > 0;
        if (await dlg.ShowAsync() != ContentDialogResult.Primary) return ("", "", false);
        return (name.Text.Trim(), description.Text.Trim(), name.Text.Trim().Length > 0);
    }

    private async Task SendSavePresetAsync(string name, string description, bool overwrite, bool askWhenExists)
    {
        var reply = await RunAsync("savePreset", new JsonObject
        {
            ["Name"] = name,
            ["Description"] = description,
            ["Overwrite"] = overwrite,
            ["Config"] = PresetStateConfig(),
        });
        if (reply == null) return;
        var data = reply["Data"] as JsonObject;
        if (InitData.Bool(reply["ok"]) && data != null && InitData.Bool(data["Success"]))
        {
            ReplacePresets(data["Presets"]);
            SelectPresetKey(InitData.Str(data["Key"]));
            await MessageAsync(_s.Get("Dlg.SavePreset.Title"), InitData.Str(data["Text"], _s.Format("Msg.SavePreset.Success", name)), "Info");
            return;
        }
        string reason = InitData.Str(data?["ReasonKey"]);
        if (reason == "SavePreset.Reason.Exists" && askWhenExists)
        {
            if (await ConfirmAsync(_s.Get("Dlg.SavePreset.Title"), _s.Format("Dlg.SavePreset.Overwrite", name)))
            {
                await SendSavePresetAsync(name, description, overwrite: true, askWhenExists: false);
            }
            return;
        }
        string text = InitData.Str(data?["Text"]);
        if (text.Length == 0) text = _s.Get("SavePreset.Reason.Write");
        await MessageAsync(_s.Get("Dlg.SavePreset.Title"), _s.Format("Msg.SavePreset.Error", text), "Error");
    }

    // The refreshed preset list (init layout: built-ins first, then the user presets) replaces
    // _init.Presets; the combo is rebuilt with the Custom entry still last.
    private void ReplacePresets(JsonNode? presets)
    {
        var parsed = new List<PresetDef>();
        foreach (var p in InitData.Arr(presets))
        {
            if (p == null) continue;
            var engines = new Dictionary<string, string>(StringComparer.Ordinal);
            if (p["DebloatEngineSelection"] is JsonObject pe) foreach (var kv in pe) engines[kv.Key] = InitData.Str(kv.Value);
            parsed.Add(new PresetDef(InitData.Str(p["Key"]), InitData.BoolMap(p["Components"]), InitData.BoolMap(p["Tweaks"]),
                InitData.Str(p["PayloadFormat"], "WIM"), InitData.Bool(p["UseVHDX"]), InitData.StrList(p["AdvancedDebloatStandard"]),
                InitData.StrList(p["AdvancedDebloatExperimental"]), engines, InitData.Str(p["Label"])));
        }
        if (parsed.Count == 0) return;
        _init.Presets.Clear();
        _init.Presets.AddRange(parsed);
        // the Preset Diff picker works from PresetNames: a just-saved preset joins without a restart
        foreach (var p in parsed)
        {
            if (!_init.PresetNames.Contains(p.Key)) _init.PresetNames.Add(p.Key);
        }
        if (_presetCombo != null)
        {
            _applyingPreset = true;
            try
            {
                _presetCombo.Items.Clear();
                foreach (var p in _init.Presets) _presetCombo.Items.Add(PresetDisplayLabel(p));
                _presetCombo.Items.Add(_s.Get("Media.Preset.Custom"));
                _presetCombo.SelectedIndex = _presetIndex <= _init.Presets.Count && _presetIndex >= 0 ? _presetIndex : _init.Presets.Count;
            }
            finally { _applyingPreset = false; }
        }
        UpdatePresetStatus();
    }

    // Select a (usually just saved) preset in the combo and make it the base preset: its values
    // equal what the window shows, so the state line reads "<new preset> (unmodified)".
    private void SelectPresetKey(string key)
    {
        int idx = _init.Presets.FindIndex(p => p.Key == key);
        if (idx < 0) return;
        _forcedCustom = false;
        _presetIndex = idx;
        if (_presetCombo != null)
        {
            _applyingPreset = true;
            try { _presetCombo.SelectedIndex = idx; } finally { _applyingPreset = false; }
        }
        _basePresetKey = key;
        UpdatePresetStatus();
        _ = RefreshPresetStateAsync();
    }

    // Any control change: ask the shared rules again (debounced, so "Select all" is one request)
    private void OnSettingChanged()
    {
        if (_applyingPreset) return;
        _presetStateTimer ??= new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(150) };
        _presetStateTimer.Tick -= PresetStateTimer_Tick;
        _presetStateTimer.Tick += PresetStateTimer_Tick;
        _presetStateTimer.Stop();
        _presetStateTimer.Start();
    }

    private void PresetStateTimer_Tick(object? sender, object e)
    {
        _presetStateTimer?.Stop();
        _ = RefreshPresetStateAsync();
    }

    // What Get-WinEaseGuiPresetState compares: the preset-controlled parts of the window
    private JsonObject PresetStateConfig()
    {
        var components = new JsonObject();
        foreach (var kv in _components) components[kv.Key] = kv.Value;
        var tweaks = new JsonObject();
        foreach (var t in _init.Tweaks) tweaks[t.Key] = _tweaks.GetValueOrDefault(t.Key, t.Default);
        return new JsonObject
        {
            ["Components"] = components,
            ["TweakSettings"] = tweaks,
            ["PayloadFormat"] = _payload,
            ["UseVHDX"] = _useVhdx,
            ["AdvancedDebloatStandard"] = ToArray(_init.DebloatStandard.Where(_debloatStd.Contains)),
            ["AdvancedDebloatExperimental"] = ToArray(_init.DebloatExperimental.Where(_debloatExp.Contains).Distinct()),
            ["DebloatEngineSelection"] = DebloatEngineSelectionObject(),
        };
    }

    private async Task RefreshPresetStateAsync()
    {
        int seq = ++_presetStateSeq;
        if (_basePresetKey == null)
        {
            _presetModified = true;
            _presetDiffCount = 0;
            UpdatePresetStatus();
            return;
        }
        bool modified = true;
        int count = -1;
        try
        {
            var reply = await _bridge.RequestAsync("presetState", _s.Language, new JsonObject
            {
                ["BasePresetKey"] = _basePresetKey,
                ["Config"] = PresetStateConfig(),
            });
            if (InitData.Bool(reply["ok"]) && reply["Data"] is JsonObject data)
            {
                modified = InitData.Bool(data["IsModified"]);
                count = InitData.Arr(data["DifferingKeys"]).Count();
            }
        }
        catch (Exception)
        {
            // Unknown state: report Custom rather than a preset the values may no longer match
        }
        if (seq != _presetStateSeq) return;
        _presetModified = modified;
        _presetDiffCount = count;
        UpdatePresetStatus();
    }

    // The label of a preset without its parenthesised description
    private string PresetShortLabel(int index)
    {
        if (index < 0 || index >= _init.Presets.Count) return "";
        string label = PresetDisplayLabel(_init.Presets[index]);
        int p = label.IndexOf(" (", StringComparison.Ordinal);
        return p > 0 ? label.Substring(0, p) : label;
    }

    // Built-in presets show their localized label; a user preset shows the ProfileName it was
    // saved with (the host sends it as Label, the key as the fallback)
    private string PresetDisplayLabel(PresetDef p)
    {
        foreach (var b in BuiltinPresetLabels)
        {
            if (b.Key == p.Key) return _s.Get(b.LabelKey);
        }
        return string.IsNullOrEmpty(p.Label) ? p.Key : p.Label;
    }

    private bool IsCustomResult => _basePresetKey == null || _forcedCustom || _presetModified;

    private void UpdatePresetStatus()
    {
        if (_presetStatusText == null) return;
        int baseIdx = _basePresetKey == null ? -1 : _init.Presets.FindIndex(p => p.Key == _basePresetKey);
        if (baseIdx < 0 || _forcedCustom)
        {
            _presetStatusText.Text = _s.Get("Media.Preset.State.Custom");
        }
        else if (_presetModified)
        {
            _presetStatusText.Text = _s.Format("Media.Preset.State.Modified", PresetShortLabel(baseIdx), _presetDiffCount >= 0 ? _presetDiffCount.ToString() : "?");
        }
        else
        {
            _presetStatusText.Text = _s.Format("Media.Preset.State.Preset", PresetShortLabel(baseIdx));
        }
        if (_revertButton != null) _revertButton.IsEnabled = baseIdx >= 0;
    }

    // =======================================================================================================
    // Pages 2-5 and 9: tweak switches from config\schema.psd1 (and config\user\user-tweaks.psd1)
    // =======================================================================================================
    private string TweakDescription(TweakDef t)
    {
        string fallback = _s.Language == "ja" && t.DescriptionJa.Length > 0 ? t.DescriptionJa : t.Description;
        return _s.Get($"Tweak.{t.Key}.Description", fallback);
    }

    private void BuildTweakPage(string category, string tabKey)
    {
        PageTitle.Text = CleanTabText(_s.Get(tabKey));
        SetSubtitle(_s.Format("Tab.TweakCaption", _s.Get($"Category.{category}", category)));
        AddTweakCards(_init.Tweaks.Where(t => t.Category == category).ToList(), showCategory: false);
    }

    private void BuildUserTweaksPage()
    {
        PageTitle.Text = CleanTabText(_s.Get("Tab.UserTweaks"));
        SetSubtitle(_s.Get("UserTweaks.Caption"));
        var list = _init.Tweaks.Where(t => !BuiltinTweakCategories.Contains(t.Category)).ToList();
        if (list.Count == 0)
        {
            PageHost.Children.Add(Card(new TextBlock { Text = _s.Get("UserTweaks.None"), TextWrapping = TextWrapping.Wrap }));
            return;
        }
        AddTweakCards(list, showCategory: true);
    }

    private void AddTweakCards(List<TweakDef> list, bool showCategory)
    {
        var toggles = new List<(string Key, ToggleSwitch Toggle)>();
        PageHost.Children.Add(SelectButtons(on =>
        {
            foreach (var (_, t) in toggles) t.IsOn = on;
        }));
        foreach (var t in list)
        {
            string key = t.Key;
            string header = showCategory ? $"{key}  [{t.Category}]" : key;
            var toggle = Toggle(_tweaks.GetValueOrDefault(key, t.Default), v => { _tweaks[key] = v; OnSettingChanged(); }, header);
            toggles.Add((key, toggle));
            var card = SettingCard(header, TweakDescription(t), toggle);
            ToolTipService.SetToolTip(card, TweakDescription(t));
            PageHost.Children.Add(card);
        }
    }

    // =======================================================================================================
    // Page 6: component switches (config\schema.psd1 Components with a Gui entry)
    // =======================================================================================================
    private string ComponentText(ComponentDef c) => _s.Get($"Component.{c.Key}.Text", c.Text);
    private string ComponentDescription(ComponentDef c) => _s.Get($"Component.{c.Key}.Description", c.Description);

    private void BuildServicesPage()
    {
        PageTitle.Text = CleanTabText(_s.Get("Tab.Services"));
        var defs = _init.Components.Where(c => c.Tab != "Migration").OrderBy(c => c.Order).ToList();
        var toggles = new List<ToggleSwitch>();
        PageHost.Children.Add(SelectButtons(on => { foreach (var t in toggles) t.IsOn = on; }));
        foreach (var c in defs)
        {
            string key = c.Key;
            var toggle = Toggle(_components.GetValueOrDefault(key, c.Default), v => { _components[key] = v; UpdateEstimate(); OnSettingChanged(); }, ComponentText(c));
            toggles.Add(toggle);
            var card = SettingCard(ComponentText(c), $"{key} - {ComponentDescription(c)}", toggle);
            ToolTipService.SetToolTip(card, ComponentDescription(c));
            PageHost.Children.Add(card);
        }
    }

    // =======================================================================================================
    // Page 7: Advanced Debloat (physical deletion). The English item text is the value; only the label is translated.
    // =======================================================================================================
    private void BuildDebloatPage()
    {
        PageTitle.Text = CleanTabText(_s.Get("Tab.Debloat"));
        PageHost.Children.Add(new InfoBar
        {
            IsOpen = true,
            IsClosable = false,
            Severity = InfoBarSeverity.Warning,
            Message = _s.Get("Debloat.Notice"),
        });
        // Global engine switch: applies one engine to every target that supports it
        var allRow = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8, Margin = new Thickness(0, 0, 0, 6) };
        // The help mark next to the label: what the engine choice does is not obvious,
        // so the mark explains it in a tooltip and accessibility properties.
        var engineHelp = new Button
        {
            Content = "?",
            VerticalAlignment = VerticalAlignment.Center,
            Padding = new Thickness(6, 2, 6, 2),
            MinHeight = 0,
            MinWidth = 0,
        };
        AutomationProperties.SetName(engineHelp, _s.Get("Debloat.Engine.Help"));
        ToolTipService.SetToolTip(engineHelp, _s.Get("Debloat.Engine.Help"));
        engineHelp.Click += async (_, _) => await MessageAsync(_s.Get("Debloat.Engine.All").TrimEnd(':', '：', ' '), _s.Get("Debloat.Engine.Help"));
        allRow.Children.Add(engineHelp);
        allRow.Children.Add(new TextBlock { Text = _s.Get("Debloat.Engine.All"), VerticalAlignment = VerticalAlignment.Center });
        var allCombo = new ComboBox { MinWidth = 140, SelectedIndex = 0 };
        ToolTipService.SetToolTip(allCombo, _s.Get("Debloat.Engine.Help"));
        AutomationProperties.SetName(allCombo, _s.Get("Debloat.Engine.All").TrimEnd(':', '：', ' '));
        allCombo.Items.Add("PowerShell");
        allCombo.Items.Add("Rust");
        allCombo.SelectionChanged += (_, _) =>
        {
            if (allCombo.SelectedIndex < 0) return;
            string engine = allCombo.SelectedIndex == 0 ? "PowerShell" : "Rust";
            foreach (var kv in _debloatEngineRows) SetDebloatEngine(kv.Key, engine, kv.Value.Combo);
        };
        allRow.Children.Add(allCombo);
        PageHost.Children.Add(allRow);

        AddDebloatList(_s.Get("Debloat.Group.Standard"), _init.DebloatStandard, _debloatStd, null, danger: false);
        AddDebloatList(_s.Get("Debloat.Group.Experimental"), _init.DebloatExperimental, _debloatExp, _s.Get("Debloat.ConfirmSelectExperimental"), danger: true);
    }

    // One row of the Advanced Debloat list: the checkbox selects the target, the combo picks the
    // engine that removes it. The combo is locked while the target is not selected, because an
    // unselected target never runs (invariant: OFF protects the target from both engines).
    private readonly Dictionary<string, (ComboBox Combo, CheckBox Box)> _debloatEngineRows = new(StringComparer.Ordinal);

    private void AddDebloatList(string title, List<string> items, HashSet<string> selected, string? confirmSelectAll, bool danger)
    {
        var header = Section(title);
        // Danger is never shown by colour alone: a warning sign and the word before the heading
        if (danger)
        {
            header.Foreground = Res("SystemFillColorCriticalBrush");
            header.Text = "\u26A0 " + _s.Get("Severity.Warning") + ": " + header.Text;
        }
        PageHost.Children.Add(header);
        var boxes = new List<CheckBox>();
        var bar = WrapRow(
            Btn(_s.Get("Button.SelectAll"), async (_, _) =>
            {
                if (confirmSelectAll != null && !await ConfirmAsync(_s.Get("Msg.Title.Confirm"), confirmSelectAll)) return;
                foreach (var b in boxes) b.IsChecked = true;
            }),
            Btn(_s.Get("Button.ClearAll"), (_, _) => { foreach (var b in boxes) b.IsChecked = false; }));
        bar.Margin = new Thickness(0, 0, 0, 4);
        PageHost.Children.Add(bar);

        var panel = new StackPanel { Spacing = 0 };
        foreach (string item in items.Distinct())
        {
            string value = item;
            // Check box (takes the free width and wraps its text) | engine combo
            var row = new Grid { ColumnSpacing = 8, Margin = new Thickness(0, 0, 0, 2) };
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            string translatedItem = _s.Get("Debloat:" + item, item);
            var cbText = new TextBlock { Text = translatedItem, TextWrapping = TextWrapping.Wrap };
            var cb = new CheckBox { Content = cbText, IsChecked = selected.Contains(item), MinWidth = 0, HorizontalAlignment = HorizontalAlignment.Stretch };
            AutomationProperties.SetName(cb, translatedItem);
            AutomationProperties.SetHelpText(cb, item);
            cb.Checked += (_, _) => { selected.Add(value); UpdateDebloatEngineState(value); OnSettingChanged(); };
            cb.Unchecked += (_, _) => { selected.Remove(value); UpdateDebloatEngineState(value); OnSettingChanged(); };
            boxes.Add(cb);
            row.Children.Add(cb);

            var combo = new ComboBox { MinWidth = 120, HorizontalAlignment = HorizontalAlignment.Right, VerticalAlignment = VerticalAlignment.Top };
            Grid.SetColumn(combo, 1);
            foreach (string eng in DebloatEnginesFor(value)) combo.Items.Add(eng);
            combo.SelectedIndex = 0;
            combo.SelectionChanged += (_, _) => { if (combo.SelectedIndex >= 0) SetDebloatEngine(value, (string)combo.SelectedItem, combo); };
            AutomationProperties.SetName(combo, $"{translatedItem} - {_s.Get("Debloat.Column.Engine", "Engine")}");
            row.Children.Add(combo);
            _debloatEngineRows[value] = (combo, cb);
            panel.Children.Add(row);
        }
        PageHost.Children.Add(Card(panel));
        foreach (var kv in _debloatEngineRows) UpdateDebloatEngineState(kv.Key);
    }

    // The engines a target supports (PowerShell and/or Rust)
    private List<string> DebloatEnginesFor(string item)
    {
        if (_init.DebloatEngines.TryGetValue(item, out var def) && def.Engines.Count > 0) return def.Engines;
        return new List<string> { "PowerShell", "Rust" };
    }

    // The engine of a target: the user's choice wins, otherwise the registered default
    private string DebloatEngineOf(string item)
    {
        List<string> allowed = DebloatEnginesFor(item);
        if (_debloatEngines.TryGetValue(item, out string? chosen) && allowed.Contains(chosen)) return chosen;
        if (_init.DebloatEngines.TryGetValue(item, out var def) && def.Default.Length > 0 && allowed.Contains(def.Default)) return def.Default;
        return allowed.Count > 0 ? allowed[0] : "PowerShell";
    }

    private void SetDebloatEngine(string item, string engine, ComboBox combo)
    {
        if (!DebloatEnginesFor(item).Contains(engine)) return;
        bool changed = !_debloatEngines.TryGetValue(item, out string? before) || before != engine;
        _debloatEngines[item] = engine;
        if (changed) OnSettingChanged();
        if (combo.SelectedItem is string current && current != engine) combo.SelectedItem = engine;
    }

    // The engine combo is only editable while the target is selected
    private void UpdateDebloatEngineState(string item)
    {
        if (!_debloatEngineRows.TryGetValue(item, out var row)) return;
        bool selected = row.Box.IsChecked == true;
        bool single = DebloatEnginesFor(item).Count <= 1;
        row.Combo.IsEnabled = selected && !single;
        string engine = DebloatEngineOf(item);
        if (row.Combo.SelectedItem is string current && current != engine) row.Combo.SelectedItem = engine;
    }

    // =======================================================================================================
    // Page 8: migration & backup (the migration engine runs in the builder process)
    // =======================================================================================================
    private TextBlock? _migStatusText;

    private void BuildMigrationPage()
    {
        PageTitle.Text = CleanTabText(_s.Get("Tab.Migration"));

        BuildMigrationAssistantSection();
        BuildMigrationBackupSection();
        BuildMigrationColumnsSection();
        BuildMigrationCustomPathsSection();
        BuildMigrationExtensionsSection();
    }

    private void BuildMigrationAssistantSection()
    {
        // Post-install migration assistant switch and the backup bundle opt-out
        var assist = _init.Components.FirstOrDefault(c => c.Key == "IncludeMigrationAssistant");
        ToggleSwitch? backupToggle = null;
        if (assist != null)
        {
            PageHost.Children.Add(Section(_s.Get("Mig.Group.Assistant")));
            var toggle = Toggle(_components.GetValueOrDefault(assist.Key, assist.Default), v => { _components[assist.Key] = v; OnSettingChanged(); }, ComponentText(assist));
            PageHost.Children.Add(SettingCard(ComponentText(assist), ComponentDescription(assist), toggle, "\uE8F1"));

            var backupDef = _init.Components.FirstOrDefault(c => c.Key == "IncludeMigrationBackup");
            if (backupDef != null)
            {
                backupToggle = Toggle(_components.GetValueOrDefault(backupDef.Key, backupDef.Default), v => { _components[backupDef.Key] = v; OnSettingChanged(); }, ComponentText(backupDef));
                backupToggle.IsEnabled = toggle.IsOn;
                PageHost.Children.Add(SettingCard(ComponentText(backupDef), ComponentDescription(backupDef), backupToggle, "\uE8F1"));
                toggle.Toggled += (_, _) => { if (backupToggle != null) backupToggle.IsEnabled = toggle.IsOn; };
            }
        }
    }

    private void BuildMigrationBackupSection()
    {
        // Backup destination, secrets, conflict policy
        PageHost.Children.Add(Section(_s.Get("Mig.Group.Backup")));
        var backup = new StackPanel();
        var root = Box(_migRoot, v => _migRoot = v, _init.DefaultMigrationRoot);
        backup.Children.Add(FieldRow(_s.Get("Mig.Label.BackupRoot"), root, Btn(_s.Get("Button.Browse"), async (_, _) =>
        {
            string? p = await PickFolderAsync();
            if (p != null) root.Text = p;
        })));
        var secrets = new CheckBox { Content = _s.Get("Mig.Check.ExcludeSecrets"), IsChecked = _migExcludeSecrets };
        AutomationProperties.SetName(secrets, _s.Get("Mig.Check.ExcludeSecrets"));
        secrets.Checked += (_, _) => _migExcludeSecrets = true;
        secrets.Unchecked += (_, _) => _migExcludeSecrets = false;
        backup.Children.Add(secrets);
        var conflict = new ComboBox { MinWidth = 220, HorizontalAlignment = HorizontalAlignment.Stretch };
        AutomationProperties.SetName(conflict, _s.Get("Mig.Label.ConflictPolicy").TrimEnd(':', '：', ' '));
        foreach (string p in ConflictPolicies) conflict.Items.Add(_s.Get("Mig.Policy." + p, p));
        conflict.SelectedIndex = Math.Max(0, Array.IndexOf(ConflictPolicies, _migConflict));
        conflict.SelectionChanged += (_, _) => { if (conflict.SelectedIndex >= 0) _migConflict = ConflictPolicies[conflict.SelectedIndex]; };
        backup.Children.Add(FieldRow(_s.Get("Mig.Label.ConflictPolicy"), conflict));
        _migStatusText = new TextBlock
        {
            Text = _migStatus ?? _s.Get("Mig.Status.Initial"),
            TextWrapping = TextWrapping.Wrap,
            Foreground = Res("TextFillColorSecondaryBrush"),
            Margin = new Thickness(0, 6, 0, 0),
        };
        AutomationProperties.SetLiveSetting(_migStatusText, Microsoft.UI.Xaml.Automation.Peers.AutomationLiveSetting.Polite);
        backup.Children.Add(_migStatusText);
        PageHost.Children.Add(Card(backup));
    }

    private void BuildMigrationColumnsSection()
    {
        // Folders and rules | actions
        var columns = new Grid { ColumnSpacing = 12 };
        columns.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        columns.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });

        var left = new StackPanel { Spacing = 2 };
        left.Children.Add(Section(_s.Get("Mig.Group.Rules")));
        var folders = new StackPanel();
        foreach (string f in MigrationFolders)
        {
            string name = f;
            var cb = new CheckBox { Content = f, IsChecked = _migFolders.Contains(f) };
            AutomationProperties.SetName(cb, f);
            ToolTipService.SetToolTip(cb, f);
            cb.Checked += (_, _) => _migFolders.Add(name);
            cb.Unchecked += (_, _) => _migFolders.Remove(name);
            folders.Children.Add(cb);
        }
        folders.Children.Add(new TextBlock { Text = _s.Get("Mig.Label.Rules"), Margin = new Thickness(0, 10, 0, 4), TextWrapping = TextWrapping.Wrap });
        var rules = new StackPanel();
        folders.Children.Add(new ScrollViewer { Content = rules, MaxHeight = 280 });
        left.Children.Add(Card(folders));
        FillMigrationRules(rules);

        var right = new StackPanel { Spacing = 2 };
        right.Children.Add(Section(_s.Get("Mig.Group.Actions")));
        var actions = new StackPanel { Spacing = 6 };
        void Action(string key, Func<Task> run)
        {
            var b = new Button { Content = _s.Get(key).Trim(), HorizontalAlignment = HorizontalAlignment.Stretch, HorizontalContentAlignment = HorizontalAlignment.Left };
            b.Click += async (_, _) => await run();
            actions.Children.Add(b);
        }
        Action("Mig.Button.Readiness", () => RunAndShowAsync("readiness", new JsonObject { ["Config"] = DraftConfig() }));
        Action("Mig.Button.ExportApps", async () =>
        {
            string? path = await PickSaveFileAsync("apps-inventory", "JSON", ".json");
            if (path != null) await RunAndShowAsync("exportApps", new JsonObject { ["OutputPath"] = path });
        });
        Action("Mig.Button.Wizard", () => RunAndShowAsync("wizard", MigrationArgs()));
        Action("Mig.Button.Estimate", () => RunAndShowAsync("estimate", MigrationArgs()));
        Action("Mig.Button.Backup", () => RunAndShowAsync("backup", MigrationArgs()));
        Action("Mig.Button.Verify", () => RunAndShowAsync("verify", MigrationArgs()));
        Action("Mig.Button.Restore", async () =>
        {
            if (!await ConfirmOverwriteAsync()) return;
            await RunAndShowAsync("restore", MigrationArgs());
        });
        Action("Mig.Button.Retry", async () =>
        {
            if (!await ConfirmOverwriteAsync()) return;
            var a = MigrationArgs();
            a["RetryFailedOnly"] = true;
            await RunAndShowAsync("restore", a);
        });
        right.Children.Add(Card(actions));

        columns.Children.Add(left);
        Grid.SetColumn(right, 1);
        columns.Children.Add(right);
        // Narrow: the two columns stack
        columns.SizeChanged += (_, e) =>
        {
            bool stack = e.NewSize.Width < 620;
            columns.ColumnDefinitions[1].Width = stack ? new GridLength(0) : new GridLength(1, GridUnitType.Star);
            Grid.SetColumn(right, stack ? 0 : 1);
            Grid.SetRow(right, stack ? 1 : 0);
            columns.RowDefinitions.Clear();
            if (stack)
            {
                columns.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
                columns.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
            }
        };
        PageHost.Children.Add(columns);
    }

    private void BuildMigrationCustomPathsSection()
    {
        // Custom files and folders
        PageHost.Children.Add(Section(_s.Get("Mig.Group.Custom")));
        var custom = new StackPanel { Spacing = 6 };
        custom.Children.Add(new TextBlock { Text = _s.Get("Mig.Label.CustomPaths").Trim() });
        var paths = new TextBox { Text = _migCustomPaths, AcceptsReturn = true, TextWrapping = TextWrapping.Wrap, MinHeight = 90, FontFamily = new FontFamily("Cascadia Mono, Consolas") };
        AutomationProperties.SetName(paths, _s.Get("Mig.Label.CustomPaths").TrimEnd(':', '：', ' '));
        paths.TextChanged += (_, _) => _migCustomPaths = paths.Text;
        custom.Children.Add(paths);
        var customButtons = WrapRow(
            Btn(_s.Get("Mig.Button.BackupCustom"), async (_, _) =>
            {
                var a = MigrationArgs();
                var arr = new JsonArray();
                foreach (string line in _migCustomPaths.Split('\n').Select(l => l.Trim()).Where(l => l.Length > 0)) arr.Add(line);
                a["Paths"] = arr;
                await RunAndShowAsync("backupCustom", a);
            }),
            Btn(_s.Get("Mig.Button.RestoreCustom"), async (_, _) =>
            {
                if (!await ConfirmOverwriteAsync()) return;
                await RunAndShowAsync("restoreCustom", MigrationArgs());
            }));
        custom.Children.Add(customButtons);
        PageHost.Children.Add(Card(custom));
    }

    private void BuildMigrationExtensionsSection()
    {
        // User extensions (config\user\user-tweaks.psd1)
        PageHost.Children.Add(Section(_s.Get("Mig.Group.Extensions")));
        var ext = _init.Extensions;
        var extPanel = new StackPanel { Spacing = 4 };
        bool loaded = InitData.Bool(ext["Loaded"]);
        extPanel.Children.Add(new TextBlock
        {
            Text = loaded
                ? _s.Format("Mig.Ext.Counts", (int?)ext["UserTweakCount"] ?? 0, (int?)ext["UserPresetCount"] ?? 0, (int?)ext["CustomScriptCount"] ?? 0)
                : _s.Get("Mig.Ext.NotLoaded"),
            TextWrapping = TextWrapping.Wrap,
        });
        var errors = InitData.StrList(ext["Errors"]);
        extPanel.Children.Add(new TextBlock
        {
            // Load errors carry a warning sign and the word, not only the caution colour
            Text = errors.Count > 0 ? "\u26A0 " + _s.Get("Severity.Warning") + ": " + _s.Format("Mig.Ext.LoadErrors", string.Join("; ", errors)) : _s.Get("Mig.Ext.NoErrors"),
            TextWrapping = TextWrapping.Wrap,
            Foreground = errors.Count > 0 ? Res("SystemFillColorCautionBrush") : Res("TextFillColorSecondaryBrush"),
        });
        var guide = Btn(_s.Get("Mig.Button.Guide"), async (_, _) => await RunAndShowAsync("guide", null));
        guide.Margin = new Thickness(0, 6, 0, 0);
        extPanel.Children.Add(guide);
        PageHost.Children.Add(Card(extPanel));
    }

    // Only the Overwrite policy replaces files without keeping a backup, so only it asks first.
    private async Task<bool> ConfirmOverwriteAsync() =>
        _migConflict != "Overwrite" || await ConfirmAsync(_s.Get("Mig.Button.Restore"), _s.Get("Mig.Confirm.Overwrite"));

    // Rules are read from tools\migrator the first time the page is opened
    private async void FillMigrationRules(StackPanel host)
    {
        List<string>? ruleErrors = null;
        if (_migRules == null)
        {
            host.Children.Add(new ProgressRing { IsActive = true, Width = 20, Height = 20, HorizontalAlignment = HorizontalAlignment.Left });
            JsonObject r;
            try
            {
                r = await _bridge.RequestAsync("migrationRules", _s.Language);
            }
            catch (Exception ex)
            {
                App.LogError(ex);
                host.Children.Clear();
                host.Children.Add(new TextBlock { Text = "\u26A0 " + _s.Format("Msg.Error", ex.Message), Foreground = Res("SystemFillColorCautionBrush"), TextWrapping = TextWrapping.Wrap });
                return;
            }
            if (!InitData.Bool(r["ok"]))
            {
                // Not cached: the next visit tries again instead of showing "no rules" for good
                host.Children.Clear();
                host.Children.Add(new TextBlock { Text = "\u26A0 " + _s.Format("Msg.Error", InitData.Str(r["Text"])), Foreground = Res("SystemFillColorCautionBrush"), TextWrapping = TextWrapping.Wrap });
                return;
            }
            ruleErrors = InitData.StrList(r["Errors"]);
            var list = new List<(string, string)>();
            foreach (var n in InitData.Arr(r["Data"]))
            {
                string id = InitData.Str(n?["Id"]);
                if (id.Length > 0) list.Add((id, InitData.Str(n?["Name"])));
            }
            _migRules = list;
            host.Children.Clear();
        }
        // Load errors (a broken user-migration-rules.psd1, duplicate Ids): the custom
        // rules are missing for a reason, and the window says which one.
        if (ruleErrors is { Count: > 0 })
        {
            foreach (string err in ruleErrors)
            {
                host.Children.Add(new TextBlock
                {
                    Text = "\u26A0 " + _s.Format("Mig.Rules.LoadErrors", err),
                    TextWrapping = TextWrapping.Wrap,
                    Foreground = Res("SystemFillColorCautionBrush"),
                });
            }
        }
        if (_migRules.Count == 0)
        {
            host.Children.Add(new TextBlock { Text = _s.Get("Mig.NoRules"), Foreground = Res("TextFillColorSecondaryBrush"), TextWrapping = TextWrapping.Wrap });
            return;
        }
        foreach (var (id, name) in _migRules)
        {
            string ruleId = id;
            string ruleLabel = $"{id} - {name}";
            var cb = new CheckBox { Content = ruleLabel, IsChecked = _migRuleIds.Contains(id) };
            AutomationProperties.SetName(cb, ruleLabel);
            ToolTipService.SetToolTip(cb, ruleLabel);
            cb.Checked += (_, _) => _migRuleIds.Add(ruleId);
            cb.Unchecked += (_, _) => _migRuleIds.Remove(ruleId);
            host.Children.Add(cb);
        }
    }

    private JsonObject MigrationArgs()
    {
        var folders = new JsonArray();
        foreach (string f in MigrationFolders.Where(_migFolders.Contains)) folders.Add(f);
        var ids = new JsonArray();
        foreach (string id in _migRuleIds) ids.Add(id);
        return new JsonObject
        {
            ["BackupRoot"] = _migRoot.Trim(),
            ["Folders"] = folders,
            ["RuleIds"] = ids,
            ["IncludeSecrets"] = !_migExcludeSecrets,
            ["ConflictPolicy"] = _migConflict,
        };
    }

    // =======================================================================================================
    // Page 10: custom scripts (tools\custom-scripts\<Stage>)
    // =======================================================================================================
    private static readonly string[] CustomScriptStages = { "PreBuild", "OfflineImage", "FirstLogon", "UserOnce" };
    private static readonly string[] OnErrorValues = { "Warn", "Stop", "Ignore" };
    private static readonly string[] CustomScriptExtensions = { ".ps1", ".bat", ".cmd", ".reg" };
    private readonly List<JsonObject> _csScripts = new();
    private string _csStage = "FirstLogon";
    private int _csSelected = -1;
    private TextBlock? _csCount;

    private void BuildCustomScriptsPage()
    {
        PageTitle.Text = CleanTabText(_s.Get("Tab.CustomScripts"));

        // Stage selection
        PageHost.Children.Add(Section(_s.Get("CS.Group.Stage")));
        var stagePanel = new StackPanel { Spacing = 6 };
        // The identifier (Tag) goes to the builder; the label is translated
        var combo = new ComboBox { MinWidth = 220, HorizontalAlignment = HorizontalAlignment.Stretch };
        foreach (string st in CustomScriptStages) combo.Items.Add(new ComboBoxItem { Content = _s.Get("CS.StageName." + st, st), Tag = st });
        combo.SelectedIndex = Math.Max(0, Array.IndexOf(CustomScriptStages, _csStage));
        var info = new TextBlock { Text = StageInfoText(_csStage), TextWrapping = TextWrapping.Wrap, Foreground = Res("TextFillColorSecondaryBrush") };
        AutomationProperties.SetLiveSetting(info, Microsoft.UI.Xaml.Automation.Peers.AutomationLiveSetting.Polite);
        var list = new StackPanel { Spacing = 2 };
        combo.SelectionChanged += async (_, _) =>
        {
            _csStage = (combo.SelectedItem as ComboBoxItem)?.Tag as string ?? "FirstLogon";
            _csSelected = -1;
            info.Text = StageInfoText(_csStage);
            await LoadCustomScriptsAsync(list);
        };
        stagePanel.Children.Add(FieldRow(_s.Get("CS.Label.Stage"), combo,
            Btn(_s.Get("CS.Button.OpenFolder"), async (_, _) => await RunAndShowAsync("customScriptOpenFolder", new JsonObject { ["Stage"] = _csStage }))));
        stagePanel.Children.Add(info);
        PageHost.Children.Add(Card(stagePanel));

        // The scripts of the stage
        PageHost.Children.Add(Section(_s.Get("CS.Group.Scripts")));
        _csCount = new TextBlock { Foreground = Res("TextFillColorSecondaryBrush") };
        AutomationProperties.SetLiveSetting(_csCount, Microsoft.UI.Xaml.Automation.Peers.AutomationLiveSetting.Polite);
        PageHost.Children.Add(_csCount);
        var scroll = new ScrollViewer { Content = list, MaxHeight = 320, HorizontalScrollBarVisibility = ScrollBarVisibility.Auto };
        PageHost.Children.Add(Card(scroll));
        _ = LoadCustomScriptsAsync(list);

        // Actions
        var actions = WrapRow(
            Btn(_s.Get("CS.Button.Add"), async (_, _) => await AddCustomScriptsAsync(list)),
            Btn(_s.Get("CS.Button.Remove"), async (_, _) => await RemoveCustomScriptAsync(list)),
            Btn(_s.Get("CS.Button.Edit"), async (_, _) => await EditCustomScriptAsync(list)),
            Btn(_s.Get("CS.Button.Reorder"), async (_, _) => await ReorderCustomScriptAsync(list)),
            Btn(_s.Get("CS.Button.Preview"), async (_, _) => await RunAndShowAsync("customScriptPreview", null, true)));
        PageHost.Children.Add(Card(actions));
    }

    // "Stage X: runs as ..., ..." from the stage table of Get-WinEaseCustomScriptStageMap (lib\WinEaseExtensions.ps1)
    private string StageInfoText(string stage)
    {
        string runsAs = stage switch
        {
            "FirstLogon" => _s.Get("CS.RunsAs.Admin"),
            "UserOnce" => _s.Get("CS.RunsAs.User"),
            _ => _s.Get("CS.RunsAs.Build"),
        };
        string where = stage switch
        {
            "FirstLogon" => _s.Format("CS.Stage.InImage", "Windows\\Setup\\Scripts\\Custom"),
            "UserOnce" => _s.Format("CS.Stage.InImage", "Windows\\Setup\\Scripts\\UserCustom"),
            _ => _s.Get("CS.Stage.BuildOnly"),
        };
        return _s.Format("CS.Stage.Info", _s.Get("CS.StageName." + stage, stage), runsAs, where);
    }

    // The scripts of the selected stage (the engine runs in the builder process)
    private async Task LoadCustomScriptsAsync(StackPanel host)
    {
        string requestedStage = _csStage;
        var r = await _bridge.RequestAsync("customScripts", _s.Language, new JsonObject { ["Stage"] = requestedStage });
        // The stage was switched while the request ran: this reply belongs to the old stage
        if (requestedStage != _csStage) return;
        if (!InitData.Bool(r["ok"]))
        {
            host.Children.Clear();
            host.Children.Add(new TextBlock { Text = "\u26A0 " + _s.Format("Msg.Error", InitData.Str(r["Text"])), Foreground = Res("SystemFillColorCautionBrush"), TextWrapping = TextWrapping.Wrap });
            return;
        }
        _csScripts.Clear();
        foreach (var n in InitData.Arr(r["Data"]))
        {
            if (n is JsonObject o) _csScripts.Add(o);
        }
        host.Children.Clear();
        if (_csCount != null) _csCount.Text = _s.Format("CS.Count", _csScripts.Count, _csStage);
        if (_csScripts.Count == 0)
        {
            host.Children.Add(new TextBlock { Text = _s.Get("CS.Msg.Empty"), Foreground = Res("TextFillColorSecondaryBrush"), TextWrapping = TextWrapping.Wrap });
            return;
        }
        // Same columns as the classic window: Name, Order, Type, Size, Condition, OnError, Description
        string[] headers = { "CS.Column.Name", "CS.Column.Order", "CS.Column.Type", "CS.Column.Size", "CS.Column.Condition", "CS.Column.OnError", "CS.Column.Description" };
        string[] fields = { "Name", "Order", "Type", "Size", "Condition", "OnError", "Description" };
        double[] widths = { 3, 1, 1, 1, 2, 1, 3 };
        Grid NewRow()
        {
            var g = new Grid { ColumnSpacing = 12, Padding = new Thickness(4, 2, 4, 2) };
            foreach (double w in widths) g.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(w, GridUnitType.Star) });
            return g;
        }
        void Cell(Grid g, int col, string text, bool strong, bool legacy)
        {
            var t = new TextBlock { Text = text, TextWrapping = TextWrapping.Wrap };
            if (strong) t.FontWeight = Microsoft.UI.Text.FontWeights.SemiBold;
            else if (col > 0) t.Foreground = Res("TextFillColorSecondaryBrush");
            if (legacy) t.Foreground = Res("SystemFillColorCautionBrush");
            Grid.SetColumn(t, col);
            g.Children.Add(t);
        }
        var head = NewRow();
        for (int c = 0; c < headers.Length; c++) Cell(head, c, _s.Get(headers[c]), true, false);
        host.Children.Add(head);
        var buttons = new List<Button>();
        void Highlight()
        {
            for (int k = 0; k < buttons.Count; k++)
            {
                buttons[k].Background = k == _csSelected ? Res("SubtleFillColorSecondaryBrush") : Res("SubtleFillColorTransparentBrush");
            }
        }
        var headerPrefixes = new string[headers.Length];
        for (int c = 1; c < headers.Length; c++)
        {
            headerPrefixes[c] = _s.Get(headers[c]) + ": ";
        }
        string legacySuffix = " (" + _s.Get("CS.Legacy") + ")";

        for (int i = 0; i < _csScripts.Count; i++)
        {
            var s = _csScripts[i];
            int index = i;
            bool legacy = InitData.Str(s["Location"]) == "Legacy";
            var row = NewRow();
            var summary = new List<string>();
            for (int c = 0; c < fields.Length; c++)
            {
                string value = InitData.Str(s[fields[c]]);
                if (fields[c] == "OnError") value = _s.Get("CS.OnError." + value, value);
                // A legacy script is marked in text too, not only by the caution colour
                if (c == 0 && legacy) value += legacySuffix;
                Cell(row, c, value, false, legacy);
                if (c > 0) summary.Add(string.Concat(headerPrefixes[c], value));
            }
            var btn = new Button { Content = row, HorizontalAlignment = HorizontalAlignment.Stretch, HorizontalContentAlignment = HorizontalAlignment.Left };
            AutomationProperties.SetName(btn, legacy ? string.Concat(InitData.Str(s["Name"]), legacySuffix) : InitData.Str(s["Name"]));
            AutomationProperties.SetHelpText(btn, string.Join(", ", summary));
            btn.Click += (_, _) => { _csSelected = index; Highlight(); };
            buttons.Add(btn);
            host.Children.Add(btn);
        }
        Highlight();
    }

    private JsonObject? SelectedCustomScript()
    {
        if (_csSelected < 0 || _csSelected >= _csScripts.Count) return null;
        return _csScripts[_csSelected];
    }

    private async Task AddCustomScriptsAsync(StackPanel list)
    {
        var paths = await PickFilesAsync(CustomScriptExtensions);
        if (paths.Count == 0) return;
        var arr = new JsonArray();
        foreach (string p in paths) arr.Add(p);
        await RunAndShowAsync("customScriptAdd", new JsonObject { ["Stage"] = _csStage, ["Paths"] = arr });
        await LoadCustomScriptsAsync(list);
    }

    private async Task RemoveCustomScriptAsync(StackPanel list)
    {
        var sel = SelectedCustomScript();
        if (sel == null)
        {
            await MessageAsync(_s.Get("Msg.Title.Default"), _s.Get("CS.Msg.NoSelection"), "Warning");
            return;
        }
        string name = InitData.Str(sel["Name"]);
        if (!await ConfirmAsync(_s.Get("CS.Button.Remove"), _s.Format("CS.Msg.ConfirmRemove", name))) return;
        await RunAndShowAsync("customScriptRemove", new JsonObject { ["Stage"] = _csStage, ["Path"] = InitData.Str(sel["Path"]) });
        _csSelected = -1;
        await LoadCustomScriptsAsync(list);
    }

    private async Task EditCustomScriptAsync(StackPanel list)
    {
        var sel = SelectedCustomScript();
        if (sel == null)
        {
            await MessageAsync(_s.Get("Msg.Title.Default"), _s.Get("CS.Msg.NoSelection"), "Warning");
            return;
        }
        var order = new TextBox { Text = InitData.Str(sel["Order"]) };
        var condition = new TextBox { Text = InitData.Str(sel["Condition"]) };
        var onError = new ComboBox { MinWidth = 140, HorizontalAlignment = HorizontalAlignment.Stretch };
        foreach (string v in OnErrorValues) onError.Items.Add(new ComboBoxItem { Content = _s.Get("CS.OnError." + v, v), Tag = v });
        string current = InitData.Str(sel["OnError"], "Warn");
        onError.SelectedIndex = Math.Max(0, Array.IndexOf(OnErrorValues, current));
        var description = new TextBox { Text = InitData.Str(sel["Description"]) };
        var panel = new StackPanel { Spacing = 8 };
        panel.Children.Add(FieldRow(_s.Get("CS.Dlg.Meta.Order"), order));
        panel.Children.Add(FieldRow(_s.Get("CS.Dlg.Meta.Condition"), condition));
        panel.Children.Add(FieldRow(_s.Get("CS.Dlg.Meta.OnError"), onError));
        panel.Children.Add(FieldRow(_s.Get("CS.Dlg.Meta.Description"), description));
        panel.Children.Add(new TextBlock { Text = _s.Get("CS.Dlg.Meta.Hint"), TextWrapping = TextWrapping.Wrap, Foreground = Res("TextFillColorSecondaryBrush") });
        var dlg = new ContentDialog
        {
            XamlRoot = Content.XamlRoot,
            Title = _s.Get("CS.Dlg.Meta.Title"),
            Content = panel,
            PrimaryButtonText = _s.Get("Button.Save", "Save"),
            CloseButtonText = _s.Get("Button.Cancel", "Cancel"),
        };
        if (await dlg.ShowAsync() != ContentDialogResult.Primary) return;
        await RunAndShowAsync("customScriptMeta", new JsonObject
        {
            ["Path"] = InitData.Str(sel["Path"]),
            ["Order"] = order.Text.Trim(),
            ["Condition"] = condition.Text.Trim(),
            ["OnError"] = (onError.SelectedItem as ComboBoxItem)?.Tag as string ?? "Warn",
            ["Description"] = description.Text.Trim(),
        });
        await LoadCustomScriptsAsync(list);
    }

    private async Task ReorderCustomScriptAsync(StackPanel list)
    {
        var sel = SelectedCustomScript();
        if (sel == null)
        {
            await MessageAsync(_s.Get("Msg.Title.Default"), _s.Get("CS.Msg.NoSelection"), "Warning");
            return;
        }
        string name = InitData.Str(sel["Name"]);
        var order = new TextBox { Text = InitData.Str(sel["Order"]) };
        var panel = new StackPanel { Spacing = 8 };
        panel.Children.Add(new TextBlock { Text = _s.Format("CS.Dlg.Reorder.Hint", name), TextWrapping = TextWrapping.Wrap });
        panel.Children.Add(FieldRow(_s.Get("CS.Dlg.Meta.Order"), order));
        var dlg = new ContentDialog
        {
            XamlRoot = Content.XamlRoot,
            Title = _s.Get("CS.Dlg.Reorder.Title"),
            Content = panel,
            PrimaryButtonText = _s.Get("Button.Save", "Save"),
            CloseButtonText = _s.Get("Button.Cancel", "Cancel"),
        };
        if (await dlg.ShowAsync() != ContentDialogResult.Primary) return;
        await RunAndShowAsync("customScriptReorder", new JsonObject { ["Path"] = InitData.Str(sel["Path"]), ["Order"] = order.Text.Trim() });
        await LoadCustomScriptsAsync(list);
    }

    // =======================================================================================================
    // Estimate (Update-WinEaseGuiEstimate)
    // =======================================================================================================
    private void UpdateEstimate()
    {
        bool C(string k) => _components.TryGetValue(k, out bool v) && v;
        bool Has(string k) => _components.ContainsKey(k);
        double mb = 5500;
        if (C("KeepExtraFonts")) mb += 150;
        if (C("KeepAsianIME")) mb += 400;
        if (Has("RemoveDefender") && !C("RemoveDefender")) mb += 200;
        if (Has("RemoveStore") && !C("RemoveStore")) mb += 120;
        if (Has("DisableWindowsUpdate") && !C("DisableWindowsUpdate")) mb += 50;
        if (C("KeepBasicApps")) mb += 30;
        if (C("KeepSearchIndex")) mb += 20;
        if (C("KeepXboxServices")) mb += 40;
        if (C("RemoveDrivers")) mb -= 80;
        if (C("UltraSlimMode")) mb -= 200;
        if (_payload == "ESD") mb = Math.Round(mb * 0.82);
        EstimateText.Text = _s.Format("Main.Estimate", Math.Round(mb / 1024, 2));
    }

    // =======================================================================================================
    // Settings as the build functions take them (Get-WinEaseGuiDraftConfig) and the final result
    // =======================================================================================================
    private JsonObject DraftConfig()
    {
        var cfg = new JsonObject();
        foreach (var kv in _components) cfg[kv.Key] = kv.Value;
        var tweaks = new JsonObject();
        foreach (var t in _init.Tweaks) tweaks[t.Key] = _tweaks.GetValueOrDefault(t.Key, t.Default);
        cfg["TweakSettings"] = tweaks;
        cfg["AdvancedDebloatStandard"] = ToArray(_init.DebloatStandard.Where(_debloatStd.Contains));
        cfg["AdvancedDebloatExperimental"] = ToArray(_init.DebloatExperimental.Where(_debloatExp.Contains).Distinct());
        cfg["DebloatEngineSelection"] = DebloatEngineSelectionObject();
        return cfg;
    }

    private static JsonArray ToArray(IEnumerable<string> items)
    {
        var a = new JsonArray();
        foreach (string s in items) a.Add(s);
        return a;
    }

    // Row + a message line under it for -field (issues of OutputDir / disk space are shown at the workspace)
    private UIElement WithMessage(string field, FrameworkElement row)
    {
        var msg = new TextBlock
        {
            TextWrapping = TextWrapping.Wrap,
            Visibility = Visibility.Collapsed,
            Margin = new Thickness(198, 0, 0, 4),
            Style = (Style)Application.Current.Resources["CaptionTextBlockStyle"],
        };
        AutomationProperties.SetLiveSetting(msg, Microsoft.UI.Xaml.Automation.Peers.AutomationLiveSetting.Polite);
        _fieldMsgs[field] = msg;
        var sp = new StackPanel();
        sp.Children.Add(row);
        sp.Children.Add(msg);
        return sp;
    }

    private void ShowIssues()
    {
        var issuesByField = new Dictionary<string, List<InputIssue>>(StringComparer.Ordinal);
        for (int i = 0; i < _issues.Count; i++)
        {
            var issue = _issues[i];
            string key = issue.Field == "OutputDir" ? "WorkDir" : issue.Field;
            if (!issuesByField.TryGetValue(key, out var list))
            {
                list = new List<InputIssue>();
                issuesByField[key] = list;
            }
            list.Add(issue);
        }

        foreach (var kv in _fieldMsgs)
        {
            if (!issuesByField.TryGetValue(kv.Key, out var mine) || mine.Count == 0)
            {
                kv.Value.Text = "";
                kv.Value.Visibility = Visibility.Collapsed;
                continue;
            }
            bool error = false;
            for (int i = 0; i < mine.Count; i++)
            {
                if (mine[i].Severity == "Error")
                {
                    error = true;
                    break;
                }
            }
            // Icon and word before the text: the severity never depends on the colour
            kv.Value.Text = (error ? "\u26A0 " + _s.Get("Severity.Error") : "\u24D8 " + _s.Get("Severity.Warning")) + ": " + string.Join(" ", mine.Select(i => i.Text));
            kv.Value.Foreground = Res(error ? "SystemFillColorCriticalBrush" : "SystemFillColorCautionBrush");
            kv.Value.Visibility = Visibility.Visible;
        }
    }

    // Debounced re-check while the user types or a picker fills a box
    private void ScheduleValidation()
    {
        _validateTimer ??= new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(500) };
        _validateTimer.Tick -= ValidateTimer_Tick;
        _validateTimer.Tick += ValidateTimer_Tick;
        _validateTimer.Stop();
        _validateTimer.Start();
    }

    private async void ValidateTimer_Tick(object? sender, object e)
    {
        _validateTimer?.Stop();
        if (_busy || _validating || _resultSent) return;
        var issues = await ValidateAsync(withDisk: false);
        if (issues == null) return;
        _issues = issues;
        ShowIssues();
    }

    // Test-WinEaseBuildInputs through the host; null when the host could not answer
    private async Task<List<InputIssue>?> ValidateAsync(bool withDisk)
    {
        _validating = true;
        try
        {
            var reply = await _bridge.RequestAsync("validate", _s.Language, new JsonObject { ["Config"] = ResultObject(false), ["Disk"] = withDisk });
            if (!InitData.Bool(reply["ok"])) return null;
            var list = new List<InputIssue>();
            foreach (var i in InitData.Arr(reply["Data"]?["Issues"]))
                list.Add(new InputIssue(InitData.Str(i?["Field"]), InitData.Str(i?["Severity"]), InitData.Str(i?["Text"]), InitData.Bool(i?["Confirm"])));
            return list;
        }
        catch
        {
            return null;
        }
        finally
        {
            _validating = false;
        }
    }

    private JsonObject ResultObject(bool consent)
    {
        var components = new JsonObject();
        foreach (var kv in _components) components[kv.Key] = kv.Value;
        var tweaks = new JsonObject();
        foreach (var t in _init.Tweaks) tweaks[t.Key] = _tweaks.GetValueOrDefault(t.Key, t.Default);
        return new JsonObject
        {
            ["Success"] = true,
            ["SourceDrive"] = _source.Trim(),
            ["WorkDir"] = _workDir.Trim(),
            ["Index"] = _index.Trim(),
            ["InjectDrivers"] = _drivers.Trim(),
            ["UserName"] = _userName.Trim(),
            ["ComputerName"] = _computerName.Trim().Length == 0 ? "*" : _computerName.Trim(),
            // Hand-edited (or Custom) -> "Custom"; BasePresetKey keeps the preset the values started from
            ["PresetKey"] = !IsCustomResult && _presetIndex < _init.Presets.Count ? _init.Presets[_presetIndex].Key : "Custom",
            ["BasePresetKey"] = _basePresetKey,
            ["DryRun"] = DryRunCheck.IsChecked == true,
            ["UseVHDX"] = _useVhdx,
            ["ExportESDMode"] = _payload == "ESD",
            ["SplitWIMMode"] = _payload == "SWM",
            ["Components"] = components,
            ["TweakSettings"] = tweaks,
            ["AdvancedDebloatStandard"] = ToArray(_init.DebloatStandard.Where(_debloatStd.Contains)),
            ["AdvancedDebloatExperimental"] = ToArray(_init.DebloatExperimental.Where(_debloatExp.Contains).Distinct()),
            ["DebloatEngineSelection"] = DebloatEngineSelectionObject(),
            ["PhysicalDebloatConsent"] = consent,
        };
    }

    // The engine per Advanced Debloat target. Only the targets that run on another engine than
    // their registered default are reported, so the profile stays small.
    private JsonObject DebloatEngineSelectionObject()
    {
        var engines = new JsonObject();
        foreach (string item in _init.DebloatStandard.Concat(_init.DebloatExperimental).Distinct())
        {
            bool selected = _debloatStd.Contains(item) || _debloatExp.Contains(item);
            if (!selected) continue;
            string engine = DebloatEngineOf(item);
            string fallback = _init.DebloatEngines.TryGetValue(item, out var def) ? def.Default : "PowerShell";
            if (engine != fallback) engines[item] = engine;
        }
        return engines;
    }

    // =======================================================================================================
    // Command bar
    // =======================================================================================================
    private async void StartButton_Click(object sender, RoutedEventArgs e)
    {
        if (_busy || _starting || _resultSent) return;
        _starting = true;
        try
        {
            await StartBuildFlowAsync();
        }
        catch (Exception ex)
        {
            App.LogError(ex);
            await MessageAsync(_s.Get("Val.Title"), _s.Format("Msg.Error", ex.Message), "Error");
        }
        finally
        {
            _starting = false;
        }
    }

    private async Task StartBuildFlowAsync()
    {
        if (_busy) return;
        // Same input check as Complete-WinEaseGuiResult, the session bridge and the builder (PowerShell: Test-WinEaseBuildInputs).
        // An Error blocks Start and is shown under its control; never fail open when the check cannot run.
        var issues = await ValidateAsync(withDisk: true);
        if (issues == null)
        {
            await MessageAsync(_s.Get("Val.Title"), _s.Format("Msg.Error", _s.Get("Plan.Value.Unknown")), "Error");
            return;
        }
        _issues = issues;
        ShowIssues();
        var errors = issues.Where(i => i.Severity == "Error").ToList();
        if (errors.Count > 0)
        {
            var mediaItem = Nav.MenuItems.OfType<NavigationViewItem>().FirstOrDefault(i => i.Tag as string == "media");
            if (mediaItem != null && _page != "media") Nav.SelectedItem = mediaItem;
            await MessageAsync(_s.Get("Val.Title"), string.Join("\n", errors.Select(i => i.Text)), "Warning");
            return;
        }
        if (issues.Any(i => i.Confirm) && !await ConfirmAsync(_s.Get("Val.Title"), _s.Get("Val.Index.Confirm"))) return;
        // Dependency / feature-impact pre-check
        var dep = await RunAsync("dependencies", new JsonObject { ["Config"] = DraftConfig() }, quiet: true);
        if (dep == null || !InitData.Bool(dep["ok"]))
        {
            // Never fail open: an unchecked selection may hide a conflict or an unknown impact, so the user has to say so
            string why = dep == null ? _s.Get("Plan.Value.Unknown") : InitData.Str(dep["Text"], _s.Get("Plan.Value.Unknown"));
            if (!await ShowBuildPlanDialogAsync(CheckFailedView(why))) return;
        }
        else if (InitData.Bool(dep["Data"]?["HasIssues"]))
        {
            var depData = dep["Data"]!.AsObject();
            // Critical (conflict / Unknown) needs its own explicit acknowledgement, separate from the plain-impact confirm
            if (InitData.Bool(depData["HasCritical"]) && !await ShowDependencyDialogAsync(depData, acknowledge: true)) return;
            if (InitData.Arr(depData["Impact"]).Any() &&
                !await ConfirmAsync(_s.Get("Msg.Dependency.Title"), _s.Format("Msg.Dependency.Confirm", InitData.Str(depData["ImpactText"])))) return;
        }

        // Physical debloat consent (the builder's -AllowPhysicalDebloat gate)
        bool consent = false;
        int std = _debloatStd.Count, exp = _debloatExp.Count;
        // Declining clears the selection; a cancelled final confirmation puts it back
        var stdBefore = _debloatStd.ToList();
        var expBefore = _debloatExp.ToList();
        var enginesBefore = _debloatEngines.ToDictionary(kv => kv.Key, kv => kv.Value, StringComparer.Ordinal);
        if (std + exp > 0)
        {
            consent = await ConfirmAsync(_s.Get("Msg.PhysicalConsent.Title"), _s.Format("Msg.PhysicalConsent.Text", std, exp));
            if (!consent)
            {
                _debloatStd.Clear();
                _debloatExp.Clear();
                _debloatEngines.Clear();
            }
        }

        // The consent gate may have cleared the Advanced Debloat selection: the state must match what is sent
        _presetStateTimer?.Stop();
        await RefreshPresetStateAsync();

        // Final confirmation: the build plan of exactly the settings below, recomputed now by the builder (Get-WinEaseBuildPlan)
        var result = ResultObject(consent);
        var planReply = await RunAsync("buildPlan", new JsonObject { ["Config"] = result.DeepClone() }, quiet: true);
        bool confirmed;
        if (planReply != null && InitData.Bool(planReply["ok"]) && planReply["Data"]?["Plan"] is JsonObject plan && planReply["Data"]?["View"] is JsonObject view)
        {
            confirmed = await ShowBuildPlanDialogAsync(view);
            if (confirmed) result["BuildPlan"] = plan.DeepClone();
        }
        else
        {
            // No plan: the user decides explicitly, the result is never sent silently without the summary
            string why = planReply == null ? _s.Get("Plan.Value.Unknown") : InitData.Str(planReply["Text"], _s.Get("Plan.Value.Unknown"));
            confirmed = await ConfirmAsync(_s.Get("Msg.Dependency.Title"), _s.Format("Msg.Plan.Failed.Continue", why));
        }
        if (!confirmed)
        {
            foreach (string i in stdBefore) _debloatStd.Add(i);
            foreach (string i in expBefore) _debloatExp.Add(i);
            foreach (var kv in enginesBefore) _debloatEngines[kv.Key] = kv.Value;
            await RefreshPresetStateAsync();
            return;
        }
        await SendResultAndCloseAsync(result);
    }

    // Reply of a failed dependency check, shaped like a plan view so the same dialog asks for the acknowledgement
    private JsonObject CheckFailedView(string reason)
    {
        return new JsonObject
        {
            ["Title"] = _s.Get("Msg.Dependency.Title"),
            ["ModeText"] = _s.Format("Msg.Dependency.CheckFailed", reason),
            ["IsDryRun"] = false,
            ["RequiresAck"] = true,
            ["AckText"] = _s.Get("Msg.Dependency.CheckFailed.Checkbox"),
            ["ConfirmText"] = _s.Get("Dep.Ack.Continue"),
            ["Sections"] = new JsonArray(),
        };
    }

    // Final confirmation (build plan). The mode banner (DRY RUN / REAL BUILD) and the acknowledgement checkbox stay
    // visible; the sections scroll between them, text wraps and nothing is truncated. A critical plan keeps the
    // confirm button disabled until the box is ticked. Returns true when the user confirmed.
    private async Task<bool> ShowBuildPlanDialogAsync(JsonObject view)
    {
        bool dry = InitData.Bool(view["IsDryRun"]);
        bool ackNeeded = InitData.Bool(view["RequiresAck"]);
        static (string Glyph, string Brush) IconFor(string severity) => severity switch
        {
            "Critical" => ("", "SystemFillColorCriticalBrush"),
            "Warning" => ("", "SystemFillColorCautionBrush"),
            _ => ("", "AccentTextFillColorPrimaryBrush"),
        };
        var outer = new StackPanel { Spacing = 12 };
        var banner = new Border
        {
            Padding = new Thickness(12, 8, 12, 8),
            CornerRadius = new CornerRadius(4),
            Background = Res(dry ? "SystemFillColorAttentionBackgroundBrush" : "SystemFillColorCautionBackgroundBrush"),
            Child = new TextBlock { Text = InitData.Str(view["ModeText"]), FontSize = 18, FontWeight = Microsoft.UI.Text.FontWeights.Bold, TextWrapping = TextWrapping.Wrap, IsTextSelectionEnabled = true },
        };
        outer.Children.Add(banner);

        var panel = new StackPanel { Spacing = 6 };
        foreach (var sec in InitData.Arr(view["Sections"]))
        {
            var (g, b) = IconFor(InitData.Str(sec?["Severity"]));
            var head = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8, Margin = new Thickness(0, 8, 0, 0) };
            head.Children.Add(new FontIcon { Glyph = g, Foreground = Res(b), FontSize = 16 });
            head.Children.Add(new TextBlock { Text = InitData.Str(sec?["Heading"]), FontWeight = Microsoft.UI.Text.FontWeights.SemiBold, TextWrapping = TextWrapping.Wrap });
            panel.Children.Add(head);
            foreach (string line in InitData.StrList(sec?["Lines"]))
                panel.Children.Add(new TextBlock { Text = line, TextWrapping = TextWrapping.Wrap, IsTextSelectionEnabled = true, Margin = new Thickness(24, 0, 0, 0) });
        }
        double maxHeight = Math.Max(240, Content.XamlRoot.Size.Height - 380);
        if (panel.Children.Count > 0)
            outer.Children.Add(new ScrollViewer { Content = panel, MaxHeight = maxHeight, HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled, HorizontalScrollMode = ScrollMode.Disabled });

        var dlg = new ContentDialog
        {
            XamlRoot = Content.XamlRoot,
            Title = InitData.Str(view["Title"]),
            Content = outer,
            PrimaryButtonText = InitData.Str(view["ConfirmText"], _s.Get("Button.OK")),
            CloseButtonText = _s.Get("Button.Cancel"),
            DefaultButton = ContentDialogButton.Close,
            IsPrimaryButtonEnabled = !ackNeeded,
        };
        dlg.Resources["ContentDialogMaxWidth"] = 900.0;
        if (ackNeeded)
        {
            var ack = new CheckBox { Content = InitData.Str(view["AckText"]), Margin = new Thickness(0, 4, 0, 0) };
            ack.Checked += (_, _) => dlg.IsPrimaryButtonEnabled = true;
            ack.Unchecked += (_, _) => dlg.IsPrimaryButtonEnabled = false;
            outer.Children.Add(ack);
        }
        return await dlg.ShowAsync() == ContentDialogResult.Primary;
    }

    private async void CancelButton_Click(object sender, RoutedEventArgs e)
    {
        if (_busy) return;
        await SendResultAndCloseAsync(new JsonObject { ["Success"] = false });
    }

    private async void AppWindow_Closing(AppWindow sender, AppWindowClosingEventArgs args)
    {
        if (_resultSent)
        {
            // Closing during a real build is a decision, not an accident: cancel it, keep it running in the
            // console, or stay. Without a running build (finished, or no progress view) the window just closes.
            if (!_progressActive || _buildFinished || _allowClose) return;
            args.Cancel = true;
            if (!_closeDialogOpen) await ConfirmCloseDuringBuildAsync();
            return;
        }
        args.Cancel = true;
        if (_busy) return;
        await SendResultAndCloseAsync(new JsonObject { ["Success"] = false });
    }

    // Cancel build / Keep running in console / Stay. Cancel is offered only when the builder advertised it.
    private async Task ConfirmCloseDuringBuildAsync()
    {
        _closeDialogOpen = true;
        try
        {
            var body = new StackPanel { Spacing = 8 };
            body.Children.Add(new TextBlock { Text = _s.Get("Progress.Close.Body"), TextWrapping = TextWrapping.Wrap });
            string note = _cancelRequested ? _s.Get("Progress.Close.CancelPending")
                : !_cancelSupported ? _s.Get("Progress.Close.CancelUnavailable") : "";
            if (note.Length > 0) body.Children.Add(new TextBlock { Text = note, TextWrapping = TextWrapping.Wrap, Opacity = 0.8 });
            var dlg = new ContentDialog
            {
                XamlRoot = Content.XamlRoot,
                Title = _s.Get("Progress.Close.Title"),
                Content = body,
                PrimaryButtonText = _s.Get("Progress.Close.CancelBuild"),
                SecondaryButtonText = _s.Get("Progress.Close.KeepRunning"),
                CloseButtonText = _s.Get("Progress.Close.Stay"),
                DefaultButton = ContentDialogButton.Close,
                IsPrimaryButtonEnabled = _cancelSupported && !_cancelRequested,
            };
            var choice = await dlg.ShowAsync();
            if (choice == ContentDialogResult.Primary)
            {
                // The window stays open: it shows "Cancelling..." and the result when the builder reports it
                _requestCancel?.Invoke();
            }
            else if (choice == ContentDialogResult.Secondary)
            {
                // Explicit: the window closes, the build keeps running in the console
                _allowClose = true;
                Close();
            }
        }
        finally
        {
            _closeDialogOpen = false;
        }
    }

    private async Task SendResultAndCloseAsync(JsonObject result)
    {
        if (_resultSent) return;
        _resultSent = true;
        try
        {
            await _bridge.SendResultAsync(_s.Language, result);
        }
        catch (Exception ex)
        {
            // The builder never got the result: the window must stay usable and say so, not stay
            // locked in a "sent" state with nothing started.
            _resultSent = false;
            App.LogError(ex);
            await MessageAsync(_s.Get("Val.Title"), _s.Format("Msg.Error", ex.Message), "Error");
            return;
        }
        // A real build keeps the window open and shows its progress; cancel and dry run close as before
        if (_bridge.IsConnected && InitData.Bool(result["Success"]) && !InitData.Bool(result["DryRun"]))
        {
            await ShowProgressViewAsync();
            return;
        }
        Close();
    }

    // =======================================================================================================
    // Build progress (progress lines from the builder after the result was sent)
    // =======================================================================================================
    // Data files the progress window may open with the shell; programs and scripts are never launched from here.
    private static readonly string[] OpenableExtensions = { ".log", ".txt", ".html", ".htm", ".json", ".md" };
    private const int MaxLogLines = 500;

    // The cancel request file the builder advertised: an absolute path whose file name is exactly cancel.request
    // in an existing folder. The window only creates that one file; it never deletes or runs anything.
    private static bool IsValidCancelPath(string? path)
    {
        if (string.IsNullOrWhiteSpace(path) || !System.IO.Path.IsPathRooted(path)) return false;
        if (!string.Equals(System.IO.Path.GetFileName(path), "cancel.request", StringComparison.OrdinalIgnoreCase)) return false;
        string? dir = System.IO.Path.GetDirectoryName(path);
        return !string.IsNullOrEmpty(dir) && System.IO.Directory.Exists(dir);
    }

    private static bool PathExists(string? path) =>
        !string.IsNullOrWhiteSpace(path) && System.IO.Path.IsPathRooted(path) && (System.IO.File.Exists(path) || System.IO.Directory.Exists(path));

    // The folder that holds the output file (or the folder itself); null when the folder does not exist.
    // The file itself does not have to exist yet: after an early failure the output folder is still useful.
    private static string? FolderOf(string? path)
    {
        if (string.IsNullOrWhiteSpace(path) || !System.IO.Path.IsPathRooted(path)) return null;
        string? folder = System.IO.Directory.Exists(path) ? path : System.IO.Path.GetDirectoryName(path);
        return !string.IsNullOrEmpty(folder) && System.IO.Directory.Exists(folder) ? folder : null;
    }

    // Opens an existing folder or data file with the shell safely.
    private static bool TryOpenPath(string? path)
    {
        if (string.IsNullOrWhiteSpace(path) || !System.IO.Path.IsPathRooted(path)) return false;
        try
        {
            string fullPath = System.IO.Path.GetFullPath(path);

            if (System.IO.Directory.Exists(fullPath))
            {
                string safeDir = fullPath.TrimEnd(System.IO.Path.DirectorySeparatorChar, System.IO.Path.AltDirectorySeparatorChar);
                if (safeDir.Length == 2 && safeDir[1] == ':')
                {
                    safeDir += System.IO.Path.DirectorySeparatorChar;
                }

                System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo
                {
                    FileName = safeDir,
                    UseShellExecute = true
                });
                return true;
            }

            if (System.IO.File.Exists(fullPath))
            {
                string ext = System.IO.Path.GetExtension(fullPath);
                if (!OpenableExtensions.Contains(ext, StringComparer.OrdinalIgnoreCase)) return false;

                System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo
                {
                    FileName = fullPath,
                    UseShellExecute = true
                });
                return true;
            }

            return false;
        }
        catch (Exception ex) when (ex is System.ComponentModel.Win32Exception || ex is System.IO.IOException || ex is InvalidOperationException || ex is UnauthorizedAccessException || ex is ArgumentException)
        {
            return false;
        }
    }

    // Builder events (docs\PROGRESS_PROTOCOL.md): state, phase, log, failure, done. An event this window does not
    // know is ignored, so an older builder and a newer builder both work.
    private async Task ShowProgressViewAsync()
    {
        var bodyStrong = (Style)Application.Current.Resources["BodyStrongTextBlockStyle"];
        var caption = (Style)Application.Current.Resources["CaptionTextBlockStyle"];
        var title = new TextBlock { Text = _s.Get("Progress.Title"), Style = (Style)Application.Current.Resources["TitleTextBlockStyle"] };
        var stateText = new TextBlock { Style = bodyStrong, TextWrapping = TextWrapping.Wrap };
        var stepText = new TextBlock { Text = _s.Get("Progress.Starting"), TextWrapping = TextWrapping.Wrap };
        var bar = new ProgressBar { Minimum = 0, Maximum = 100, Value = 0, IsIndeterminate = true };
        var barText = new TextBlock { Style = caption };
        var timeText = new TextBlock { Style = caption };
        var verifyText = new TextBlock { TextWrapping = TextWrapping.Wrap, FontWeight = Microsoft.UI.Text.FontWeights.SemiBold, Visibility = Visibility.Collapsed };
        var hint = new TextBlock { Text = _s.Get("Progress.Hint"), TextWrapping = TextWrapping.Wrap, Opacity = 0.7 };
        // Cancel: enabled only when the builder advertises it (hello event); until then it says why it is disabled
        var cancelBuildButton = new Button { Content = _s.Get("Progress.Button.Cancel"), IsEnabled = false, HorizontalAlignment = HorizontalAlignment.Left };
        var cancelText = new TextBlock { Text = _s.Get("Progress.Cancel.Unsupported"), TextWrapping = TextWrapping.Wrap, FontWeight = Microsoft.UI.Text.FontWeights.SemiBold };
        ToolTipService.SetToolTip(cancelBuildButton, _s.Get("Progress.Cancel.Unsupported"));
        cancelBuildButton.Click += (_, _) => _requestCancel?.Invoke();

        // Failure panel: failed step, reason, details without secrets, log location and the next actions
        var failTitle = new TextBlock { Text = _s.Get("Progress.Failure.Title"), Style = bodyStrong };
        var failStep = new TextBlock { TextWrapping = TextWrapping.Wrap, IsTextSelectionEnabled = true };
        var failReason = new TextBlock { TextWrapping = TextWrapping.Wrap };
        var failDetail = new TextBlock { TextWrapping = TextWrapping.Wrap, IsTextSelectionEnabled = true, Opacity = 0.85 };
        var failLog = new TextBlock { TextWrapping = TextWrapping.Wrap, IsTextSelectionEnabled = true };
        var failNext = new StackPanel { Spacing = 2 };
        failNext.Children.Add(new TextBlock { Text = _s.Get("Progress.Failure.NextHeading"), Style = bodyStrong, Margin = new Thickness(0, 6, 0, 0) });
        foreach (string nextText in new[] { _s.Get("Progress.Failure.Next.Log"), _s.Get("Progress.Failure.Next.Diag"), _s.Get("Progress.Failure.Next.Retry"), _s.Get("Progress.Failure.Next.Docs") })
            failNext.Children.Add(new TextBlock { Text = "• " + nextText, TextWrapping = TextWrapping.Wrap });
        var failCancelNext = new TextBlock { Text = "• " + _s.Get("Progress.Cancel.Next.Docs"), TextWrapping = TextWrapping.Wrap, Visibility = Visibility.Collapsed };
        failNext.Children.Add(failCancelNext);
        var failPanel = new StackPanel { Spacing = 4, Visibility = Visibility.Collapsed };
        failPanel.Children.Add(failTitle);
        failPanel.Children.Add(failStep);
        failPanel.Children.Add(failReason);
        failPanel.Children.Add(failDetail);
        failPanel.Children.Add(failLog);
        failPanel.Children.Add(failNext);

        // Bounded log pane: the newest MaxLogLines lines, scrolled to the end
        var logLines = new System.Collections.ObjectModel.ObservableCollection<string>();
        var logHeading = new TextBlock { Text = _s.Get("Progress.Log.Heading"), Style = caption };
        var logView = new ListView
        {
            ItemsSource = logLines,
            SelectionMode = ListViewSelectionMode.None,
            MaxHeight = 220,
            FontFamily = new Microsoft.UI.Xaml.Media.FontFamily("Consolas"),
            FontSize = 12,
        };

        string logPath = "", reportPath = "", outputPath = "", diagPath = "", docsPath = "";
        Button MakeButton(string text, string help, Action onClick, bool visible = true)
        {
            var b = new Button { Content = text, IsEnabled = false, Visibility = visible ? Visibility.Visible : Visibility.Collapsed };
            b.Click += (_, _) => onClick();
            AutomationProperties.SetName(b, text);
            AutomationProperties.SetHelpText(b, help);
            return b;
        }
        var openLog = MakeButton(_s.Get("Progress.Button.OpenLog"), _s.Get("Progress.Help.OpenLog"), () => TryOpenPath(logPath));
        var openReport = MakeButton(_s.Get("Progress.Button.OpenReport"), _s.Get("Progress.Help.OpenReport"), () => TryOpenPath(reportPath));
        var openOutput = MakeButton(_s.Get("Progress.Button.OpenOutput"), _s.Get("Progress.Help.OpenOutput"), () => TryOpenPath(FolderOf(outputPath)));
        var openDiag = MakeButton(_s.Get("Progress.Button.OpenDiag"), _s.Get("Progress.Help.OpenDiag"), () => TryOpenPath(diagPath));
        var openDocs = MakeButton(_s.Get("Progress.Button.OpenDocs"), _s.Get("Progress.Help.OpenDocs"), () => TryOpenPath(docsPath), visible: false);
        var closeButton = new Button { Content = _s.Get("Progress.Close"), IsEnabled = false, HorizontalAlignment = HorizontalAlignment.Right };
        closeButton.Click += (_, _) => Close();
        var buttons = new WrapPanel { HorizontalSpacing = 8, VerticalSpacing = 8, HorizontalAlignment = HorizontalAlignment.Left };
        foreach (var b in new[] { openLog, openReport, openOutput, openDiag, openDocs })
        {
            buttons.Children.Add(b);
        }

        // Accessibility: every control has a name and a help text; text that changes mirrors its text in the name
        AutomationProperties.SetName(title, _s.Get("Progress.Title"));
        AutomationProperties.SetHelpText(stateText, _s.Get("Progress.Help.State"));
        AutomationProperties.SetLiveSetting(stateText, Microsoft.UI.Xaml.Automation.Peers.AutomationLiveSetting.Polite);
        AutomationProperties.SetHelpText(stepText, _s.Get("Progress.Help.Bar"));
        AutomationProperties.SetName(bar, _s.Get("Progress.Help.Bar"));
        AutomationProperties.SetHelpText(bar, _s.Get("Progress.Help.Bar"));
        AutomationProperties.SetName(barText, _s.Get("Progress.Help.Bar"));
        AutomationProperties.SetHelpText(barText, _s.Get("Progress.Help.Bar"));
        AutomationProperties.SetHelpText(timeText, _s.Get("Progress.Help.Time"));
        AutomationProperties.SetHelpText(verifyText, _s.Get("Progress.Help.State"));
        AutomationProperties.SetLiveSetting(verifyText, Microsoft.UI.Xaml.Automation.Peers.AutomationLiveSetting.Polite);
        AutomationProperties.SetName(failPanel, _s.Get("Progress.Failure.Title"));
        AutomationProperties.SetHelpText(failPanel, _s.Get("Progress.Failure.NextHeading"));
        AutomationProperties.SetName(logView, _s.Get("Progress.Log.Heading"));
        AutomationProperties.SetHelpText(logView, _s.Get("Progress.Help.Log"));
        AutomationProperties.SetName(logHeading, _s.Get("Progress.Log.Heading"));
        AutomationProperties.SetName(hint, _s.Get("Progress.Hint"));
        AutomationProperties.SetName(closeButton, _s.Get("Progress.Close"));
        AutomationProperties.SetName(cancelBuildButton, _s.Get("Progress.Button.Cancel"));
        AutomationProperties.SetHelpText(cancelBuildButton, _s.Get("Progress.Help.Cancel"));
        AutomationProperties.SetLiveSetting(cancelText, Microsoft.UI.Xaml.Automation.Peers.AutomationLiveSetting.Polite);
        AutomationProperties.SetHelpText(closeButton, _s.Get("Progress.Help.Close"));
        foreach (var failText in new[] { failStep, failReason, failDetail, failLog })
            AutomationProperties.SetHelpText(failText, _s.Get("Progress.Failure.Title"));
        var dynamicTexts = new[] { stateText, stepText, barText, timeText, verifyText, cancelText, failStep, failReason, failDetail, failLog };

        var panel = new StackPanel { Spacing = 10, Padding = new Thickness(32, 48, 32, 32), MaxWidth = 900, VerticalAlignment = VerticalAlignment.Center };
        panel.Children.Add(title);
        panel.Children.Add(stateText);
        panel.Children.Add(stepText);
        panel.Children.Add(bar);
        panel.Children.Add(barText);
        panel.Children.Add(timeText);
        panel.Children.Add(verifyText);
        panel.Children.Add(failPanel);
        panel.Children.Add(logHeading);
        panel.Children.Add(logView);
        panel.Children.Add(hint);
        panel.Children.Add(cancelBuildButton);
        panel.Children.Add(cancelText);
        panel.Children.Add(buttons);
        panel.Children.Add(closeButton);
        Content = new ScrollViewer { Content = panel, VerticalScrollBarVisibility = ScrollBarVisibility.Auto };

        var started = DateTime.UtcNow;
        double estimate = 0;
        double phase = 0, total = 0;
        string phaseName = "", state = "Preparing", verification = "";
        string failedPhase = "", failKey = "", failSummary = "";
        bool finished = false, doneSuccess = false, failed = false, cancelledFlag = false;
        _progressActive = true;
        _buildFinished = false;
        _cancelSupported = false;
        _cancelRequested = false;
        _cancelRequestPath = "";

        string StateLabel(string st) => st switch
        {
            "Preparing" => _s.Get("Progress.State.Preparing"),
            "Running" => _s.Get("Progress.State.Running"),
            "Verifying" => _s.Get("Progress.State.Verifying"),
            "Succeeded" => _s.Get("Progress.State.Succeeded"),
            "NotVerified" => _s.Get("Progress.State.NotVerified"),
            "Failed" => _s.Get("Progress.State.Failed"),
            "Cancelling" => _s.Get("Progress.State.Cancelling"),
            "Cancelled" => _s.Get("Progress.State.Cancelled"),
            _ => st,
        };
        // Only the known message keys are translated; anything else falls back to the generic text
        string FailureMessage(string key) => key switch
        {
            "Progress.Failure.Source" => _s.Get("Progress.Failure.Source"),
            "Progress.Failure.Verification" => _s.Get("Progress.Failure.Verification"),
            "Progress.Failure.Iso" => _s.Get("Progress.Failure.Iso"),
            "Progress.Cancel.CleanupFailed" => _s.Get("Progress.Cancel.CleanupFailed"),
            _ => _s.Get("Progress.Failure.Generic"),
        };
        static double Num(JsonObject m, string key)
        {
            try { return m[key] == null ? double.NaN : (double)m[key]!; }
            catch (Exception ex) when (ex is FormatException || ex is InvalidOperationException) { return double.NaN; }
        }
        static string PathOf(JsonObject m, string key, string current)
        {
            string v = InitData.Str(m[key]);
            return v.Length > 0 ? v : current;
        }

        void UpdateButtons()
        {
            openLog.IsEnabled = PathExists(logPath);
            openReport.IsEnabled = PathExists(reportPath);
            openOutput.IsEnabled = FolderOf(outputPath) != null;
            openDiag.IsEnabled = PathExists(diagPath);
            openDocs.IsEnabled = PathExists(docsPath);
            openDocs.Visibility = failed ? Visibility.Visible : Visibility.Collapsed;
            cancelBuildButton.IsEnabled = _cancelSupported && !_cancelRequested && !finished;
            cancelBuildButton.Visibility = finished ? Visibility.Collapsed : Visibility.Visible;
        }
        // Cancel: enabled only with the builder's capability. The builder's own state (Cancelling, Cancelled) is the
        // only thing that says the build is cancelled; the request text below only says that we are waiting.
        string? DoCancel()
        {
            if (!_cancelSupported || _cancelRequested || finished) return null;
            try
            {
                if (!IsValidCancelPath(_cancelRequestPath)) throw new System.IO.IOException("invalid cancel request path");
                System.IO.File.WriteAllText(_cancelRequestPath, "cancel requested " + DateTime.UtcNow.ToString("o"));
            }
            catch (Exception ex) when (ex is System.IO.IOException || ex is UnauthorizedAccessException || ex is ArgumentException || ex is NotSupportedException)
            {
                cancelText.Text = _s.Format("Progress.Cancel.RequestFailed", ex.Message);
                cancelText.Visibility = Visibility.Visible;
                return ex.Message;
            }
            _cancelRequested = true;
            cancelText.Text = _s.Get("Progress.Cancel.Waiting") + " " + _s.Get("Progress.Cancel.WaitingNote");
            cancelText.Visibility = Visibility.Visible;
            AutomationProperties.SetName(cancelText, cancelText.Text);
            cancelBuildButton.IsEnabled = false;
            return null;
        }
        _requestCancel = DoCancel;
        void UpdateTime()
        {
            var elapsed = DateTime.UtcNow - started;
            string text = _s.Format("Progress.Elapsed", $"{(int)elapsed.TotalMinutes}:{elapsed.Seconds:D2}");
            if (estimate > 0 && !finished)
            {
                double remain = Math.Max(0, estimate - elapsed.TotalSeconds);
                text += "  " + _s.Format("Progress.Remaining", Math.Max(1, (int)Math.Ceiling(remain / 60)));
            }
            timeText.Text = text;
            UpdateButtons();
        }
        void Refresh()
        {
            stateText.Text = _s.Format("Progress.State", StateLabel(state));
            if (total > 0)
            {
                // A step count: the bar is determinate only because it really is phase-based, and it says so
                double done = finished && doneSuccess && state == "Succeeded" ? total : Math.Max(0, Math.Min(phase - 1, total));
                bar.IsIndeterminate = false;
                bar.Maximum = total;
                bar.Value = done;
                barText.Text = _s.Format("Progress.StepsBar", (int)done, (int)total);
                stepText.Text = _s.Format("Progress.Step", (int)phase, (int)total) + (phaseName.Length > 0 ? " - " + phaseName : "");
            }
            else
            {
                bar.IsIndeterminate = !finished;
                barText.Text = "";
            }
            bool cancelledDone = finished && state == "Cancelled";
            if (finished && !failed && !cancelledDone)
            {
                // Success is shown only for a verified result; unknown or not-run verification is "not verified"
                bool verified = verification == "Verified" && state == "Succeeded";
                verifyText.Text = verified ? _s.Get("Progress.Done") + " " + _s.Get("Progress.Verified") : _s.Get("Progress.NotVerified");
                verifyText.Visibility = Visibility.Visible;
            }
            if (cancelledDone)
            {
                cancelText.Text = _s.Get("Progress.Cancel.Done");
                cancelText.Visibility = Visibility.Visible;
            }
            else if (finished && _cancelRequested)
            {
                // The build ended without honouring the request (it finished or failed first)
                cancelText.Text = _s.Get("Progress.Cancel.TooLate");
                cancelText.Visibility = Visibility.Visible;
            }
            if (failed)
            {
                failCancelNext.Visibility = cancelledFlag ? Visibility.Visible : Visibility.Collapsed;
                failPanel.Visibility = Visibility.Visible;
                failStep.Text = _s.Format("Progress.Failure.Step", failedPhase.Length > 0 ? failedPhase : _s.Get("Progress.State.Preparing"));
                failReason.Text = _s.Format("Progress.Failure.Reason", FailureMessage(failKey));
                failDetail.Text = failSummary.Length > 0 ? _s.Format("Progress.Failure.Detail", failSummary) : "";
                failDetail.Visibility = failSummary.Length > 0 ? Visibility.Visible : Visibility.Collapsed;
                failLog.Text = logPath.Length > 0 ? _s.Format("Progress.Failure.LogAt", logPath) : "";
                failLog.Visibility = logPath.Length > 0 ? Visibility.Visible : Visibility.Collapsed;
            }
            foreach (var t in dynamicTexts) AutomationProperties.SetName(t, t.Text);
            UpdateTime();
        }
        void AddLogLine(string text)
        {
            if (text.Length > 500) text = text[..500] + "...";
            logLines.Add(text);
            while (logLines.Count > MaxLogLines) logLines.RemoveAt(0);
            logView.ScrollIntoView(logLines[^1]);
        }

        var timer = new Microsoft.UI.Xaml.DispatcherTimer { Interval = TimeSpan.FromSeconds(1) };
        timer.Tick += (_, _) => UpdateTime();
        timer.Start();
        Refresh();

        void Handle(JsonObject m)
        {
            switch ((string?)m["event"])
            {
                case "hello":
                    // Capabilities of the builder. No hello (an older builder) or no Cancel flag: Cancel stays disabled.
                    string cancelPath = InitData.Str(m["CancelRequestPath"]);
                    bool capCancel = m["Capabilities"] is JsonObject caps && InitData.Bool(caps["Cancel"]);
                    _cancelSupported = capCancel && IsValidCancelPath(cancelPath);
                    _cancelRequestPath = _cancelSupported ? cancelPath : "";
                    if (_cancelSupported)
                    {
                        ToolTipService.SetToolTip(cancelBuildButton, _s.Get("Progress.Help.Cancel"));
                        cancelText.Visibility = Visibility.Collapsed;
                    }
                    break;
                case "state":
                    state = InitData.Str(m["State"]);
                    break;
                case "phase":
                    double p = Num(m, "Phase"), t = Num(m, "Total");
                    if (!double.IsNaN(p)) phase = p;
                    if (!double.IsNaN(t)) total = t;
                    if (m["EstimatedSeconds"] != null && !double.IsNaN(Num(m, "EstimatedSeconds"))) estimate = Num(m, "EstimatedSeconds");
                    phaseName = InitData.Str(m["Name"]);
                    break;
                case "log":
                    AddLogLine(InitData.Str(m["Text"]));
                    break;
                case "failure":
                    failed = true;
                    state = "Failed";
                    failedPhase = InitData.Str(m["FailedPhase"]);
                    failKey = InitData.Str(m["MessageKey"]);
                    failSummary = InitData.Str(m["Summary"]);
                    logPath = PathOf(m, "LogPath", logPath);
                    reportPath = PathOf(m, "ReportPath", reportPath);
                    outputPath = PathOf(m, "OutputPath", outputPath);
                    diagPath = PathOf(m, "DiagnosticsPath", diagPath);
                    docsPath = PathOf(m, "DocsPath", docsPath);
                    break;
                case "done":
                    finished = true;
                    doneSuccess = InitData.Bool(m["Success"]);
                    verification = InitData.Str(m["Verification"]);
                    logPath = PathOf(m, "LogPath", logPath);
                    reportPath = PathOf(m, "ReportPath", reportPath);
                    outputPath = PathOf(m, "OutputPath", outputPath);
                    diagPath = PathOf(m, "DiagnosticsPath", diagPath);
                    docsPath = PathOf(m, "DocsPath", docsPath);
                    string st = InitData.Str(m["State"]);
                    // An old builder sends no State or Verification: that is never shown as a verified success
                    if (st.Length == 0) st = doneSuccess ? "NotVerified" : "Failed";
                    if (st == "Succeeded" && verification != "Verified") st = "NotVerified";
                    state = st;
                    cancelledFlag = InitData.Bool(m["Cancelled"]);
                    // A cancel that finished cleanly is not a failure; one whose cleanup failed arrives as Failed
                    if (!doneSuccess && !failed && st != "Cancelled")
                    {
                        failed = true;
                        failKey = InitData.Str(m["MessageKey"]);
                        if (failSummary.Length == 0) failSummary = InitData.Str(m["Summary"]);
                        // "Message" is text, never a path: it used to be assigned to diagPath
                        if (failSummary.Length == 0) failSummary = InitData.Str(m["Message"]);
                    }
                    break;
            }
            if (finished || failed) _buildFinished = true;
            // The result is in: the window must be closable now, not only when the builder process ends
            // (its console can sit on a pause or a slow teardown long after the result was reported).
            if (finished || failed) closeButton.IsEnabled = true;
            Refresh();
        }

        // Events are read asynchronously and the continuation runs on the UI thread; the guard keeps every
        // control update on the dispatcher even if that ever changes, and nothing here waits on the builder.
        try
        {
            await _bridge.ListenProgressAsync(m =>
            {
                // One bad event must not end the listening and leave the window stuck on "running"
                void Safe()
                {
                    try { Handle(m); }
                    catch (Exception ex) { App.LogError(ex); }
                }
                if (DispatcherQueue.HasThreadAccess) Safe();
                else DispatcherQueue.TryEnqueue(Safe);
            });
        }
        catch (Exception ex)
        {
            // The pipe broke: fall through to the cleanup below, which shows the generic failure
            App.LogError(ex);
            AddLogLine(ex.Message);
        }

        // The builder closed the pipe: finished (or ended abnormally). A build that never sent
        // 'done' is a failure, not a success: show the generic failure panel and keep the log reachable.
        timer.Stop();
        _buildFinished = true;
        if (!finished)
        {
            failed = true;
            state = "Failed";
            failedPhase = phaseName;
            failKey = "";
            Refresh();
            bar.IsIndeterminate = false;
            stateText.Text = _s.Get("Progress.Ended") + " " + _s.Get("Progress.Failure.Generic");
            AutomationProperties.SetName(stateText, stateText.Text);
        }
        UpdateButtons();
        closeButton.IsEnabled = true;
    }

    private async void DependenciesButton_Click(object sender, RoutedEventArgs e)
    {
        // Recomputed from the current selection on every click (the host never caches a result)
        var r = await RunAsync("dependencies", new JsonObject { ["Config"] = DraftConfig() });
        if (r == null) return;
        var data = r["Data"]?.AsObject();
        if (data == null || !InitData.Bool(data["HasIssues"]))
        {
            await MessageAsync(_s.Get("Msg.Dependency.Title"), _s.Get("Msg.Dependency.None"));
            return;
        }
        await ShowDependencyDialogAsync(data, acknowledge: false);
    }

    // Dependency dialog shared by the Dependencies button (acknowledge = false: everything, OK only) and the
    // Start confirmation (acknowledge = true: Critical items only; Continue stays disabled until the box is
    // ticked). Every row has a glyph AND a text label, so state never depends on colour alone, and an
    // Unknown row is labelled as not verified. Returns true when the user acknowledged.
    private async Task<bool> ShowDependencyDialogAsync(JsonObject data, bool acknowledge)
    {
        static (string Glyph, string Brush) IconFor(string kind) => kind switch
        {
            "Conflict" => ("\uEA39", "SystemFillColorCriticalBrush"),
            "Unknown" => ("\uE897", "SystemFillColorCautionBrush"),
            _ => ("\uE946", "AccentTextFillColorPrimaryBrush"),
        };
        var panel = new StackPanel { Spacing = 8 };
        void Section(string heading, string kind, JsonNode? rows)
        {
            var items = InitData.Arr(rows).ToList();
            if (items.Count == 0) return;
            var (hg, hb) = IconFor(kind);
            var head = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
            head.Children.Add(new FontIcon { Glyph = hg, Foreground = Res(hb), FontSize = 16 });
            head.Children.Add(new TextBlock { Text = heading, FontWeight = Microsoft.UI.Text.FontWeights.SemiBold, TextWrapping = TextWrapping.Wrap });
            panel.Children.Add(head);
            foreach (var row in items)
            {
                string rk = InitData.Str(row?["Kind"]);
                var (g, b) = IconFor(rk);
                var line = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8, Margin = new Thickness(12, 0, 0, 0) };
                line.Children.Add(new FontIcon { Glyph = g, Foreground = Res(b), FontSize = 14, VerticalAlignment = VerticalAlignment.Top });
                var text = new StackPanel();
                text.Children.Add(new TextBlock { Text = InitData.Str(row?["Label"]), FontWeight = Microsoft.UI.Text.FontWeights.SemiBold, TextWrapping = TextWrapping.Wrap });
                text.Children.Add(new TextBlock { Text = InitData.Str(row?["Text"]), IsTextSelectionEnabled = true, TextWrapping = TextWrapping.Wrap });
                foreach (string af in InitData.StrList(row?["AffectedFeatures"]))
                    text.Children.Add(new TextBlock { Text = "\u2022 " + af, TextWrapping = TextWrapping.Wrap, Margin = new Thickness(12, 0, 0, 0), Opacity = 0.85 });
                line.Children.Add(text);
                panel.Children.Add(line);
            }
        }
        string kept = InitData.Str(data["KeptWarning"]);
        string criticalKind = InitData.Arr(data["Critical"]).Any(x => InitData.Str(x?["Kind"]) == "Conflict") ? "Conflict" : "Unknown";
        if (kept.Length > 0 && InitData.Arr(data["Critical"]).Any())
            panel.Children.Add(new TextBlock { Text = kept, TextWrapping = TextWrapping.Wrap, FontWeight = Microsoft.UI.Text.FontWeights.SemiBold });
        Section(_s.Get("Dep.Section.Critical"), criticalKind, data["Critical"]);
        if (!acknowledge) Section(_s.Get("Dep.Section.Impact"), "Impact", data["Impact"]);
        if (acknowledge) panel.Children.Insert(0, new TextBlock { Text = _s.Get("Dep.Ack.Intro"), TextWrapping = TextWrapping.Wrap });

        var dlg = new ContentDialog
        {
            XamlRoot = Content.XamlRoot,
            Title = _s.Get(acknowledge ? "Dep.Ack.Title" : "Msg.Dependency.Title"),
            PrimaryButtonText = _s.Get(acknowledge ? "Dep.Ack.Continue" : "Button.OK"),
            DefaultButton = acknowledge ? ContentDialogButton.Close : ContentDialogButton.Primary,
        };
        if (acknowledge)
        {
            var ack = new CheckBox { Content = _s.Get("Dep.Ack.Checkbox"), Margin = new Thickness(0, 8, 0, 0) };
            dlg.IsPrimaryButtonEnabled = false;
            ack.Checked += (_, _) => dlg.IsPrimaryButtonEnabled = true;
            ack.Unchecked += (_, _) => dlg.IsPrimaryButtonEnabled = false;
            panel.Children.Add(ack);
            dlg.CloseButtonText = _s.Get("Button.Cancel");
        }
        dlg.Content = new ScrollViewer { Content = panel, MaxHeight = 480, HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled };
        var res = await dlg.ShowAsync();
        return res == ContentDialogResult.Primary;
    }

    // Preset diff: two pickers and the result in one dialog
    private async void PresetDiffButton_Click(object sender, RoutedEventArgs e)
    {
        if (_busy) return;
        var names = new List<(string Id, string Label)> { (CurrentSettingsId, _s.Get("Dlg.PresetDiff.CurrentSettings")) };
        names.AddRange(_init.PresetNames.Select(n => (n, n)));
        ComboBox Picker(int sel, string name)
        {
            var c = new ComboBox { MinWidth = 260 };
            foreach (var n in names) c.Items.Add(n.Label);
            c.SelectedIndex = Math.Min(sel, names.Count - 1);
            AutomationProperties.SetName(c, name);
            return c;
        }
        var from = Picker(0, _s.Get("Dlg.PresetDiff.From").Trim().TrimEnd(':', '：', ' '));
        var to = Picker(1, _s.Get("Dlg.PresetDiff.To").Trim().TrimEnd(':', '：', ' '));
        var output = new TextBlock
        {
            FontFamily = new FontFamily("Cascadia Mono, Consolas"),
            FontSize = 12,
            IsTextSelectionEnabled = true,
            TextWrapping = TextWrapping.NoWrap,
        };
        var content = new StackPanel { Spacing = 8, MinWidth = 560 };
        content.Children.Add(FieldRow(_s.Get("Dlg.PresetDiff.From"), from));
        content.Children.Add(FieldRow(_s.Get("Dlg.PresetDiff.To"), to));
        content.Children.Add(new ScrollViewer
        {
            Content = output,
            MaxHeight = 420,
            HorizontalScrollBarVisibility = ScrollBarVisibility.Auto,
            HorizontalScrollMode = ScrollMode.Auto,
        });
        var dlg = new ContentDialog
        {
            XamlRoot = Content.XamlRoot,
            Title = _s.Get("Dlg.PresetDiff.Title"),
            Content = content,
            PrimaryButtonText = _s.Get("Button.Compare"),
            CloseButtonText = _s.Get("Button.Close"),
            DefaultButton = ContentDialogButton.Primary,
        };
        dlg.Resources["ContentDialogMaxWidth"] = 900.0;
        dlg.PrimaryButtonClick += async (d, a) =>
        {
            a.Cancel = true;
            var deferral = a.GetDeferral();
            try
            {
                var args = new JsonObject
                {
                    ["From"] = names[Math.Max(0, from.SelectedIndex)].Id,
                    ["To"] = names[Math.Max(0, to.SelectedIndex)].Id,
                    ["Config"] = DraftConfig(),
                };
                output.Text = "...";
                var r = await _bridge.RequestAsync("presetDiff", _s.Language, args);
                output.Text = InitData.Str(r["Text"]);
            }
            catch (Exception ex)
            {
                App.LogError(ex);
                output.Text = _s.Format("Msg.Error", ex.Message);
            }
            finally
            {
                deferral.Complete();
            }
        };
        await dlg.ShowAsync();
    }

    // =======================================================================================================
    // Requests, dialogs, pickers
    // =======================================================================================================
    private void SetBusy(bool busy)
    {
        _busy = busy;
        BusyRing.IsActive = busy;
        PageHost.IsHitTestVisible = !busy;
        PageHost.Opacity = busy ? 0.6 : 1.0;
        StartButton.IsEnabled = DependenciesButton.IsEnabled = PresetDiffButton.IsEnabled = CancelButton.IsEnabled = !busy;
        Nav.IsEnabled = !busy;
    }

    private async Task<JsonObject?> RunAsync(string op, JsonObject? args, bool quiet = false)
    {
        if (_busy) return null;
        SetBusy(true);
        try
        {
            return await _bridge.RequestAsync(op, _s.Language, args);
        }
        catch (Exception ex)
        {
            if (!quiet) await MessageAsync(_s.Get("Msg.Title.Default"), _s.Format("Msg.Error", ex.Message), "Error");
            return null;
        }
        finally
        {
            SetBusy(false);
        }
    }

    // Run a request and show its reply text (if any); a Data.Status updates the migration status line
    private async Task RunAndShowAsync(string op, JsonObject? args, bool monospace = false)
    {
        var r = await RunAsync(op, args);
        if (r == null) return;
        string status = InitData.Str(r["Data"]?["Status"]);
        if (status.Length > 0)
        {
            _migStatus = status;
            if (_migStatusText != null) _migStatusText.Text = status;
        }
        string text = InitData.Str(r["Text"]);
        if (text.Length == 0) return;
        string title = InitData.Str(r["Title"], _s.Get("Msg.Title.Default"));
        string kind = InitData.Str(r["Kind"], InitData.Bool(r["ok"]) ? "Info" : "Error");
        await MessageAsync(title, text, kind, monospace);
    }

    private static readonly Dictionary<string, (string Glyph, string Brush)> KindIcons = new()
    {
        ["Info"] = ("\uE946", "AccentTextFillColorPrimaryBrush"),
        ["Warning"] = ("\uE7BA", "SystemFillColorCautionBrush"),
        ["Error"] = ("\uEA39", "SystemFillColorCriticalBrush"),
    };

    private async Task MessageAsync(string title, string text, string kind = "Info", bool monospace = false)
    {
        // OK is the close button, so Escape and Enter both dismiss it
        await ShowDialogAsync(title, text, kind, monospace, null, _s.Get("Button.OK"));
    }

    private async Task<bool> ConfirmAsync(string title, string text)
    {
        return await ShowDialogAsync(title, text, "Warning", false, _s.Get("Button.Yes", "Yes"), _s.Get("Button.No", "No")) == ContentDialogResult.Primary;
    }

    private async Task<ContentDialogResult> ShowDialogAsync(string title, string text, string kind, bool monospace, string? primary, string? close)
    {
        var (glyph, brush) = KindIcons.TryGetValue(kind, out var k) ? k : KindIcons["Info"];
        var header = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 10 };
        var kindIcon = new FontIcon { Glyph = glyph, Foreground = Res(brush), FontSize = 20 };
        // The severity word is read out for screen readers; the icon alone would only show it by shape and colour
        AutomationProperties.SetName(kindIcon, _s.Get("Severity." + (KindIcons.ContainsKey(kind) ? kind : "Info")));
        header.Children.Add(kindIcon);
        header.Children.Add(new TextBlock { Text = title, VerticalAlignment = VerticalAlignment.Center, TextWrapping = TextWrapping.Wrap });
        var body = new TextBlock { Text = text.Replace("\r\n", "\n"), IsTextSelectionEnabled = true, TextWrapping = monospace ? TextWrapping.NoWrap : TextWrapping.Wrap };
        if (monospace)
        {
            body.FontFamily = new FontFamily("Cascadia Mono, Consolas");
            body.FontSize = 12;
        }
        var dlg = new ContentDialog
        {
            XamlRoot = Content.XamlRoot,
            Title = header,
            Content = new ScrollViewer { Content = body, MaxHeight = 480, HorizontalScrollBarVisibility = monospace ? ScrollBarVisibility.Auto : ScrollBarVisibility.Disabled, HorizontalScrollMode = monospace ? ScrollMode.Auto : ScrollMode.Disabled },
            DefaultButton = close == null ? ContentDialogButton.Primary : ContentDialogButton.Close,
        };
        if (primary != null) dlg.PrimaryButtonText = primary;
        if (close != null) dlg.CloseButtonText = close;
        if (monospace) dlg.Resources["ContentDialogMaxWidth"] = 900.0;
        return await dlg.ShowAsync();
    }

    // Microsoft.Windows.Storage.Pickers work in an elevated process (the builder runs as administrator)
    private async Task<string?> PickFolderAsync()
    {
        try
        {
            var picker = new FolderPicker(AppWindow.Id);
            var r = await picker.PickSingleFolderAsync();
            return r?.Path;
        }
        catch (Exception ex)
        {
            await MessageAsync(_s.Get("Msg.Title.Default"), _s.Format("Msg.Error", ex.Message), "Error");
            return null;
        }
    }

    private async Task<string?> PickFileAsync(string extension)
    {
        try
        {
            var picker = new FileOpenPicker(AppWindow.Id);
            picker.FileTypeFilter.Add(extension);
            var r = await picker.PickSingleFileAsync();
            return r?.Path;
        }
        catch (Exception ex)
        {
            await MessageAsync(_s.Get("Msg.Title.Default"), _s.Format("Msg.Error", ex.Message), "Error");
            return null;
        }
    }

    private async Task<List<string>> PickFilesAsync(IEnumerable<string> extensions)
    {
        var picked = new List<string>();
        try
        {
            var picker = new FileOpenPicker(AppWindow.Id);
            foreach (string e in extensions) picker.FileTypeFilter.Add(e);
            var files = await picker.PickMultipleFilesAsync();
            foreach (var f in files) picked.Add(f.Path);
        }
        catch (Exception ex)
        {
            await MessageAsync(_s.Get("Msg.Title.Default"), _s.Format("Msg.Error", ex.Message), "Error");
        }
        return picked;
    }

    private async Task<string?> PickSaveFileAsync(string suggestedName, string typeName, string extension)
    {
        try
        {
            var picker = new FileSavePicker(AppWindow.Id) { SuggestedFileName = suggestedName };
            picker.FileTypeChoices.Add(typeName, new List<string> { extension });
            var r = await picker.PickSaveFileAsync();
            return r?.Path;
        }
        catch (Exception ex)
        {
            await MessageAsync(_s.Get("Msg.Title.Default"), _s.Format("Msg.Error", ex.Message), "Error");
            return null;
        }
    }
}
