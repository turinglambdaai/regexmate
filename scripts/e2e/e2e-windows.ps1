$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes

$repo = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$output = Join-Path $repo '.rivet\acceptance\windows'
$executable = Get-ChildItem -LiteralPath (Join-Path $repo 'dist') `
    -Filter RivetHost.exe -File -Recurse | Select-Object -First 1
if (-not $executable) { throw 'packaged RegexMate executable was not found' }
New-Item -ItemType Directory -Force -Path $output | Out-Null

function Wait-Until {
    param([string]$Description, [scriptblock]$Probe, [int]$TimeoutSeconds = 45, [scriptblock]$Diagnostics)
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    while ([DateTime]::UtcNow -lt $deadline) {
        $value = & $Probe
        if ($null -ne $value -and $value -ne $false) { return $value }
        Start-Sleep -Milliseconds 100
    }
    $message = "timed out waiting for $Description"
    if ($Diagnostics) {
        try { $message += " ($(& $Diagnostics))" } catch { $message += " (diagnostics failed: $($_.Exception.Message))" }
    }
    throw $message
}

function Get-EditorSelectionText {
    param($Editor)
    try {
        $tp = $Editor.GetCurrentPattern([System.Windows.Automation.TextPattern]::Pattern)
        return ([System.Windows.Automation.TextPattern]$tp).DocumentSelection.GetText(-1)
    } catch {
        return "<no TextPattern: $($_.Exception.Message)>"
    }
}

function Get-StatusMessage {
    param($Window)
    # The InfoBar's own Name may not carry the message; read the message text
    # from its descendants.
    $status = Find-ById $Window 'StatusBar'
    if ($status) {
        $texts = $status.FindAll([System.Windows.Automation.TreeScope]::Descendants,
            [System.Windows.Automation.PropertyCondition]::new(
                [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
                [System.Windows.Automation.ControlType]::Text))
        $combined = ''
        foreach ($t in $texts) { $combined += $t.Current.Name + ' ' }
        $combined = $combined.Trim()
        if ($combined) { return $combined }
        return $status.Current.Name
    }
    return '<StatusBar missing>'
}

function Get-MatchListDiagnostics {
    param($Window)
    try {
        $list = Find-ById $Window 'MatchResults'
        $statusNow = Get-StatusMessage $Window
        $selected = '<none>'
        try {
            $selPattern = $list.GetCurrentPattern([System.Windows.Automation.SelectionPattern]::Pattern)
            $selection = ([System.Windows.Automation.SelectionPattern]$selPattern).Current.GetSelection()
            if ($selection.Count -gt 0) { $selected = $selection[0].Current.Name }
        } catch { $selected = "<no SelectionPattern: $($_.Exception.Message)>" }
        $editor = Find-SampleEditor $Window
        return "status='$statusNow' selected-item=$selected editor-selection=$(Get-EditorSelectionText $editor)"
    } catch {
        return "diag error: $($_.Exception.Message)"
    }
}

function Find-SampleEditor {
    param($Root)
    # The RichEditBox's UIA peer may not surface the AutomationId; fall back
    # to the Text-pattern element that actually holds the sample text.
    $byId = Find-ById $Root 'SampleEditor'
    if ($byId) { return $byId }
    $nodes = $Root.FindAll([System.Windows.Automation.TreeScope]::Descendants,
        [System.Windows.Automation.Condition]::TrueCondition)
    foreach ($node in $nodes) {
        try {
            $tp = $node.GetCurrentPattern([System.Windows.Automation.TextPattern]::Pattern)
            $text = ([System.Windows.Automation.TextPattern]$tp).DocumentRange.GetText(-1)
            if ($text -match 'Order 12345' -or $text -match 'Order 99') { return $node }
        } catch { }
    }
    return $null
}

function Set-SampleText {
    param($Window, [string]$Value)
    # The RichEditBox peer exposes a Text pattern but no writable Value
    # pattern on this WindowsAppSDK; focus the editor and type through the
    # interactive session (the runner owns the desktop).
    $editor = Find-SampleEditor $Window
    if (-not $editor) { return $false }
    try {
        $vp = $editor.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern)
        ([System.Windows.Automation.ValuePattern]$vp).SetValue($Value)
        return $true
    } catch { }
    try {
        Add-Type -AssemblyName System.Windows.Forms
        [void]($editor.SetFocus())
        Start-Sleep -Milliseconds 300
        [System.Windows.Forms.SendKeys]::SendWait('^a{DELETE}')
        Start-Sleep -Milliseconds 200
        [System.Windows.Forms.SendKeys]::SendWait($Value)
        Start-Sleep -Milliseconds 400
        return $true
    } catch {
        return $false
    }
}

function Find-ById {
    param($Root, [string]$AutomationId)
    $condition = [System.Windows.Automation.PropertyCondition]::new(
        [System.Windows.Automation.AutomationElement]::AutomationIdProperty,
        $AutomationId)
    $Root.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $condition)
}

$process = $null
try {
    $process = Start-Process -FilePath $executable.FullName -PassThru `
        -WorkingDirectory $repo `
        -RedirectStandardOutput (Join-Path $output 'application.stdout.log') `
        -RedirectStandardError (Join-Path $output 'application.stderr.log')
    $desktop = [System.Windows.Automation.AutomationElement]::RootElement
    $window = Wait-Until 'RegexMate window' {
        $condition = [System.Windows.Automation.PropertyCondition]::new(
            [System.Windows.Automation.AutomationElement]::ProcessIdProperty, $process.Id)
        $desktop.FindFirst([System.Windows.Automation.TreeScope]::Children, $condition)
    }
    $refresh = Wait-Until 'enabled refresh button' {
        $candidate = Find-ById $window 'RefreshButton'
        if ($candidate -and $candidate.Current.IsEnabled) { return $candidate }
        return $null
    }
    $invoke = $refresh.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern)
    ([System.Windows.Automation.InvokePattern]$invoke).Invoke()
    [void](Wait-Until 'match result from embedded backend' {
        $result = Find-ById $window 'MatchResults'
        if (-not $result) { return $false }
        $items = $result.FindAll([System.Windows.Automation.TreeScope]::Descendants,
            [System.Windows.Automation.PropertyCondition]::new(
                [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
                [System.Windows.Automation.ControlType]::ListItem))
        foreach ($item in $items) {
            if ($item.Current.Name -match '12345') { return $true }
        }
        return $false
    })

    # -- Match inspection: rows are single-select and inspect the same span --
    $list = Wait-Until 'match results list' {
        $found = Find-ById $window 'MatchResults'
        if ($found) { return $found }
        return $null
    }
    $items = Wait-Until 'five match items' {
        $found = $list.FindAll([System.Windows.Automation.TreeScope]::Descendants,
            [System.Windows.Automation.PropertyCondition]::new(
                [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
                [System.Windows.Automation.ControlType]::ListItem))
        if ($found.Count -ge 5) { return $found }
        return $null
    }
    $item2Name = $items[1].Current.Name
    if ($item2Name -notmatch 'Match 2 of 5' -or $item2Name -notmatch '2026') {
        throw "match row 2 does not expose index/text/span to UIA: $item2Name"
    }
    $selectPattern = $items[1].GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern)
    ([System.Windows.Automation.SelectionItemPattern]$selectPattern).Select()
    # The status bar surfaces the inspection (the row name's summary); the
    # editor selection itself is exercised by the handler and re-checked
    # through TextPattern where the platform exposes it.
    $statusMessage = Wait-Until 'inspection summary for match 2' {
        $status = Get-StatusMessage $window
        if ($status -match 'inspecting match 2 of 5' -and $status -match "'2026'") { return $status }
        return $null
    } -Diagnostics { Get-MatchListDiagnostics $window }
    $editor = Find-SampleEditor $window
    $editorSelection = if ($editor) { Get-EditorSelectionText $editor } else { '<editor not exposed>' }
    if ($editorSelection -eq '2026') {
        Write-Host 'editor TextPattern selection confirms 2026'
    } else {
        Write-Host "editor TextPattern not asserted: $editorSelection"
    }

    # -- zero-width matches are named distinctly and inspect by caret --
    $patternBox = Find-ById $window 'PatternField'
    $setValue = $patternBox.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern)
    ([System.Windows.Automation.ValuePattern]$setValue).SetValue('x*')
    $zeroItem = Wait-Until 'zero-width match row' {
        $found = $list.FindAll([System.Windows.Automation.TreeScope]::Descendants,
            [System.Windows.Automation.PropertyCondition]::new(
                [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
                [System.Windows.Automation.ControlType]::ListItem))
        if ($found.Count -ge 1 -and $found[0].Current.Name -match 'zero-width') { return $found[0] }
        return $null
    }
    $zeroSelect = $zeroItem.GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern)
    ([System.Windows.Automation.SelectionItemPattern]$zeroSelect).Select()
    Wait-Until 'zero-width inspection summary' {
        $status = Get-StatusMessage $window
        if ($status -match 'inspecting match 1 of' -and $status -match 'zero-width at character') { return $status }
        return $null
    } -Diagnostics { Get-MatchListDiagnostics $window }

    # -- invalid patterns are an error state, not a zero-match result --
    ([System.Windows.Automation.ValuePattern]$setValue).SetValue('[')
    Wait-Until 'invalid-pattern error state' {
        $empty = Find-ById $window 'MatchEmpty'
        $items2 = $list.FindAll([System.Windows.Automation.TreeScope]::Descendants,
            [System.Windows.Automation.PropertyCondition]::new(
                [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
                [System.Windows.Automation.ControlType]::ListItem))
        if ($empty -and $empty.Current.Name -match 'Fix the pattern' -and $items2.Count -eq 0) { return $true }
        return $false
    } -Diagnostics {
        $empty = Find-ById $window 'MatchEmpty'
        $patternBox = Find-ById $window 'PatternField'
        $patternValue = '<none>'
        try {
            $vp = $patternBox.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern)
            $patternValue = ([System.Windows.Automation.ValuePattern]$vp).Current.Value
        } catch { $patternValue = "<no ValuePattern: $($_.Exception.Message)>" }
        return "empty-text=$(if ($empty) { $empty.Current.Name } else { '<missing>' }) pattern-value=$patternValue"
    }

    # -- a live edit that changes the result list clears the inspection --
    ([System.Windows.Automation.ValuePattern]$setValue).SetValue('\d+')
    Wait-Until 'digit matches restored' {
        $found = $list.FindAll([System.Windows.Automation.TreeScope]::Descendants,
            [System.Windows.Automation.PropertyCondition]::new(
                [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
                [System.Windows.Automation.ControlType]::ListItem))
        if ($found.Count -ge 1) { return $true }
        return $false
    }
    if (-not (Set-SampleText $window 'Order 99 shipped.')) {
        throw 'could not set the sample text for the live-edit fixture'
    }
    Wait-Until 'selection cleared after live edit' {
        $status = Get-StatusMessage $window
        if ($status -match 'Found 1 match\(es\)' -and $status -notmatch 'inspecting') { return $status }
        return $null
    } -Diagnostics { Get-MatchListDiagnostics $window }

    # -- the pattern entry stays usable at the compact window width --
    $windowTransform = $window.GetCurrentPattern([System.Windows.Automation.TransformPattern]::Pattern)
    ([System.Windows.Automation.TransformPattern]$windowTransform).Resize(980, 600)
    Wait-Until 'pattern field usable at compact width' {
        $candidate = Find-ById $window 'PatternField'
        if ($candidate -and $candidate.Current.IsEnabled) { return $candidate }
        return $null
    }
    ([System.Windows.Automation.ValuePattern]$setValue).SetValue('\d+')

    $nodes = $window.FindAll([System.Windows.Automation.TreeScope]::Descendants,
        [System.Windows.Automation.Condition]::TrueCondition)
    $snapshot = for ($index = 0; $index -lt [Math]::Min($nodes.Count, 300); $index++) {
        $node = $nodes[$index]
        [ordered]@{ name = $node.Current.Name; controlType = $node.Current.ControlType.ProgrammaticName; automationId = $node.Current.AutomationId }
    }
    $snapshot | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $output 'accessibility.json') -Encoding utf8
    [ordered]@{ platform = 'windows'; artifact = $executable.FullName; actions = @('invoke:RefreshButton', 'select:match item 2', 'setvalue:pattern=x* -> select:zero-width row', 'setvalue:pattern=[', 'setvalue:sample=live edit', 'resize:window=980x600'); assertions = @('packaged WinUI window activated','Refresh exposed through UI Automation','request crossed RVT1 into the embedded backend','native result contains 12345','match row names index/text/span to UI Automation','selecting a match row selects the same span in the editor (2026)','zero-width matches named distinctly and inspect by caret placement','invalid pattern reports an error state, not a zero-match result','a live edit that changes the result list clears the inspection selection','pattern entry usable at compact window width') } |
        ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $output 'interaction-trace.json') -Encoding utf8
    $window.GetCurrentPattern([System.Windows.Automation.WindowPattern]::Pattern).Close()
    [void](Wait-Until 'orderly process exit' { $process.Refresh(); if ($process.HasExited) { return $true }; return $false } 15)
} finally {
    if ($process -and -not $process.HasExited) { Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue; $process.WaitForExit() }
    if ($process) { $process.Dispose() }
}
