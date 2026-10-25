$ErrorActionPreference = 'Stop'
$script:Fails = 0
function Check([bool]$c, [string]$m) { if ($c) { "  PASS  $m" } else { $script:Fails++; "  FAIL  $m" } }
function CountBoxes($node, [switch]$VisibleOnly) {
    if ($node -is [System.Windows.Controls.CheckBox]) {
        if ($VisibleOnly -and $node.Visibility -ne [System.Windows.Visibility]::Visible) { return 0 }
        return 1
    }
    $n = 0
    if ($node -is [System.Windows.Controls.Panel]) {
        foreach ($el in $node.Children) { $n += CountBoxes $el -VisibleOnly:$VisibleOnly }
    } elseif ($node.Child) {
        $n += CountBoxes $node.Child -VisibleOnly:$VisibleOnly
    }
    return $n
}

. ((Get-Location).Path + '\Velocity11.ps1')

'--- 1. window + controls ---'
$win = New-V11GuiWindow
Check ($win -is [System.Windows.Window]) 'WPF window parsed from XAML'
Check ([string]$win.Title -like 'Velocity11*') 'title = ' + $win.Title
foreach ($n in @('RunButton','UndoButton','RestorePointButton','LogBox','StatusLabel','StatusDot','FilterBox','FilterHint','SectionHost')) {
    Check ($null -ne (Get-V11GuiName -Window $win -Name $n)) "control present: $n"
}
$run = Get-V11GuiName -Window $win -Name 'RunButton'
Check ($run.Template -ne $null) 'buttons use a custom pill template'
$null = Get-V11GuiName -Window $win -Name 'SectionHost'
Check ((Get-V11GuiName -Window $win -Name 'RunButton').Template -ne $null) 'Run button template resolved'

$groups = Get-V11Tweaks
$host2  = Get-V11GuiName -Window $win -Name 'SectionHost'
$boxes  = Add-V11GuiSections -Window $win -Groups $groups
$cards  = @($host2.Children | Where-Object { $_ -is [System.Windows.Controls.Border] })
$expected = 0; $enabled = 0
foreach ($g in $groups) { foreach ($t in $g.Tweaks) { $expected++; if ($t.Enabled) { $enabled++ } } }

'--- 2. sections and checkboxes ---'
$gamerGroup = @($groups | Where-Object { $_.Id -eq 'gamer' })
Check ($null -ne $gamerGroup -and @($gamerGroup.Tweaks).Count -eq 6) 'Gamer section present with 6 tweaks'
Check ((@($gamerGroup.Tweaks) | Where-Object { $_.Id -eq 'controller-gamebar' }).Default -eq $true) 'controller Game Bar toggle ships ON'
Check ((@($gamerGroup.Tweaks) | Where-Object { $_.Id -eq 'ultimate-power' }).Default -eq $false) 'Ultimate Performance ships opt-in'
Check ((@($gamerGroup.Tweaks) | Where-Object { $_.Id -eq 'core-parking' }).Default -eq $false) 'core parking ships opt-in'
Check ($cards.Count -eq $groups.Count) "one card per section ($($cards.Count) of $($groups.Count))"
Check ($boxes -eq $expected) "checkboxes rendered = catalogue tweaks ($boxes of $expected)"
$checked = 0; $tips = 0; $optIn = $null; $gameMode = $null
foreach ($card in $cards) {
    foreach ($el in $card.Child.Children) {
        if ($el -is [System.Windows.Controls.CheckBox]) {
            if ($el.IsChecked) { $checked++ }
            if ($el.ToolTip)   { $tips++ }
            if ($el.Tag.Id -eq 'wap-push')    { $optIn = $el }
            if ($el.Tag.Id -eq 'game-mode')   { $gameMode = $el }
        }
    }
}
Check ($checked -eq $enabled) "ticked ($checked) == default-enabled ($enabled)"
Check ($tips -eq $boxes) 'every checkbox has a detail tooltip'
Check ($optIn -and $optIn.IsChecked -eq $false) 'opt-in tweak starts unticked'
Check ($gameMode -and $gameMode.IsChecked -eq $true) 'default tweak starts ticked'
Check (@($gameMode.Style.Setters).Count -ge 5) 'checkboxes use the custom tile style'

'--- 3. UI -> model sync ---'
$gameMode.IsChecked = $false
$c2 = Sync-V11GuiToModel -Window $win
Check ($c2 -eq ($enabled - 1)) "sync returned $c2 after unticking"
$gm = @($groups | Where-Object { $_.Id -eq 'gaming' }).Tweaks | Where-Object { $_.Id -eq 'game-mode' }
Check ($gm.Enabled -eq $false) 'model reflects the unticked box'
$optIn.IsChecked = $true
$c3 = Sync-V11GuiToModel -Window $win
$op = @($groups | Where-Object { $_.Id -eq 'privacy' }).Tweaks | Where-Object { $_.Id -eq 'wap-push' }
Check ($c3 -eq $enabled -and $op.Enabled -eq $true) 'opt-in selectable from the UI'

'--- 4. filter box ---'
Update-V11GuiFilter -Window $win -Query 'game'
$v = CountBoxes $host2 -VisibleOnly
Check ($v -gt 0 -and $v -lt $boxes) "filter 'game' narrowed to $v of $boxes"
Update-V11GuiFilter -Window $win -Query 'telemetry'
$v2 = CountBoxes $host2 -VisibleOnly
Check ($v2 -gt 0 -and $v2 -lt $boxes) "filter 'telemetry' narrowed to $v2"
Update-V11GuiFilter -Window $win -Query 'zzzzz-no-such-tweak'
$v3 = CountBoxes $host2 -VisibleOnly
Check ($v3 -eq 0) "filter with no match hides everything ($v3)"
Update-V11GuiFilter -Window $win -Query ''
$v4 = CountBoxes $host2 -VisibleOnly
Check ($v4 -eq $boxes) "clearing the filter restores all $v4"

'--- 5. activity log ---'
$box = New-Object System.Windows.Controls.TextBox
$script:V11LogBox = $box
$script:V11LogSink = { param($m, $c) Update-V11GuiLog -Box $script:V11LogBox -Message $m }
Write-V11 'routed line' 'Green'
Check ($box.Text -like '*routed line*') 'Write-V11 routes into the log pane'
$script:V11LogSink = $null; $script:V11LogBox = $null

'--- 6. render a preview image (window still never shown) ---'
# sample log lines so the preview image shows the log pane styled
$winLog = Get-V11GuiName -Window $win -Name 'LogBox'
Update-V11GuiLog -Box $winLog -Message ('Velocity11 ready - {0} tweak(s) in {1} sections. Nothing has been changed yet.' -f $boxes, $groups.Count)
Update-V11GuiLog -Box $winLog -Message 'Hover a checkbox for the exact registry path it writes.'
Update-V11GuiLog -Box $winLog -Message 'A snapshot is written BEFORE anything changes; Undo Tweaks puts it back.'

try {
    $w = 1180; $h = 830
    $root = $win.Content                       # a never-shown Window cannot be captured directly
    $root.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#FF0B0B11')
    $null = $root.Measure([System.Windows.Size]::new($w, $h))
    $root.Arrange([System.Windows.Rect]::new(0, 0, $w, $h))
    $root.UpdateLayout()
    $rtb = New-Object System.Windows.Media.Imaging.RenderTargetBitmap($w, $h, 96, 96, [System.Windows.Media.PixelFormats]::Pbgra32)
    $rtb.Render($root)
    $enc = New-Object System.Windows.Media.Imaging.PngBitmapEncoder
    $enc.Frames.Add([System.Windows.Media.Imaging.BitmapFrame]::Create($rtb))
    $out = Join-Path (Get-Location).Path 'preview.png'
    $fs = [System.IO.File]::Create($out)
    $enc.Save($fs); $fs.Close()
    $root.Background = $null                   # leave the live tree exactly as it was
    Check ((Get-Item $out).Length -gt 1500) ("preview.png rendered (" + (Get-Item $out).Length + " bytes)")
} catch {
    Check $false ("preview render failed: " + $_.Exception.Message)
}

'--- 7. new helper functions exist ---'
foreach ($f in @('Disable-V11Task','Get-V11PowerSettingIndex','Set-V11PowerSetting','Set-V11Trim','Update-V11GuiFilter','Restore-V11Snapshot')) {
    Check ([bool](Get-Command $f -EA SilentlyContinue)) "function defined: $f"
}

'--- 8. engine regression (scratch HKCU key only) ---'
$testKey = 'Software\V11SelfTest'
$full    = 'HKCU:\' + $testKey
if (Test-Path $full) { Remove-Item -Path $full -Recurse -Force }
New-Item -Path $full -Force | Out-Null
New-ItemProperty -LiteralPath $full -Name 'Pre' -Value 'old' -PropertyType String -Force | Out-Null
$grp = [pscustomobject]@{ Id='t'; Name='T'; Desc=''; Enabled=$true; Tweaks=@(
    [pscustomobject]@{ Id='a'; Name='write'; Detail='d'; Reboot=$false; Default=$true; Enabled=$true
        Actions=@( @{Type='Reg';Hive='HKCU';Key=$testKey;Name='Added';RegType='DWord';Data=7} ) },
    [pscustomobject]@{ Id='b'; Name='skipped'; Detail='d'; Reboot=$false; Default=$false; Enabled=$false
        Actions=@( @{Type='Reg';Hive='HKCU';Key=$testKey;Name='Never';RegType='DWord';Data=1} ) } ) }
$dir = Join-Path $env:TEMP ('v11_' + (Get-Random))
$ok = Invoke-V11Apply -Groups @($grp) -SnapshotDir $dir
Check ($ok -eq $true) 'apply succeeded on scratch key'
Check ((Get-ItemProperty -LiteralPath $full -Name 'Added').Added -eq 7) 'value written'
Check ($null -eq (Get-ItemProperty -LiteralPath $full -Name 'Never' -EA SilentlyContinue)) 'disabled tweak skipped'
Check ((Restore-V11Snapshot -Dir $dir) -eq $true) 'revert succeeded'
Check ($null -eq (Get-ItemProperty -LiteralPath $full -Name 'Added' -EA SilentlyContinue)) 'value removed on revert'
Check ((Get-ItemProperty -LiteralPath $full -Name 'Pre').Pre -eq 'old') 'pre-existing value restored'
$badDir = 'Q:\v11_no_such_drive\snap'
$grpAbort = [pscustomobject]@{ Id='t2'; Name='T2'; Desc=''; Enabled=$true; Tweaks=@(
    [pscustomobject]@{ Id='c'; Name='must not run'; Detail='d'; Reboot=$false; Default=$true; Enabled=$true
        Actions=@( @{Type='Reg';Hive='HKCU';Key=$testKey;Name='AbortTest';RegType='DWord';Data=99} ) } ) }
Check ((Invoke-V11Apply -Groups @($grpAbort) -SnapshotDir $badDir) -eq $false) 'unwritable snapshot dir aborts apply'
Check ($null -eq (Get-ItemProperty -LiteralPath $full -Name 'AbortTest' -EA SilentlyContinue)) 'abort wrote nothing'

'--- 9. nothing was applied to this machine ---'
Check ($win.IsVisible -eq $false) 'window never shown'
Check (@(Get-V11Snapshots).Count -eq 0) 'no snapshots exist'
Remove-Item -Path $full -Recurse -Force -EA SilentlyContinue
Remove-Item -Path $dir -Recurse -Force -EA SilentlyContinue

Write-Host ''
if ($script:Fails -eq 0) { Write-Host 'HARNESS: ALL CHECKS PASSED' -ForegroundColor Green; exit 0 }
Write-Host "HARNESS: $($script:Fails) CHECK(S) FAILED" -ForegroundColor Red; exit 1
