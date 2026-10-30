# Palette's Journal

WinUI 3 accessibility and UI notes from the Palette agent. Newest entry first; format in `README.md`.

## 2025-05-19 - Accessibility for dynamic action buttons and standalone ProgressRing controls in WinUI 3

**Learning:** Dynamically generated `Button` lists and standalone `ProgressRing` loading indicators in WinUI 3 lack screen reader announcements if `AutomationProperties.SetName` is not explicitly set on instantiation.
**Action:** Always set `AutomationProperties.SetName` (and `ToolTipService.SetToolTip`) when instantiating dynamic buttons and loading indicators, mapping them to localized string keys.

## 2025-05-18 - Keyboard focus for tooltips and help marks in WinUI 3

**Learning:** Placing `ToolTipService.ToolTip` or `AutomationProperties.Name` on static `TextBlock` elements (such as "?" help indicators) renders them inaccessible to keyboard-only users because `TextBlock` controls do not receive Tab focus.
**Action:** Use a compact, focusable `Button` control for inline help indicators so keyboard users can Tab to the help mark, trigger the tooltip on focus, and activate the button to view detailed help dialogs.

## 2025-02-23 - Screen reader accessibility in WinUI 3 custom setting cards

**Learning:** In WinUI 3 XAML interfaces, wrapping interactive controls (`ToggleSwitch`, `TextBox`, `ComboBox`) inside custom card containers (`Border`/`Grid`) without setting `AutomationProperties.Name` on the child controls leaves screen readers unable to announce what setting or field is currently focused during keyboard navigation.
**Action:** Always set `AutomationProperties.SetName` (and `AutomationProperties.SetHelpText` when descriptions exist) directly on the interactive control within setting card and field row factories.
