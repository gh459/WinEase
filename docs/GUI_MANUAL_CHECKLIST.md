# GUI manual checklist

`tests/GuiParity.Tests.ps1` proves that the WinUI 3 window, the WinForms window and the command
line agree on settings, labels, validation and safety gates. It cannot render a window. The
points below need a person at a real display and have to be checked before a release that
changes `gui/winui` or `gui/WinEaseGui.ps1`. Run both windows (`-ClassicGui` for WinForms) and
note the Windows build, the display scale and the result.

## What E1 now covers in code, and what is still manual

Legend: `[x]` = the structure is checked by `tests/GuiParity.Tests.ps1` (context "e.") and cannot regress
silently, but only a person sees the result on screen, so the line stays here as a release check where
it says "look". `[ ]` = manual only. The E1 change itself was looked at in the WinUI 3 window at 100%
display scale only (640x560 minimum size and 1200x880, English and Japanese); 125-200% scale, Narrator,
high contrast and the WinForms window were NOT looked at on a screen.

## Display scale and screen size

- [ ] 100%, 125%, 150% and 200% display scale: no clipped text, no overlapping controls, every
      button fully visible, tab pages scroll instead of cutting content off.
      (Code: WinUI rows and the command bar wrap, the WinForms form uses AutoScaleMode Dpi and scrolling pages.)
- [ ] Change the scale while the window is open (sign out is not needed): the window stays usable.
- [ ] Small screen (1366x768, and 1280x720 at 125%): the Start / Cancel bar stays reachable, the
      window does not open larger than the work area, the WinForms window shrinks to fit.
      (Code: WinUI start size and minimum size are clamped to the work area; WinForms Load handler does the same.)
- [ ] Second monitor with a different scale: move the window across; text stays sharp, layout holds.
- [x] Minimum window size (WinUI 3): 640x560 device-independent pixels, scaled by the monitor DPI,
      clamped to the work area (WM_GETMINMAXINFO; checked by test, seen at 100%). WinForms: MinimumSize 700x560.
- [x] The navigation pane collapses on narrow windows (PaneDisplayMode Auto; seen at 640 px).
- [x] The command bar wraps below the status text on narrow windows; Preset Diff / Dependencies / Start /
      Cancel stay fully visible (structure checked; seen at 640 px, English and Japanese).
- [ ] Look: maximised window, and a very long path in each path box (tooltip shows the full text).

## Keyboard and focus

- [ ] Tab order follows the visual order on every page: navigation, page controls, Dry Run, Estimate,
      Preset Diff, Dependencies, Start, Cancel. (Code: TabIndex of the command bar is checked, pages follow the visual tree.)
- [ ] Every button, toggle, check box and combo box can be operated with Space / Enter / arrow keys.
- [ ] A visible focus rectangle is shown on every focusable control, in light and dark theme.
- [x] Enter starts the Start flow only when the last input check found no error (the flow validates again and
      asks for the final confirmation, a build never starts silently); Escape = Cancel in both windows
      (WinForms AcceptButton / CancelButton; WinUI key handler, Escape seen to close the WinUI window).
      Enter inside a multi-line box, a button, a combo box or an open popup / dialog keeps its own meaning.
- [x] Access keys (Alt+P / D / S / C) exist on the WinUI command bar buttons (declared; press Alt to look).
- [ ] Keyboard-only run: choose source, a preset, one tweak, Dry Run, Start.

## Screen reader (Narrator)

- [x] Every named control has an accessible name and help text: WinUI command bar and the controls
      created in code (buttons, toggles, inputs, dialog icons carry a severity word); WinForms
      AccessibleName / AccessibleDescription on every input, button and check box (checked by test).
- [ ] Look / listen: toggles, debloat check boxes, engine combo boxes, language combo box and navigation
      items are announced with a meaningful name and state.
- [ ] Toggle state (on / off) and the selected engine are announced when they change.
- [x] Estimate, status and preset-state texts are live regions (WinUI; checked by test). [ ] Listen to them.
- [ ] Error and confirmation dialogs (invalid name, dependency warning, physical debloat consent)
      are announced and receive focus; the default button of the consent dialog is the safe one.
- [ ] The progress view announces step changes and the final result.

## Contrast and theme

- [ ] Light, dark and high-contrast themes: text, disabled controls, warnings (experimental debloat
      notice) and the accent Start button keep a readable contrast (4.5:1 for body text).
      (Code: no hard-coded colour; brushes made in code are looked up in the theme dictionary of the current theme.)
- [x] Information is not carried by color alone: field issues, extension load errors, the experimental debloat
      heading, legacy custom scripts and dialog kinds show an icon and a word as well (WinUI; checked by test).
      WinForms warning colours are still colour plus text only where the text itself says warning / error: look.
- [ ] Switching the Windows theme while the window is open updates the window (the WinUI page is rebuilt on theme change).

## English / Japanese layout

- [x] No user-facing text of MainWindow.xaml(.cs) is a hard-coded literal, and every ui-strings key used by the
      code exists in en.json and ja.json (test scans the source; progress view texts are part of the scan).
- [ ] Switch en -> ja -> en on every page: no truncated labels, no text overlapping a neighbour,
      long Japanese tweak descriptions wrap or show a tooltip. (Code: text wraps; seen on the media page only.)
- [ ] Japanese font (Yu Gothic UI / Meiryo UI) is used and glyphs are not missing.
- [ ] Debloat targets show translated names; the saved profile still holds the English names.
- [x] Values typed before the switch (source, work folder, names, selections, Dry Run) are still there
      (WinForms: rebuilt from the saved state, tested; WinUI: the init data and the stored fields do not depend on
      the language, and the stage / on-error / conflict choices travel as identifiers, tested).
- [ ] The language chosen is remembered for the next start; `-UiLanguage` overrides it.

## Cancel, close and busy behavior

- [ ] Cancel, the window close button, Alt+F4 and Escape return no settings and start nothing.
- [ ] Closing while a background request is running (dependency check, preset diff, migration) does
      not hang or crash and does not start a build.
- [ ] Start with Dry Run closes the window and the builder exits without touching images.
- [ ] Start without Dry Run keeps the WinUI 3 window open as the progress view; Close is enabled only
      when the build has ended.
- [ ] Declining the physical debloat consent clears the Advanced Debloat selection (re-open the
      window and confirm nothing is pre-selected from the declined run).
- [ ] Killing the builder process closes the WinUI 3 window; closing the window does not leave
      `WinEaseGui.exe` running.

## Controls that automation only checks structurally

These have a handler (checked by the test) but their effect on screen needs an eye:

- [ ] Select All / Clear All on every tab, global engine switch of the debloat page.
- [ ] Browse buttons (drive, ISO, folder) open the right dialog and fill the right box.
- [ ] Preset combo box applies the preset to all tabs and changes to Custom after a manual change.
- [ ] Preset Diff, Dependencies, migration actions, custom script and user tweak pages.
