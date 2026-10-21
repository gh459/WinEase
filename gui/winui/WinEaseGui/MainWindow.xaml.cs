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
    private static readonly string[] PresetLabelKeys =
    {
        "Media.Preset.Extreme", "Media.Preset.Balanced", "Media.Preset.Fat32", "Media.Preset.Handheld",
        "Media.Preset.VM", "Media.Preset.Audio", "Media.Preset.Custom",
    };
    private static readonly string[] MigrationFolders = { "Documents", "Desktop", "Pictures", "Videos", "Downloads" };
    private static readonly string[] ConflictPolicies = { "BackupExisting", "Skip", "OverwriteIfNewer", "Overwrite" };
    private const string CurrentSettingsId = "__current__";

    private readonly InitData _init;
    private readonly Bridge _bridge;
    private readonly UiStrings _s;

    // --- state -------------------------------------------------------------------------------------------
    private string _source = "", _workDir = "", _index = "", _drivers = "", _userName = "User", _computerName = "*";
    private int _presetIndex;
    private string? _basePresetKey;
    private string _payload = "WIM";
    private bool _useVhdx;
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
        AppWindow.Closing += AppWindow_Closing;

        ApplyLanguage();
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
        if (idx < 0) idx = presetKey.Length > 0 ? PresetLabelKeys.Length - 1 : 1;
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
        StatusText.Text = _bridge.IsConnected ? "" : "Standalone preview (not connected to WinEasebuilder.ps1)";

        AutomationProperties.SetName(DryRunCheck, _s.Get("Main.DryRun"));
        AutomationProperties.SetName(LanguageCombo, LanguageLabel.Text);
        AutomationProperties.SetName(PresetDiffButton, _s.Get("Button.PresetDiff"));
        AutomationProperties.SetName(DependenciesButton, _s.Get("Button.CheckDependencies"));
        AutomationProperties.SetName(StartButton, _s.Get("Button.StartBuild"));
        AutomationProperties.SetName(CancelButton, _s.Get("Button.Cancel"));
        ToolTipService.SetToolTip(PresetDiffButton, _s.Get("Button.PresetDiff"));
        ToolTipService.SetToolTip(DependenciesButton, _s.Get("Button.CheckDependencies"));

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
            ("user", _s.Get("Tab.UserTweaks"), "\uE77B"),
        };
        Nav.MenuItems.Clear();
        NavigationViewItem? selected = null;
        foreach (var (tag, text, glyph) in items)
        {
            var item = new NavigationViewItem { Content = CleanTabText(text), Tag = tag, Icon = new FontIcon { Glyph = glyph } };
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
    private static Brush Res(string key) => (Brush)Application.Current.Resources[key];

    private static TextBlock Section(string text) => new()
    {
        Text = text.Trim(),
        Style = (Style)Application.Current.Resources["BodyStrongTextBlockStyle"],
        Margin = new Thickness(1, 18, 0, 4),
    };

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
        var lbl = new TextBlock { Text = cleanLabel, VerticalAlignment = VerticalAlignment.Center, TextWrapping = TextWrapping.Wrap };
        g.Children.Add(lbl);
        Grid.SetColumn(field, 1);
        g.Children.Add(field);
        AutomationProperties.SetName(field, cleanLabel);
        int col = 2;
        foreach (var b in buttons)
        {
            g.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            Grid.SetColumn(b, col++);
            g.Children.Add(b);
        }
        return g;
    }

    private static Button Btn(string text, RoutedEventHandler click, bool accent = false)
    {
        var b = new Button { Content = text.Trim() };
        if (accent) b.Style = (Style)Application.Current.Resources["AccentButtonStyle"];
        b.Click += click;
        return b;
    }

    private static TextBox Box(string text, Action<string> changed, string? placeholder = null)
    {
        var t = new TextBox { Text = text, PlaceholderText = placeholder ?? "" };
        t.TextChanged += (_, _) => changed(t.Text);
        return t;
    }

    private static ToggleSwitch Toggle(bool on, Action<bool> changed)
    {
        var t = new ToggleSwitch { IsOn = on, MinWidth = 0, OnContent = "", OffContent = "" };
        t.Toggled += (_, _) => changed(t.IsOn);
        return t;
    }

    private StackPanel SelectButtons(Action<bool> setAll)
    {
        var p = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8, Margin = new Thickness(0, 0, 0, 4) };
        p.Children.Add(Btn(_s.Get("Button.SelectAll"), (_, _) => setAll(true)));
        p.Children.Add(Btn(_s.Get("Button.ClearAll"), (_, _) => setAll(false)));
        return p;
    }

    // =======================================================================================================
    // Page 1: media, workspace, account, preset and payload format
    // =======================================================================================================
    private void BuildMediaPage()
    {
        PageTitle.Text = CleanTabText(_s.Get("Tab.Media"));
        SetSubtitle(_s.Get("Main.Subtitle"));

        // Source media
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
        srcPanel.Children.Add(FieldRow(_s.Get("Media.Label.Source"), source, browseDrive, browseIso, rescan));

        var work = Box(_workDir, v => _workDir = v, _init.DefaultWorkDir);
        srcPanel.Children.Add(FieldRow(_s.Get("Media.Label.Workspace"), work, Btn(_s.Get("Button.BrowseFolder"), async (_, _) =>
        {
            string? p = await PickFolderAsync();
            if (p != null) work.Text = p;
        })));

        var index = Box(_index, v => _index = v);
        index.HorizontalAlignment = HorizontalAlignment.Left;
        index.Width = 120;
        srcPanel.Children.Add(FieldRow(_s.Get("Media.Label.Index"), index));

        var drivers = Box(_drivers, v => _drivers = v);
        srcPanel.Children.Add(FieldRow(_s.Get("Media.Label.Drivers"), drivers, Btn(_s.Get("Button.Browse"), async (_, _) =>
        {
            string? p = await PickFolderAsync();
            if (p != null) drivers.Text = p;
        })));

        var user = Box(_userName, v => _userName = v);
        user.MaxLength = 20;
        srcPanel.Children.Add(FieldRow(_s.Get("Media.Label.UserName"), user));
        var computer = Box(_computerName, v => _computerName = v);
        computer.MaxLength = 15;
        srcPanel.Children.Add(FieldRow(_s.Get("Media.Label.ComputerName"), computer));
        PageHost.Children.Add(Card(srcPanel));

        // Preset
        PageHost.Children.Add(Section(_s.Get("Media.Group.Preset")));
        var preset = new ComboBox { HorizontalAlignment = HorizontalAlignment.Stretch };
        foreach (string k in PresetLabelKeys) preset.Items.Add(_s.Get(k));
        preset.SelectedIndex = _presetIndex;
        preset.SelectionChanged += (_, _) =>
        {
            if (preset.SelectedIndex < 0 || preset.SelectedIndex == _presetIndex) return;
            _presetIndex = preset.SelectedIndex;
            if (_presetIndex < _init.Presets.Count) ApplyPreset(_init.Presets[_presetIndex]);
        };
        PageHost.Children.Add(Card(preset));

        // Payload format
        PageHost.Children.Add(Section(_s.Get("Media.Group.Payload")));
        var payload = new StackPanel { Spacing = 4 };
        var radios = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 24 };
        foreach (var (fmt, key) in new[] { ("WIM", "Media.Radio.WIM"), ("ESD", "Media.Radio.ESD"), ("SWM", "Media.Radio.SWM") })
        {
            var rb = new RadioButton { Content = _s.Get(key), GroupName = "payload", Tag = fmt, IsChecked = _payload == fmt };
            rb.Checked += (s, _) => { _payload = (string)((RadioButton)s).Tag; UpdateEstimate(); };
            radios.Children.Add(rb);
            _payloadRadios.Add(rb);
        }
        payload.Children.Add(radios);
        var vhdx = new CheckBox { Content = _s.Get("Media.Check.VHDX"), IsChecked = _useVhdx };
        vhdx.Checked += (_, _) => _useVhdx = true;
        vhdx.Unchecked += (_, _) => _useVhdx = false;
        payload.Children.Add(vhdx);
        PageHost.Children.Add(Card(payload));
    }

    // Built-in preset -> every switch (Set-WinEaseGuiPreset)
    private void ApplyPreset(PresetDef p)
    {
        foreach (var kv in p.Components) if (_components.ContainsKey(kv.Key)) _components[kv.Key] = kv.Value;
        foreach (var t in _init.Tweaks) _tweaks[t.Key] = p.Tweaks.TryGetValue(t.Key, out bool v) ? v : t.Default;
        _payload = p.PayloadFormat is "ESD" or "SWM" ? p.PayloadFormat : "WIM";
        foreach (var rb in _payloadRadios) rb.IsChecked = (string)rb.Tag == _payload;
        _basePresetKey = p.Key;
        UpdateEstimate();
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
            var toggle = Toggle(_tweaks.GetValueOrDefault(key, t.Default), v => _tweaks[key] = v);
            toggles.Add((key, toggle));
            string header = showCategory ? $"{key}  [{t.Category}]" : key;
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
            var toggle = Toggle(_components.GetValueOrDefault(key, c.Default), v => { _components[key] = v; UpdateEstimate(); });
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
        // so the mark explains it in a tooltip.
        var engineHelp = new TextBlock
        {
            Text = "?",
            VerticalAlignment = VerticalAlignment.Center,
            FontSize = 15,
        };
        ToolTipService.SetToolTip(engineHelp, _s.Get("Debloat.Engine.Help"));
        allRow.Children.Add(engineHelp);
        allRow.Children.Add(new TextBlock { Text = _s.Get("Debloat.Engine.All"), VerticalAlignment = VerticalAlignment.Center });
        var allCombo = new ComboBox { MinWidth = 140, SelectedIndex = 0 };
        ToolTipService.SetToolTip(allCombo, _s.Get("Debloat.Engine.Help"));
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
        if (danger) header.Foreground = Res("SystemFillColorCriticalBrush");
        PageHost.Children.Add(header);
        var boxes = new List<CheckBox>();
        var bar = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8, Margin = new Thickness(0, 0, 0, 4) };
        bar.Children.Add(Btn(_s.Get("Button.SelectAll"), async (_, _) =>
        {
            if (confirmSelectAll != null && !await ConfirmAsync(_s.Get("Msg.Title.Confirm"), confirmSelectAll)) return;
            foreach (var b in boxes) b.IsChecked = true;
        }));
        bar.Children.Add(Btn(_s.Get("Button.ClearAll"), (_, _) => { foreach (var b in boxes) b.IsChecked = false; }));
        PageHost.Children.Add(bar);

        var panel = new StackPanel { Spacing = 0 };
        foreach (string item in items.Distinct())
        {
            string value = item;
            var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8, Margin = new Thickness(0, 0, 0, 2) };
            var cb = new CheckBox { Content = _s.Get("Debloat:" + item, item), IsChecked = selected.Contains(item), MinWidth = 380 };
            cb.Checked += (_, _) => { selected.Add(value); UpdateDebloatEngineState(value); };
            cb.Unchecked += (_, _) => { selected.Remove(value); UpdateDebloatEngineState(value); };
            boxes.Add(cb);
            row.Children.Add(cb);

            var combo = new ComboBox { MinWidth = 120, HorizontalAlignment = HorizontalAlignment.Left };
            foreach (string eng in DebloatEnginesFor(value)) combo.Items.Add(eng);
            combo.SelectedIndex = 0;
            combo.SelectionChanged += (_, _) => { if (combo.SelectedIndex >= 0) SetDebloatEngine(value, (string)combo.SelectedItem, combo); };
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
        _debloatEngines[item] = engine;
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

        // Post-install migration assistant switch
        var assist = _init.Components.FirstOrDefault(c => c.Key == "IncludeMigrationAssistant");
        if (assist != null)
        {
            PageHost.Children.Add(Section(_s.Get("Mig.Group.Assistant")));
            var toggle = Toggle(_components.GetValueOrDefault(assist.Key, assist.Default), v => _components[assist.Key] = v);
            PageHost.Children.Add(SettingCard(ComponentText(assist), ComponentDescription(assist), toggle, "\uE8F1"));
        }

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
        secrets.Checked += (_, _) => _migExcludeSecrets = true;
        secrets.Unchecked += (_, _) => _migExcludeSecrets = false;
        backup.Children.Add(secrets);
        var conflict = new ComboBox { MinWidth = 220 };
        foreach (string p in ConflictPolicies) conflict.Items.Add(p);
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
        backup.Children.Add(_migStatusText);
        PageHost.Children.Add(Card(backup));

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
        Action("Mig.Button.Restore", () => RunAndShowAsync("restore", MigrationArgs()));
        Action("Mig.Button.Retry", () =>
        {
            var a = MigrationArgs();
            a["RetryFailedOnly"] = true;
            return RunAndShowAsync("restore", a);
        });
        right.Children.Add(Card(actions));

        columns.Children.Add(left);
        Grid.SetColumn(right, 1);
        columns.Children.Add(right);
        PageHost.Children.Add(columns);

        // Custom files and folders
        PageHost.Children.Add(Section(_s.Get("Mig.Group.Custom")));
        var custom = new StackPanel { Spacing = 6 };
        custom.Children.Add(new TextBlock { Text = _s.Get("Mig.Label.CustomPaths").Trim() });
        var paths = new TextBox { Text = _migCustomPaths, AcceptsReturn = true, TextWrapping = TextWrapping.NoWrap, MinHeight = 90, FontFamily = new FontFamily("Cascadia Mono, Consolas") };
        paths.TextChanged += (_, _) => _migCustomPaths = paths.Text;
        custom.Children.Add(paths);
        var customButtons = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        customButtons.Children.Add(Btn(_s.Get("Mig.Button.BackupCustom"), async (_, _) =>
        {
            var a = MigrationArgs();
            var arr = new JsonArray();
            foreach (string line in _migCustomPaths.Split('\n').Select(l => l.Trim()).Where(l => l.Length > 0)) arr.Add(line);
            a["Paths"] = arr;
            await RunAndShowAsync("backupCustom", a);
        }));
        customButtons.Children.Add(Btn(_s.Get("Mig.Button.RestoreCustom"), async (_, _) => await RunAndShowAsync("restoreCustom", MigrationArgs())));
        custom.Children.Add(customButtons);
        PageHost.Children.Add(Card(custom));

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
            Text = errors.Count > 0 ? _s.Format("Mig.Ext.LoadErrors", string.Join("; ", errors)) : _s.Get("Mig.Ext.NoErrors"),
            TextWrapping = TextWrapping.Wrap,
            Foreground = errors.Count > 0 ? Res("SystemFillColorCautionBrush") : Res("TextFillColorSecondaryBrush"),
        });
        var guide = Btn(_s.Get("Mig.Button.Guide"), async (_, _) => await RunAndShowAsync("guide", null));
        guide.Margin = new Thickness(0, 6, 0, 0);
        extPanel.Children.Add(guide);
        PageHost.Children.Add(Card(extPanel));
    }

    // Rules are read from tools\migrator the first time the page is opened
    private async void FillMigrationRules(StackPanel host)
    {
        if (_migRules == null)
        {
            host.Children.Add(new ProgressRing { IsActive = true, Width = 20, Height = 20, HorizontalAlignment = HorizontalAlignment.Left });
            var r = await _bridge.RequestAsync("migrationRules", _s.Language);
            var list = new List<(string, string)>();
            foreach (var n in InitData.Arr(r["Data"]))
            {
                string id = InitData.Str(n?["Id"]);
                if (id.Length > 0) list.Add((id, InitData.Str(n?["Name"])));
            }
            _migRules = list;
            host.Children.Clear();
        }
        if (_migRules.Count == 0)
        {
            host.Children.Add(new TextBlock { Text = _s.Get("Mig.NoRules"), Foreground = Res("TextFillColorSecondaryBrush"), TextWrapping = TextWrapping.Wrap });
            return;
        }
        foreach (var (id, name) in _migRules)
        {
            string ruleId = id;
            var cb = new CheckBox { Content = $"{id} - {name}", IsChecked = _migRuleIds.Contains(id) };
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
            ["PresetKey"] = _presetIndex < _init.Presets.Count ? _init.Presets[_presetIndex].Key : null,
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
        if (_busy) return;
        // Same checks as Complete-WinEaseGuiResult
        if (_source.Trim().Length == 0)
        {
            await MessageAsync(_s.Get("Msg.SourceRequired.Title"), _s.Get("Msg.SourceRequired.Text"), "Warning");
            return;
        }
        if (!Regex.IsMatch(_userName.Trim(), @"^[\p{L}\p{N}_][\p{L}\p{N} ._-]{0,19}$"))
        {
            await MessageAsync(_s.Get("Msg.InvalidUserName.Title"), _s.Get("Msg.InvalidUserName.Text"), "Warning");
            return;
        }
        string computer = _computerName.Trim().Length == 0 ? "*" : _computerName.Trim();
        if (!Regex.IsMatch(computer, @"^(\*|[A-Za-z0-9][A-Za-z0-9-]{0,14})$"))
        {
            await MessageAsync(_s.Get("Msg.InvalidComputerName.Title"), _s.Get("Msg.InvalidComputerName.Text"), "Warning");
            return;
        }

        // Dependency / feature-impact pre-check
        var dep = await RunAsync("dependencies", new JsonObject { ["Config"] = DraftConfig() }, quiet: true);
        if (dep != null && InitData.Bool(dep["ok"]) && InitData.Bool(dep["Data"]?["HasIssues"]))
        {
            if (!await ConfirmAsync(_s.Get("Msg.Dependency.Title"), _s.Format("Msg.Dependency.Confirm", InitData.Str(dep["Text"])))) return;
        }

        // Physical debloat consent (the builder's -AllowPhysicalDebloat gate)
        bool consent = false;
        int std = _debloatStd.Count, exp = _debloatExp.Count;
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

        await SendResultAndCloseAsync(ResultObject(consent));
    }

    private async void CancelButton_Click(object sender, RoutedEventArgs e)
    {
        if (_busy) return;
        await SendResultAndCloseAsync(new JsonObject { ["Success"] = false });
    }

    private async void AppWindow_Closing(AppWindow sender, AppWindowClosingEventArgs args)
    {
        if (_resultSent) return;
        args.Cancel = true;
        if (_busy) return;
        await SendResultAndCloseAsync(new JsonObject { ["Success"] = false });
    }

    private async Task SendResultAndCloseAsync(JsonObject result)
    {
        if (_resultSent) return;
        _resultSent = true;
        await _bridge.SendResultAsync(_s.Language, result);
        Close();
    }

    private async void DependenciesButton_Click(object sender, RoutedEventArgs e)
    {
        await RunAndShowAsync("dependencies", new JsonObject { ["Config"] = DraftConfig() }, monospace: true);
    }

    // Preset diff: two pickers and the result in one dialog
    private async void PresetDiffButton_Click(object sender, RoutedEventArgs e)
    {
        if (_busy) return;
        var names = new List<(string Id, string Label)> { (CurrentSettingsId, _s.Get("Dlg.PresetDiff.CurrentSettings")) };
        names.AddRange(_init.PresetNames.Select(n => (n, n)));
        ComboBox Picker(int sel)
        {
            var c = new ComboBox { MinWidth = 260 };
            foreach (var n in names) c.Items.Add(n.Label);
            c.SelectedIndex = Math.Min(sel, names.Count - 1);
            return c;
        }
        var from = Picker(0);
        var to = Picker(1);
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
        await ShowDialogAsync(title, text, kind, monospace, _s.Get("Button.OK"), null);
    }

    private async Task<bool> ConfirmAsync(string title, string text)
    {
        return await ShowDialogAsync(title, text, "Warning", false, _s.Get("Button.Yes", "Yes"), _s.Get("Button.No", "No")) == ContentDialogResult.Primary;
    }

    private async Task<ContentDialogResult> ShowDialogAsync(string title, string text, string kind, bool monospace, string primary, string? close)
    {
        var (glyph, brush) = KindIcons.TryGetValue(kind, out var k) ? k : KindIcons["Info"];
        var header = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 10 };
        header.Children.Add(new FontIcon { Glyph = glyph, Foreground = Res(brush), FontSize = 20 });
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
            PrimaryButtonText = primary,
            DefaultButton = close == null ? ContentDialogButton.Primary : ContentDialogButton.Close,
        };
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
