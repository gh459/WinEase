# WinEaseUnattendComposer.ps1 - builds autounattend.xml from the base template plus the optional fragments
#
# autounattend.xml in the repository root is the base template: it holds only what every build needs.
# Every optional parameter or attribute is declared in config\unattend-fragments.psd1 and added here,
# through the XML DOM, when its toggle (a tweak key, a component key or its own 'Unattend.<Id>' key) is on.
# Nothing is removed from the template afterwards, so a value in the template can never overrule the
# user's choice. Values such as the user name are set as DOM text, never by string concatenation.
#
# PowerShell 5.1 compatible. Pure functions; no state outside the parameters.

function Get-WinEaseUnattendFragmentPath {
    $root = Split-Path -Parent $PSScriptRoot
    return (Join-Path -Path $root -ChildPath 'config\unattend-fragments.psd1')
}

function Import-WinEaseUnattendFragments {
    # Reads and validates the fragment definitions. Any problem stops the build: a fragment that is
    # silently skipped would change the answer file without anyone noticing.
    # -KnownKeys: the setting keys a Toggle or When entry may name (tweaks and components). The keys of
    # fragments without a Toggle ('Unattend.<Id>') are added automatically.
    param(
        [string]$Path = (Get-WinEaseUnattendFragmentPath),
        [string[]]$KnownKeys
    )
    if (-not (Test-Path -LiteralPath $Path)) { throw "Unattend fragments: definition file not found: $Path" }
    $data = Import-PowerShellDataFile -LiteralPath $Path
    $list = @($data.Fragments)
    $validKinds = @('RunSynchronousCommand', 'FirstLogonCommand', 'Element', 'Attribute')
    $validPasses = @('windowsPE', 'offlineServicing', 'generalize', 'specialize', 'auditSystem', 'auditUser', 'oobeSystem')
    $ids = @{}
    $known = @{}
    foreach ($k in @($KnownKeys)) { if ($k) { $known[$k] = $true } }
    foreach ($f in $list) { if ($f.Id -and -not $f.Toggle) { $known["Unattend.$($f.Id)"] = $true } }
    $result = @()
    foreach ($f in $list) {
        $id = [string]$f.Id
        if ($id -notmatch '^[A-Za-z][A-Za-z0-9]*$') { throw "Unattend fragments: invalid Id '$id'" }
        if ($ids.ContainsKey($id)) { throw "Unattend fragments: Id '$id' is defined twice" }
        $ids[$id] = $true
        foreach ($req in @('Kind', 'Pass', 'Component', 'Description')) {
            if ([string]::IsNullOrWhiteSpace([string]$f[$req])) { throw "Unattend fragments: '$id' has no $req" }
        }
        if ($validKinds -notcontains $f.Kind) { throw "Unattend fragments: '$id' has the unknown Kind '$($f.Kind)'" }
        if ($validPasses -notcontains $f.Pass) { throw "Unattend fragments: '$id' has the unknown Pass '$($f.Pass)'" }
        switch ($f.Kind) {
            'RunSynchronousCommand' { if (-not $f.Path) { throw "Unattend fragments: '$id' (RunSynchronousCommand) has no Path" } }
            'FirstLogonCommand' { if (-not $f.CommandLine) { throw "Unattend fragments: '$id' (FirstLogonCommand) has no CommandLine" } }
            'Element' { if (-not $f.Element) { throw "Unattend fragments: '$id' (Element) has no Element" } }
            'Attribute' { if (-not $f.Target -or -not $f.Attributes) { throw "Unattend fragments: '$id' (Attribute) needs Target and Attributes" } }
        }
        $toggleKey = if ($f.Toggle) { [string]$f.Toggle } else { "Unattend.$id" }
        if ($null -ne $KnownKeys -and -not $known.ContainsKey($toggleKey)) { throw "Unattend fragments: '$id' names the unknown setting '$toggleKey'" }
        $when = $f.When
        foreach ($group in @('AllOf', 'AnyOf')) {
            if ($when -and $when[$group]) {
                foreach ($k in @($when[$group])) {
                    if ($null -ne $KnownKeys -and -not $known.ContainsKey([string]$k)) { throw "Unattend fragments: '$id' When.$group names the unknown setting '$k'" }
                }
            }
        }
        $result += [PSCustomObject]@{
            Id          = $id
            ToggleKey   = $toggleKey
            OwnToggle   = (-not $f.Toggle)
            Default     = if ($null -ne $f.Default) { [bool]$f.Default } else { $false }
            Category    = if ($f.Category) { [string]$f.Category } else { 'Unattend' }
            Description = [string]$f.Description
            When        = $when
            Kind        = [string]$f.Kind
            Pass        = [string]$f.Pass
            Component   = [string]$f.Component
            Parent      = [string]$f.Parent
            Order       = [string]$f.Order
            Path        = [string]$f.Path
            CommandLine = [string]$f.CommandLine
            Element     = [string]$f.Element
            Value       = $f.Value
            Children    = $f.Children
            Target      = [string]$f.Target
            Attributes  = $f.Attributes
        }
    }
    return $result
}

function Get-WinEaseUnattendSettingValue {
    param($Settings, [string]$Key, [bool]$Default)
    if ($null -eq $Settings) { return $Default }
    if ($Settings -is [System.Collections.IDictionary]) {
        if ($Settings.Contains($Key) -and $null -ne $Settings[$Key]) { return [bool]$Settings[$Key] }
        return $Default
    }
    if ($Settings.PSObject.Properties[$Key] -and $null -ne $Settings.$Key) { return [bool]$Settings.$Key }
    return $Default
}

function Test-WinEaseUnattendFragmentEnabled {
    # Toggle on, every AllOf key on, and at least one AnyOf key on (when given). A key that is not set
    # counts as its default: the fragment's Default for its own toggle, $true for the keys named in When
    # and in Toggle (the tweak/component defaults are already resolved into the settings by the builder).
    param([Parameter(Mandatory = $true)]$Fragment, $Settings)
    $toggleDefault = if ($Fragment.OwnToggle) { [bool]$Fragment.Default } else { $true }
    if (-not (Get-WinEaseUnattendSettingValue -Settings $Settings -Key $Fragment.ToggleKey -Default $toggleDefault)) { return $false }
    $when = $Fragment.When
    if ($when) {
        foreach ($k in @($when['AllOf'])) {
            if ($k -and -not (Get-WinEaseUnattendSettingValue -Settings $Settings -Key ([string]$k) -Default $true)) { return $false }
        }
        $any = @($when['AnyOf'] | Where-Object { $_ })
        if ($any.Count -gt 0) {
            $hit = $false
            foreach ($k in $any) { if (Get-WinEaseUnattendSettingValue -Settings $Settings -Key ([string]$k) -Default $true) { $hit = $true; break } }
            if (-not $hit) { return $false }
        }
    }
    return $true
}

function Expand-WinEaseUnattendValue {
    # {{Name}} placeholders from -Values. An unknown placeholder is an error, not an empty string.
    param([AllowNull()][AllowEmptyString()][string]$Text, [hashtable]$Values)
    if ($null -eq $Text) { return '' }
    $sb = New-Object System.Text.StringBuilder
    $last = 0
    foreach ($m in [regex]::Matches($Text, '\{\{([A-Za-z]+)\}\}')) {
        $name = $m.Groups[1].Value
        if ($null -eq $Values -or -not $Values.ContainsKey($name)) { throw "Unattend fragments: no value for the placeholder '{{$name}}'" }
        [void]$sb.Append($Text.Substring($last, $m.Index - $last)).Append([string]$Values[$name])
        $last = $m.Index + $m.Length
    }
    [void]$sb.Append($Text.Substring($last))
    return $sb.ToString()
}

function New-WinEaseUnattendElement {
    param([xml]$XmlDocument, [string]$Name)
    return $XmlDocument.CreateElement($Name, $XmlDocument.DocumentElement.NamespaceURI)
}

function Set-WinEaseUnattendAttributes {
    param([System.Xml.XmlElement]$Element, $Attributes, [switch]$NoOverwrite)
    if (-not $Attributes) { return }
    foreach ($name in @($Attributes.Keys)) {
        $value = [string]$Attributes[$name]
        if ($name -like 'wcm:*') {
            $local = $name.Substring(4)
            if ($NoOverwrite -and $Element.HasAttribute($local, 'http://schemas.microsoft.com/WMIConfig/2002/State') -and $Element.GetAttribute($local, 'http://schemas.microsoft.com/WMIConfig/2002/State') -ne $value) {
                throw "Unattend fragments: attribute '$name' of <$($Element.LocalName)> already has another value"
            }
            [void]$Element.SetAttribute($local, 'http://schemas.microsoft.com/WMIConfig/2002/State', $value)
            # SetAttribute with a namespace creates its own prefix; keep the conventional 'wcm' one
            $attr = $Element.GetAttributeNode($local, 'http://schemas.microsoft.com/WMIConfig/2002/State')
            if ($attr) { $attr.Prefix = 'wcm' }
        } else {
            if ($NoOverwrite -and $Element.HasAttribute($name) -and $Element.GetAttribute($name) -ne $value) {
                throw "Unattend fragments: attribute '$name' of <$($Element.LocalName)> already has another value"
            }
            [void]$Element.SetAttribute($name, $value)
        }
    }
}

function Add-WinEaseUnattendChildren {
    param([xml]$XmlDocument, [System.Xml.XmlElement]$Parent, $Children, [hashtable]$Values)
    foreach ($c in @($Children)) {
        if (-not $c) { continue }
        $el = New-WinEaseUnattendElement -XmlDocument $XmlDocument -Name ([string]$c.Name)
        Set-WinEaseUnattendAttributes -Element $el -Attributes $c.Attributes
        if ($c.Children) {
            Add-WinEaseUnattendChildren -XmlDocument $XmlDocument -Parent $el -Children $c.Children -Values $Values
        } elseif ($null -ne $c.Value) {
            $el.InnerText = Expand-WinEaseUnattendValue -Text ([string]$c.Value) -Values $Values
        }
        [void]$Parent.AppendChild($el)
    }
}

function Get-WinEaseUnattendComponent {
    # The component of a pass, created with the standard attributes when the template has none.
    param([xml]$XmlDocument, [string]$Pass, [string]$Component, [string]$Architecture)
    $settings = $XmlDocument.SelectSingleNode("/*[local-name()='unattend']/*[local-name()='settings'][@pass='$Pass']")
    if (-not $settings) {
        $settings = New-WinEaseUnattendElement -XmlDocument $XmlDocument -Name 'settings'
        [void]$settings.SetAttribute('pass', $Pass)
        $ext = $XmlDocument.SelectSingleNode("/*[local-name()='unattend']/*[local-name()='Extensions']")
        if ($ext) { [void]$XmlDocument.DocumentElement.InsertBefore($settings, $ext) } else { [void]$XmlDocument.DocumentElement.AppendChild($settings) }
    }
    $comp = $settings.SelectSingleNode("*[local-name()='component'][@name='$Component'][@processorArchitecture='$Architecture']")
    if (-not $comp) {
        $comp = New-WinEaseUnattendElement -XmlDocument $XmlDocument -Name 'component'
        [void]$comp.SetAttribute('name', $Component)
        [void]$comp.SetAttribute('processorArchitecture', $Architecture)
        [void]$comp.SetAttribute('publicKeyToken', '31bf3856ad364e35')
        [void]$comp.SetAttribute('language', 'neutral')
        [void]$comp.SetAttribute('versionScope', 'nonSxS')
        [void]$settings.AppendChild($comp)
    }
    return $comp
}

function Get-WinEaseUnattendPathNode {
    # Walks (and with -Create builds) a '/'-separated path of element names below a node.
    param([xml]$XmlDocument, [System.Xml.XmlNode]$Start, [string]$RelativePath, [switch]$Create)
    $node = $Start
    foreach ($part in @($RelativePath -split '/' | Where-Object { $_ })) {
        $next = $node.SelectSingleNode("*[local-name()='$part']")
        if (-not $next) {
            if (-not $Create) { return $null }
            $next = New-WinEaseUnattendElement -XmlDocument $XmlDocument -Name $part
            [void]$node.AppendChild($next)
        }
        $node = $next
    }
    return $node
}

function Add-WinEaseUnattendNodeOrdered {
    # Order: '' or 'Last' appends, 'First' prepends, 'After:<text>' / 'Before:<text>' places the node next
    # to the first sibling whose text contains <text> (a command) or whose name is <text> (an element).
    param([System.Xml.XmlNode]$Parent, [System.Xml.XmlNode]$Node, [string]$Order)
    if ([string]::IsNullOrWhiteSpace($Order) -or $Order -eq 'Last') { [void]$Parent.AppendChild($Node); return }
    if ($Order -eq 'First') { [void]$Parent.PrependChild($Node); return }
    if ($Order -notmatch '^(After|Before):(.+)$') { throw "Unattend fragments: invalid Order '$Order'" }
    $mode = $matches[1]; $anchorText = $matches[2]
    $anchor = $null
    foreach ($s in @($Parent.ChildNodes)) {
        if ($s.NodeType -ne [System.Xml.XmlNodeType]::Element) { continue }
        if ($s.LocalName -eq $anchorText -or $s.InnerText.Contains($anchorText)) { $anchor = $s; break }
    }
    if (-not $anchor) { throw "Unattend fragments: the anchor '$anchorText' of Order '$Order' was not found" }
    if ($mode -eq 'After') { [void]$Parent.InsertAfter($Node, $anchor) } else { [void]$Parent.InsertBefore($Node, $anchor) }
}

function Update-WinEaseUnattendCommandOrder {
    # Renumbers <Order> of every command list 1..n in document order.
    param([xml]$XmlDocument)
    foreach ($list in @($XmlDocument.SelectNodes("//*[local-name()='RunSynchronous' or local-name()='FirstLogonCommands']"))) {
        $n = 1
        foreach ($cmd in @($list.SelectNodes("*[local-name()='RunSynchronousCommand' or local-name()='SynchronousCommand']"))) {
            $o = $cmd.SelectSingleNode("*[local-name()='Order']")
            if ($o) { $o.InnerText = "$n" }
            $n++
        }
    }
}

function Add-WinEaseUnattendFragment {
    param(
        [Parameter(Mandatory = $true)][xml]$XmlDocument,
        [Parameter(Mandatory = $true)]$Fragment,
        [Parameter(Mandatory = $true)][string]$Architecture,
        [hashtable]$Values
    )
    $comp = Get-WinEaseUnattendComponent -XmlDocument $XmlDocument -Pass $Fragment.Pass -Component $Fragment.Component -Architecture $Architecture
    switch ($Fragment.Kind) {
        'RunSynchronousCommand' {
            $parent = Get-WinEaseUnattendPathNode -XmlDocument $XmlDocument -Start $comp -RelativePath $(if ($Fragment.Parent) { $Fragment.Parent } else { 'RunSynchronous' }) -Create
            $cmd = New-WinEaseUnattendElement -XmlDocument $XmlDocument -Name 'RunSynchronousCommand'
            Set-WinEaseUnattendAttributes -Element $cmd -Attributes @{ 'wcm:action' = 'add' }
            $o = New-WinEaseUnattendElement -XmlDocument $XmlDocument -Name 'Order'; $o.InnerText = '0'; [void]$cmd.AppendChild($o)
            $p = New-WinEaseUnattendElement -XmlDocument $XmlDocument -Name 'Path'; $p.InnerText = Expand-WinEaseUnattendValue -Text $Fragment.Path -Values $Values; [void]$cmd.AppendChild($p)
            foreach ($existing in @($parent.SelectNodes("*/*[local-name()='Path']"))) {
                if ($existing.InnerText -eq $p.InnerText) { throw "Unattend fragments: '$($Fragment.Id)' duplicates an existing command" }
            }
            Add-WinEaseUnattendNodeOrdered -Parent $parent -Node $cmd -Order $Fragment.Order
        }
        'FirstLogonCommand' {
            $parent = Get-WinEaseUnattendPathNode -XmlDocument $XmlDocument -Start $comp -RelativePath $(if ($Fragment.Parent) { $Fragment.Parent } else { 'FirstLogonCommands' }) -Create
            $cmd = New-WinEaseUnattendElement -XmlDocument $XmlDocument -Name 'SynchronousCommand'
            Set-WinEaseUnattendAttributes -Element $cmd -Attributes @{ 'wcm:action' = 'add' }
            $o = New-WinEaseUnattendElement -XmlDocument $XmlDocument -Name 'Order'; $o.InnerText = '0'; [void]$cmd.AppendChild($o)
            $c = New-WinEaseUnattendElement -XmlDocument $XmlDocument -Name 'CommandLine'; $c.InnerText = Expand-WinEaseUnattendValue -Text $Fragment.CommandLine -Values $Values; [void]$cmd.AppendChild($c)
            Add-WinEaseUnattendNodeOrdered -Parent $parent -Node $cmd -Order $Fragment.Order
        }
        'Element' {
            $parent = if ($Fragment.Parent) { Get-WinEaseUnattendPathNode -XmlDocument $XmlDocument -Start $comp -RelativePath $Fragment.Parent -Create } else { $comp }
            if ($parent.SelectSingleNode("*[local-name()='$($Fragment.Element)']")) {
                throw "Unattend fragments: '$($Fragment.Id)' would overwrite the existing element <$($Fragment.Element)> in $($Fragment.Pass)/$($Fragment.Component)"
            }
            $el = New-WinEaseUnattendElement -XmlDocument $XmlDocument -Name $Fragment.Element
            Set-WinEaseUnattendAttributes -Element $el -Attributes $Fragment.Attributes
            if ($Fragment.Children) {
                Add-WinEaseUnattendChildren -XmlDocument $XmlDocument -Parent $el -Children $Fragment.Children -Values $Values
            } elseif ($null -ne $Fragment.Value) {
                $el.InnerText = Expand-WinEaseUnattendValue -Text ([string]$Fragment.Value) -Values $Values
            }
            Add-WinEaseUnattendNodeOrdered -Parent $parent -Node $el -Order $Fragment.Order
        }
        'Attribute' {
            $target = Get-WinEaseUnattendPathNode -XmlDocument $XmlDocument -Start $comp -RelativePath $Fragment.Target
            if (-not $target) { throw "Unattend fragments: '$($Fragment.Id)' target '$($Fragment.Target)' does not exist" }
            $expanded = @{}
            foreach ($k in @($Fragment.Attributes.Keys)) { $expanded[$k] = Expand-WinEaseUnattendValue -Text ([string]$Fragment.Attributes[$k]) -Values $Values }
            Set-WinEaseUnattendAttributes -Element $target -Attributes $expanded -NoOverwrite
        }
    }
}

function Set-WinEaseUnattendPlaceholders {
    # Fills the {{Name}} placeholders of the base template (text nodes only, so a value can never become
    # markup). A placeholder without a value is an error.
    param([Parameter(Mandatory = $true)][xml]$XmlDocument, [hashtable]$Values)
    foreach ($t in @($XmlDocument.SelectNodes('//text()'))) {
        if ($t.Value -match '\{\{[A-Za-z]+\}\}') { $t.Value = Expand-WinEaseUnattendValue -Text $t.Value -Values $Values }
    }
}

function Invoke-WinEaseUnattendComposition {
    # Applies every enabled fragment for the target architecture, fills the placeholders and renumbers the
    # command lists. Returns the applied and the skipped fragment ids.
    param(
        [Parameter(Mandatory = $true)][xml]$XmlDocument,
        [Parameter(Mandatory = $true)]$Fragments,
        $Settings,
        [Parameter(Mandatory = $true)][string]$Architecture,
        [hashtable]$Values
    )
    $applied = @(); $skipped = @()
    # The base template must not carry an optional part itself (an old full template, for example the one
    # the self-healing download fetches): it would stay in the answer file whatever the setting says.
    foreach ($f in @($Fragments)) {
        $settingsNode = $XmlDocument.SelectSingleNode("/*[local-name()='unattend']/*[local-name()='settings'][@pass='$($f.Pass)']")
        if (-not $settingsNode) { continue }
        foreach ($comp in @($settingsNode.SelectNodes("*[local-name()='component'][@name='$($f.Component)']"))) {
            $carried = $false
            switch ($f.Kind) {
                'RunSynchronousCommand' { $carried = @($comp.SelectNodes(".//*[local-name()='RunSynchronousCommand']/*[local-name()='Path']") | Where-Object { $_.InnerText -eq $f.Path }).Count -gt 0 }
                'FirstLogonCommand' { $carried = @($comp.SelectNodes(".//*[local-name()='SynchronousCommand']/*[local-name()='CommandLine']") | Where-Object { $_.InnerText -eq $f.CommandLine }).Count -gt 0 }
                'Element' { $carried = $null -ne $comp.SelectSingleNode(".//*[local-name()='$($f.Element)']") }
            }
            if ($carried) { throw "autounattend.xml already contains the optional part '$($f.Id)'. Use the base template of this repository; optional parts come from config\unattend-fragments.psd1." }
        }
    }
    foreach ($f in @($Fragments)) {
        if (Test-WinEaseUnattendFragmentEnabled -Fragment $f -Settings $Settings) {
            Add-WinEaseUnattendFragment -XmlDocument $XmlDocument -Fragment $f -Architecture $Architecture -Values $Values
            $applied += $f.Id
        } else {
            $skipped += $f.Id
        }
    }
    Set-WinEaseUnattendPlaceholders -XmlDocument $XmlDocument -Values $Values
    Update-WinEaseUnattendCommandOrder -XmlDocument $XmlDocument
    return [PSCustomObject]@{ Applied = $applied; Skipped = $skipped }
}

function Test-WinEaseUnattendIdentity {
    # The user and computer names end up in XML text and in the embedded setup scripts. The same rules as
    # the GUI apply to the command line, so both accept exactly the same names.
    param([string]$UserName, [string]$MachineName)
    if ($UserName -notmatch '^[\p{L}\p{N}_][\p{L}\p{N} ._-]{0,19}$') { throw "Invalid user name '$UserName' (1-20 letters, digits, space, '.', '_' or '-')." }
    if ($MachineName -notmatch '^(\*|[A-Za-z0-9][A-Za-z0-9-]{0,14})$') { throw "Invalid computer name '$MachineName' ('*' or 1-15 letters, digits or '-')." }
}
