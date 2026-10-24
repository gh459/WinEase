# GUI manual checklist

`tests/GuiParity.Tests.ps1` proves that the WinUI 3 window, the WinForms window and the command
line agree on settings, labels, validation and safety gates. It cannot render a window. The
points below need a person at a real display and have to be checked before a release that
changes `gui/winui` or `gui/WinEaseGui.ps1`. Run both windows (`-ClassicGui` for WinForms) and
note the Windows build, the display scale and the result.

## Display scale and screen size

- [ ] 100%, 125%, 150% and 200% display scale: no clipped text, no overlapping controls, every
      button fully visible, tab pages scroll instead of cutting content off.
- [ ] Change the scale while the window is open (sign out is not needed): the window stays usable.
- [ ] Small screen (1366x768, and 1280x720 at 125%): the Start / Cancel bar stays reachable, the
      window does not open larger than the work area, the WinForms window shrinks to fit.
- [ ] Second monitor with a different scale: move the window across; text stays sharp, layout holds.
- [ ] Minimum and maximum window size (WinUI 3): the navigation pane collapses, content reflows.

## Keyboard and focus

- [ ] Tab order follows the visual order on every page: navigation, page controls, Dry Run, Estimate,
      Preset Diff, Dependencies, Start, Cancel.
- [ ] Every button, toggle, check box and combo box can be operated with Space / Enter / arrow keys.
- [ ] A visible focus rectangle is shown on every focusable control, in light and dark theme.
- [ ] Escape and Alt+F4 behave like Cancel (see below); Enter on a text box does not start a build.
- [ ] Keyboard-only run: choose source, a preset, one tweak, Dry Run, Start.

## Screen reader (Narrator)

- [ ] Every control is announced with a meaningful name (not the type or the key alone):
      toggles, debloat check boxes, engine combo boxes, language combo box, navigation items.
- [ ] Toggle state (on / off) and the selected engine are announced when they change.
- [ ] Error and confirmation dialogs (invalid name, dependency warning, physical debloat consent)
      are announced and receive focus; the default button of the consent dialog is the safe one.
- [ ] The progress view announces step changes and the final result.

## Contrast and theme

- [ ] Light, dark and high-contrast themes: text, disabled controls, warnings (experimental debloat
      notice) and the accent Start button keep a readable contrast (4.5:1 for body text).
- [ ] Information is not carried by color alone (selected / disabled / warning states have text or icon).
- [ ] Switching the Windows theme while the window is open updates the window.

## English / Japanese layout

- [ ] Switch en -> ja -> en on every page: no truncated labels, no text overlapping a neighbour,
      long Japanese tweak descriptions wrap or show a tooltip.
- [ ] Japanese font (Yu Gothic UI / Meiryo UI) is used and glyphs are not missing.
- [ ] Debloat targets show translated names; the saved profile still holds the English names.
- [ ] Values typed before the switch (source, work folder, names, selections, Dry Run) are still there.
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
