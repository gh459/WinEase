## 2025-02-23 - Screen Reader Accessibility in WinUI 3 Custom Setting Cards
**Learning:** In WinUI 3 XAML interfaces, wrapping interactive controls (`ToggleSwitch`, `TextBox`, `ComboBox`) inside custom card containers (`Border`/`Grid`) without setting `AutomationProperties.Name` on the child controls leaves screen readers unable to announce what setting or field is currently focused during keyboard navigation.
**Action:** Always set `AutomationProperties.SetName` (and `AutomationProperties.SetHelpText` when descriptions exist) directly on the interactive control within setting card and field row factories.

## 2025-05-18 - Keyboard Focus for Tooltips and Help Marks in WinUI 3
**Learning:** Placing `ToolTipService.ToolTip` or `AutomationProperties.Name` on static `TextBlock` elements (such as "?" help indicators) renders them inaccessible to keyboard-only users because `TextBlock` controls do not receive Tab focus.
**Action:** Use a compact, focusable `Button` control for inline help indicators so keyboard users can Tab to the help mark, trigger the tooltip on focus, and activate the button to view detailed help dialogs.
