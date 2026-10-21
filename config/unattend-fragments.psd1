# Optional parameters and attributes of autounattend.xml.
#
# autounattend.xml (repository root) is the base template with what every build needs. Each fragment
# below is added to it by lib\WinEaseUnattendComposer.ps1 when it is enabled; nothing is removed from the
# template afterwards. The result is written to the ISO root and into the mounted image (Sysprep, Panther).
#
# Fields:
#   Id           unique name (letters and digits)
#   Toggle       existing tweak or component key that switches the fragment (BypassNRO, ConfigureWinlogon,
#                SetJapaneseKeyboard, ...). Without Toggle the fragment gets its own toggle 'Unattend.<Id>'
#                on the GUI "Answer file" tab, with Default / Description / Category.
#   When         optional extra conditions: @{ AllOf = @(<keys that must be on>); AnyOf = @(<at least one on>) }
#   Description  what the fragment does (GUI text and build log)
#   Pass         settings pass (specialize, oobeSystem, ...)
#   Component    component name; created with the standard attributes for the target architecture if missing
#   Kind         RunSynchronousCommand (Path) | FirstLogonCommand (CommandLine) |
#                Element (Element + Value or Children) | Attribute (Target + Attributes)
#   Parent       element path below the component ('a/b'), created if missing. Defaults: RunSynchronous,
#                FirstLogonCommands, the component itself for Element.
#   Order        Last (default) | First | After:<anchor> | Before:<anchor>. The anchor is an element name or
#                a text contained in a sibling command. Command <Order> values are renumbered 1..n.
#   Children     @( @{ Name; Value | Children; Attributes } ... ) in document order
#   Attributes   @{ name = value }; 'wcm:' names use the WMIConfig namespace
# Values may use {{UserName}} and {{ComputerName}}; they are set as XML text, never as markup.
@{
    Fragments = @(
        @{
            Id          = 'BypassNRO'
            Toggle      = 'BypassNRO'
            When        = @{ AllOf = @('BypassNetworkRequirement') }
            Description = 'specialize: set OOBE\BypassNRO so the setup does not require a network connection'
            Pass        = 'specialize'
            Component   = 'Microsoft-Windows-Deployment'
            Kind        = 'RunSynchronousCommand'
            Order       = 'After:ExtractUnattend.ps1'
            Path        = 'reg.exe add "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\OOBE" /v BypassNRO /t REG_DWORD /d 1 /f'
        }
        @{
            Id          = 'AutoLogon'
            Toggle      = 'ConfigureWinlogon'
            Description = 'oobeSystem: log the local account on automatically once (blank password)'
            Pass        = 'oobeSystem'
            Component   = 'Microsoft-Windows-Shell-Setup'
            Kind        = 'Element'
            Element     = 'AutoLogon'
            Order       = 'After:UserAccounts'
            Children    = @(
                @{ Name = 'Username'; Value = '{{UserName}}' }
                @{ Name = 'Enabled'; Value = 'true' }
                @{ Name = 'LogonCount'; Value = '1' }
                @{ Name = 'Password'; Children = @(
                        @{ Name = 'Value'; Value = '' }
                        @{ Name = 'PlainText'; Value = 'true' }
                    ) }
            )
        }
        @{
            Id          = 'JapaneseTimeZone'
            Toggle      = 'SetJapaneseKeyboard'
            Description = 'specialize: Tokyo Standard Time'
            Pass        = 'specialize'
            Component   = 'Microsoft-Windows-Shell-Setup'
            Kind        = 'Element'
            Element     = 'TimeZone'
            Value       = 'Tokyo Standard Time'
        }
        @{
            Id          = 'JapaneseInputLocale'
            Toggle      = 'SetJapaneseKeyboard'
            Description = 'specialize: Japanese 106/109 keyboard (InputLocale 0411:00000411)'
            Pass        = 'specialize'
            Component   = 'Microsoft-Windows-International-Core'
            Kind        = 'Element'
            Element     = 'InputLocale'
            Value       = '0411:00000411'
        }
    )
}
