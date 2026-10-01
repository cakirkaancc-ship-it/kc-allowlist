param(
    [Parameter(Mandatory = $true)]
    [string]$StatePath,
    [int]$HostPid = 0,
    [long]$HostHwnd = 0,
    [switch]$SelfTest
)

$ErrorActionPreference = 'Stop'
$LogPath = $StatePath + '.log'
trap {
    try { [IO.File]::WriteAllText($LogPath, ($_ | Out-String), (New-Object Text.UTF8Encoding($false))) } catch { }
    exit 1
}
Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName System.Windows.Forms

$createdNew = $false
$hostKey = if ($HostPid -gt 0) { [string]$HostPid } elseif ($HostHwnd -gt 0) { [string]$HostHwnd } else { '0' }
$mutexName = 'Local\DEG_DT_TAVA_PALET_' + $hostKey
$mutex = New-Object System.Threading.Mutex($true, $mutexName, [ref]$createdNew)
if (-not $createdNew) {
    $mutex.Dispose()
    exit 0
}

function Read-State {
    param([string]$Path)
    $result = @{}
    if (Test-Path -LiteralPath $Path) {
        foreach ($line in [IO.File]::ReadAllLines($Path)) {
            $pos = $line.IndexOf('=')
            if ($pos -gt 0) {
                $result[$line.Substring(0, $pos).Trim().ToUpperInvariant()] = $line.Substring($pos + 1)
            }
        }
    }
    return $result
}

function Write-State {
    param([hashtable]$State)
    $dir = Split-Path -Parent $StatePath
    if ($dir -and -not (Test-Path -LiteralPath $dir)) {
        [IO.Directory]::CreateDirectory($dir) | Out-Null
    }
    $keys = @('MODE','WIDTH','SIDE','HEIGHT','LADDER_BOTTOM','ELEVATION_ANGLE','THREE_D','TYPE_OPTIONS','WIDTH_OPTIONS','SIDE_OPTIONS','HEIGHT_OPTIONS','CLOSED','PID')
    $lines = New-Object System.Collections.Generic.List[string]
    foreach ($key in $keys) {
        if ($State.ContainsKey($key)) {
            $lines.Add($key + '=' + [string]$State[$key])
        }
    }
    foreach ($key in ($State.Keys | Sort-Object)) {
        if ($keys -notcontains $key) {
            $lines.Add($key + '=' + [string]$State[$key])
        }
    }
    $tempPath = $StatePath + '.tmp.' + $PID
    [IO.File]::WriteAllLines($tempPath, $lines, (New-Object Text.UTF8Encoding($false)))
    Move-Item -LiteralPath $tempPath -Destination $StatePath -Force
}

function Split-Options {
    param([string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return @() }
    return @($Value.Split('|') | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' } | Select-Object -Unique)
}

function Add-UniqueValue {
    param([string[]]$Values, [string]$Value)
    $out = New-Object System.Collections.Generic.List[string]
    foreach ($item in $Values) {
        if (-not [string]::IsNullOrWhiteSpace($item) -and -not $out.Contains($item)) { $out.Add($item) }
    }
    if (-not [string]::IsNullOrWhiteSpace($Value) -and -not $out.Contains($Value)) { $out.Add($Value) }
    return @($out)
}

$state = Read-State $StatePath
if ([string]::IsNullOrWhiteSpace([string]$state['ELEVATION_ANGLE'])) {
    $state['ELEVATION_ANGLE'] = '45'
}
if ([string]::IsNullOrWhiteSpace([string]$state['THREE_D'])) {
    $state['THREE_D'] = '1'
}
$state['CLOSED'] = '0'
$state['PID'] = [string]$PID
Write-State $state

$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="DT Tava Paneli" Width="500" Height="500"
        ResizeMode="NoResize" WindowStartupLocation="Manual" Topmost="True"
        Background="#F3F4F6" FontFamily="Segoe UI" FontSize="13">
  <Grid Margin="16">
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="*"/>
      <RowDefinition Height="Auto"/>
    </Grid.RowDefinitions>
    <Grid.ColumnDefinitions>
      <ColumnDefinition Width="145"/>
      <ColumnDefinition Width="*"/>
    </Grid.ColumnDefinitions>

    <TextBlock Grid.Row="0" Grid.ColumnSpan="2" Text="Tava ayarlarini secip Uygula'ya basin." Margin="0,0,0,14" Foreground="#374151"/>
    <TextBlock Grid.Row="1" Grid.Column="0" Text="Tava Tipi" VerticalAlignment="Center" Margin="0,0,10,10"/>
    <ComboBox x:Name="ModeBox" Grid.Row="1" Grid.Column="1" Height="30" Margin="0,0,0,10"/>
    <TextBlock Grid.Row="2" Grid.Column="0" Text="Genislik" VerticalAlignment="Center" Margin="0,0,10,10"/>
    <ComboBox x:Name="WidthBox" Grid.Row="2" Grid.Column="1" Height="30" Margin="0,0,0,10"/>
    <TextBlock Grid.Row="3" Grid.Column="0" Text="Yanak Yuksekligi" VerticalAlignment="Center" Margin="0,0,10,10"/>
    <ComboBox x:Name="SideBox" Grid.Row="3" Grid.Column="1" Height="30" Margin="0,0,0,10"/>
    <TextBlock Grid.Row="4" Grid.Column="0" Text="Tava Yuksekligi" VerticalAlignment="Center" Margin="0,0,10,10"/>
    <ComboBox x:Name="HeightBox" Grid.Row="4" Grid.Column="1" Height="30" Margin="0,0,0,10" IsEditable="True" IsTextSearchEnabled="True"/>
    <TextBlock Grid.Row="5" Grid.Column="0" Text="Merdiven Alt Yuksekligi" VerticalAlignment="Center" Margin="0,0,10,10"/>
    <TextBox x:Name="LadderBottomBox" Grid.Row="5" Grid.Column="1" Height="30" Margin="0,0,0,10" Padding="6,3"/>
    <TextBlock Grid.Row="6" Grid.Column="0" Text="Elevation Esik Acisi" VerticalAlignment="Center" Margin="0,0,10,10"/>
    <TextBox x:Name="ElevationAngleBox" Grid.Row="6" Grid.Column="1" Height="30" Margin="0,0,0,10" Padding="6,3"/>
    <TextBlock Grid.Row="7" Grid.Column="0" Text="Gorunum" VerticalAlignment="Center" Margin="0,0,10,10"/>
    <CheckBox x:Name="ThreeDBox" Grid.Row="7" Grid.Column="1" Content="3D (Tum Cizim)" VerticalAlignment="Center" Margin="0,0,0,10"/>
    <TextBlock x:Name="StatusText" Grid.Row="8" Grid.ColumnSpan="2" Text="Hazir" Foreground="#166534" VerticalAlignment="Top" Margin="0,4,0,8" TextWrapping="Wrap"/>
    <StackPanel Grid.Row="9" Grid.ColumnSpan="2" Orientation="Horizontal" HorizontalAlignment="Right">
      <Button x:Name="LadderButton" Content="Merdiven" Width="100" Height="34" Margin="0,0,8,0"/>
      <Button x:Name="MergeButton" Content="Birlestir" Width="100" Height="34" Margin="0,0,8,0"/>
      <Button x:Name="ApplyButton" Content="Uygula" Width="100" Height="34" Margin="0,0,8,0" IsDefault="True"/>
      <Button x:Name="CloseButton" Content="Kapat" Width="90" Height="34" IsCancel="True"/>
    </StackPanel>
  </Grid>
</Window>
'@

$reader = New-Object System.Xml.XmlNodeReader([xml]$xaml)
$window = [Windows.Markup.XamlReader]::Load($reader)
$modeBox = $window.FindName('ModeBox')
$widthBox = $window.FindName('WidthBox')
$sideBox = $window.FindName('SideBox')
$heightBox = $window.FindName('HeightBox')
$ladderBottomBox = $window.FindName('LadderBottomBox')
$elevationAngleBox = $window.FindName('ElevationAngleBox')
$threeDBox = $window.FindName('ThreeDBox')
$statusText = $window.FindName('StatusText')
$ladderButton = $window.FindName('LadderButton')
$mergeButton = $window.FindName('MergeButton')
$applyButton = $window.FindName('ApplyButton')
$closeButton = $window.FindName('CloseButton')
$script:suppressThreeDChange = $false

$script:lastTypeOptionsKey = ''
function Sync-TypeOptions {
    param([hashtable]$Current)
    $options = @(Split-Options $Current['TYPE_OPTIONS'])
    if ($options.Count -eq 0) { $options = @('KA','ZA') }
    $key = [string]::Join('|', $options)
    if ($key -eq $script:lastTypeOptionsKey) { return }
    $preferred = [string]$modeBox.SelectedItem
    $stateMode = [string]$Current['MODE']
    if ([string]::IsNullOrWhiteSpace($preferred)) { $preferred = $stateMode }
    $modeBox.Items.Clear()
    foreach ($item in $options) { [void]$modeBox.Items.Add($item) }
    if ($options -contains $preferred) { $modeBox.SelectedItem = $preferred }
    elseif ($options -contains $stateMode) { $modeBox.SelectedItem = $stateMode }
    elseif ($modeBox.Items.Count -gt 0) { $modeBox.SelectedIndex = 0 }
    $script:lastTypeOptionsKey = $key
}
Sync-TypeOptions $state

$widthOptions = Split-Options $state['WIDTH_OPTIONS']
if ($widthOptions.Count -eq 0) { $widthOptions = @('10','20','30','40','50') }
foreach ($item in $widthOptions) {
    $entry = New-Object Windows.Controls.ComboBoxItem
    $entry.Content = ([double]$item * 10).ToString('0') + ' mm'
    $entry.Tag = $item
    [void]$widthBox.Items.Add($entry)
    if ($item -eq $state['WIDTH']) { $widthBox.SelectedItem = $entry }
}
if ($null -eq $widthBox.SelectedItem -and $widthBox.Items.Count -gt 0) { $widthBox.SelectedIndex = 0 }

$sideOptions = Split-Options $state['SIDE_OPTIONS']
if ($sideOptions.Count -eq 0) { $sideOptions = @('40','50') }
foreach ($item in $sideOptions) {
    $entry = New-Object Windows.Controls.ComboBoxItem
    $entry.Content = $item + ' mm'
    $entry.Tag = $item
    [void]$sideBox.Items.Add($entry)
    if ($item -eq $state['SIDE']) { $sideBox.SelectedItem = $entry }
}
if ($null -eq $sideBox.SelectedItem -and $sideBox.Items.Count -gt 0) { $sideBox.SelectedIndex = 0 }

$heightOptions = Split-Options $state['HEIGHT_OPTIONS']
foreach ($item in $heightOptions) { [void]$heightBox.Items.Add($item) }
$heightBox.Text = [string]$state['HEIGHT']
$ladderBottomBox.Text = [string]$state['LADDER_BOTTOM']
$elevationAngleBox.Text = $(if ([string]::IsNullOrWhiteSpace([string]$state['ELEVATION_ANGLE'])) { '45' } else { [string]$state['ELEVATION_ANGLE'] })
$threeDBox.IsChecked = ([string]$state['THREE_D'] -ne '0')

function Set-ModeValue {
    param([string]$Value)
    $modeBox.SelectedIndex = -1
    if (-not [string]::IsNullOrWhiteSpace($Value)) {
        foreach ($item in $modeBox.Items) {
            if ([string]$item -eq $Value) {
                $modeBox.SelectedItem = $item
                break
            }
        }
    }
}

function Set-TaggedValue {
    param([Windows.Controls.ComboBox]$Box, [string]$Value)
    $Box.SelectedIndex = -1
    if (-not [string]::IsNullOrWhiteSpace($Value)) {
        foreach ($item in $Box.Items) {
            if ([string]$item.Tag -eq $Value) {
                $Box.SelectedItem = $item
                break
            }
        }
    }
}

function Set-PanelValues {
    param([hashtable]$PanelState, [string]$Prefix)
    Set-ModeValue ([string]$PanelState[$Prefix + 'MODE'])
    Set-TaggedValue $widthBox ([string]$PanelState[$Prefix + 'WIDTH'])
    Set-TaggedValue $sideBox ([string]$PanelState[$Prefix + 'SIDE'])
    $heightBox.Text = [string]$PanelState[$Prefix + 'HEIGHT']
    $ladderBottomBox.Text = [string]$PanelState[$Prefix + 'LADDER_BOTTOM']
    $threeDValue = [string]$PanelState['THREE_D']
    $script:suppressThreeDChange = $true
    try {
        $threeDBox.IsThreeState = $false
        $threeDBox.IsChecked = ($threeDValue -ne '0')
    } finally {
        $script:suppressThreeDChange = $false
    }
}

function Test-LadderElevationPair {
    param([double]$Top, [double]$Bottom)
    $same = [Math]::Abs($Top - $Bottom) -lt 0.000001
    $bothZero = ([Math]::Abs($Top) -lt 0.000001 -and
                 [Math]::Abs($Bottom) -lt 0.000001)
    return (-not $same -or $bothZero)
}

$positionDir = Join-Path ([Environment]::GetFolderPath('ApplicationData')) 'DEG'
$positionPath = Join-Path $positionDir 'dt_tava_palette_position.txt'
if (Test-Path -LiteralPath $positionPath) {
    $position = [IO.File]::ReadAllLines($positionPath)
    if ($position.Count -ge 2) {
        $left = 0.0
        $top = 0.0
        if ([double]::TryParse($position[0], [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$left) -and
            [double]::TryParse($position[1], [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$top)) {
            $window.Left = $left
            $window.Top = $top
        }
    }
} else {
    $window.Left = [System.Windows.SystemParameters]::WorkArea.Right - $window.Width - 30
    $window.Top = [System.Windows.SystemParameters]::WorkArea.Top + 90
}

Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class DEGWindowFocus {
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool BringWindowToTop(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool ShowWindowAsync(IntPtr hWnd, int nCmdShow);
}
'@

function Get-CadWindowHandle {
    if ($HostHwnd -gt 0) { return [IntPtr]$HostHwnd }
    if ($HostPid -gt 0) {
        try {
            $hostProcess = Get-Process -Id $HostPid -ErrorAction Stop
            if ($hostProcess.MainWindowHandle -ne 0) { return $hostProcess.MainWindowHandle }
        } catch { }
    }
    foreach ($processName in @('acad','gcad','gstarcad')) {
        try {
            $candidate = Get-Process -Name $processName -ErrorAction Stop |
                Where-Object { $_.MainWindowHandle -ne 0 } |
                Select-Object -First 1
            if ($null -ne $candidate) { return $candidate.MainWindowHandle }
        } catch { }
    }
    return [IntPtr]::Zero
}

function Focus-CadWindow {
    $handle = Get-CadWindowHandle
    if ($handle -eq [IntPtr]::Zero) { return $false }
    [void][DEGWindowFocus]::ShowWindowAsync($handle, 9)
    [void][DEGWindowFocus]::BringWindowToTop($handle)
    return [DEGWindowFocus]::SetForegroundWindow($handle)
}

function Send-CadCommand {
    param([string]$CadCommand, [switch]$CancelCurrent, [switch]$Silent)
    foreach ($progId in @('AutoCAD.Application','GstarCAD.Application','GCAD.Application')) {
        $app = $null
        $doc = $null
        $oldCmdEcho = $null
        $oldNoMutt = $null
        try {
            $app = [Runtime.InteropServices.Marshal]::GetActiveObject($progId)
            $appHwnd = 0L
            try { $appHwnd = [long]$app.HWND } catch { }
            if ($HostHwnd -gt 0 -and $appHwnd -gt 0 -and $appHwnd -ne $HostHwnd) {
                continue
            }
            $doc = $app.ActiveDocument
            if ($Silent) {
                try {
                    $oldCmdEcho = $doc.GetVariable('CMDECHO')
                    $doc.SetVariable('CMDECHO', 0)
                } catch { }
                try {
                    $oldNoMutt = $doc.GetVariable('NOMUTT')
                    $doc.SetVariable('NOMUTT', 1)
                } catch { }
            }
            $prefix = if ($CancelCurrent) { ([string][char]27) + ([string][char]27) } else { '' }
            $doc.SendCommand($prefix + $CadCommand + "`r")
            return $true
        } catch {
        } finally {
            if ($null -ne $doc -and $Silent) {
                if ($null -ne $oldNoMutt) {
                    try { $doc.SetVariable('NOMUTT', $oldNoMutt) } catch { }
                }
                if ($null -ne $oldCmdEcho) {
                    try { $doc.SetVariable('CMDECHO', $oldCmdEcho) } catch { }
                }
            }
            if ($null -ne $doc) { try { [void][Runtime.InteropServices.Marshal]::ReleaseComObject($doc) } catch { } }
            if ($null -ne $app) { try { [void][Runtime.InteropServices.Marshal]::ReleaseComObject($app) } catch { } }
        }
    }
    if (Focus-CadWindow) {
        Start-Sleep -Milliseconds 150
        try {
            $keys = if ($CancelCurrent) { '{ESC}{ESC}' + $CadCommand + '{ENTER}' } else { $CadCommand + '{ENTER}' }
            [System.Windows.Forms.SendKeys]::SendWait($keys)
            return $true
        } catch { }
    }
    return $false
}

$lastPanelStateKey = ''
$lastRequestDone = ''

$pollTimer = New-Object Windows.Threading.DispatcherTimer
$pollTimer.Interval = [TimeSpan]::FromMilliseconds(300)
$pollTimer.Add_Tick({
    try {
        $current = Read-State $StatePath
        Sync-TypeOptions $current
        $context = [string]$current['CONTEXT']
        $selectionActive = ($context -eq 'SELECT' -and [string]$current['SELECTION_ACTIVE'] -eq '1')
        $stateKey = $context + '|' + [string]$current['SELECTION_ACTIVE'] + '|' + [string]$current['SELECTION_REV'] + '|' + [string]$current['THREE_D']
        if ($stateKey -ne $lastPanelStateKey) {
            if ($selectionActive) {
                Set-PanelValues $current 'SELECTION_'
                $count = [string]$current['SELECTION_COUNT']
                $statusText.Text = $(if ($count -eq '1') { '1 DT elemani secili.' } else { $count + ' DT elemani secili.' })
                $statusText.Foreground = '#166534'
                $applyButton.Content = 'Secime Uygula'
            } else {
                Set-PanelValues $current ''
                if ($context -eq 'LADDER') {
                    $statusText.Text = 'Merdiven yerlesimi aktif: noktaya tiklayin, ESC ile bitirin.'
                } elseif ($context -eq 'SELECT') {
                    $statusText.Text = 'Duzenlemek icin bir veya daha fazla tava secin.'
                } else {
                    $statusText.Text = 'Cizim ayarlari hazir.'
                }
                $statusText.Foreground = '#374151'
                $applyButton.Content = 'Uygula'
            }
            $ladderButton.Content = $(if ($context -eq 'LADDER') { 'Merdiven Aktif' } else { 'Merdiven' })
            $ladderButton.Background = $(if ($context -eq 'LADDER') { '#F59E0B' } else { $null })
            $script:lastPanelStateKey = $stateKey
        }
        $requestDone = [string]$current['REQUEST_DONE']
        if (-not [string]::IsNullOrWhiteSpace($requestDone) -and $requestDone -ne $lastRequestDone) {
            $script:lastRequestDone = $requestDone
            if (-not [string]::IsNullOrWhiteSpace([string]$current['STATUS'])) {
                $statusText.Text = [string]$current['STATUS']
                $statusText.Foreground = $(if ([string]$current['STATUS'] -match 'Gecersiz|bulunamadi|hata') { '#B91C1C' } else { '#166534' })
            }
        }
    } catch { }
})
$pollTimer.Start()

function Request-GlobalThreeD {
    if ($script:suppressThreeDChange) { return }
    $threeD = if ($threeDBox.IsChecked -eq $true) { '1' } else { '0' }
    $current = Read-State $StatePath
    $requestId = [string][DateTime]::UtcNow.Ticks
    $current['THREE_D'] = $threeD
    $current['REQUEST'] = 'GLOBAL_3D'
    $current['REQUEST_3D'] = ''
    $current['REQUEST_ID'] = $requestId
    $current['REQUEST_DONE'] = ''
    $current['STATUS'] = $(if ($threeD -eq '1') { 'Tum tavalar 3D gorunume cevriliyor...' } else { 'Tum tavalar 2D gorunume cevriliyor...' })
    $current['CLOSED'] = '0'
    $current['PID'] = [string]$PID
    Write-State $current
    $statusText.Text = $current['STATUS']
    $statusText.Foreground = '#166534'
    if (-not (Send-CadCommand 'DT_PALETTE_GLOBAL_3D' -CancelCurrent -Silent)) {
        $statusText.Text = '3D gorunum komutu CAD icinde baslatilamadi.'
        $statusText.Foreground = '#B91C1C'
        $current = Read-State $StatePath
        $current['REQUEST'] = ''
        $current['STATUS'] = $statusText.Text
        Write-State $current
    }
}

$threeDBox.Add_Checked({ Request-GlobalThreeD })
$threeDBox.Add_Unchecked({ Request-GlobalThreeD })

$mergeButton.Add_Click({
    $current = Read-State $StatePath
    $requestId = [string][DateTime]::UtcNow.Ticks
    $current['REQUEST'] = 'MERGE_WARNING'
    $current['REQUEST_ID'] = $requestId
    $current['REQUEST_DONE'] = ''
    $current['STATUS'] = 'Secili cakisma kuresindeki tavalar birlestiriliyor...'
    $current['CLOSED'] = '0'
    $current['PID'] = [string]$PID
    Write-State $current
    $statusText.Text = $current['STATUS']
    $statusText.Foreground = '#166534'
    if (-not (Send-CadCommand 'DT_PALETTE_MERGE' -Silent)) {
        $statusText.Text = 'Birlestirme komutu CAD icinde baslatilamadi.'
        $statusText.Foreground = '#B91C1C'
        $current = Read-State $StatePath
        $current['REQUEST'] = ''
        $current['STATUS'] = $statusText.Text
        Write-State $current
    }
})

$applyButton.Add_Click({
    $mode = [string]$modeBox.SelectedItem
    $width = if ($widthBox.SelectedItem) { [string]$widthBox.SelectedItem.Tag } else { '' }
    $side = if ($sideBox.SelectedItem) { [string]$sideBox.SelectedItem.Tag } else { '' }
    $height = $heightBox.Text.Trim()
    $ladderBottom = $ladderBottomBox.Text.Trim()
    $threeD = if ($threeDBox.IsChecked -eq $true) { '1' } elseif ($threeDBox.IsChecked -eq $false) { '0' } else { '' }
    $elevationAngle = $elevationAngleBox.Text.Trim()
    $elevationAngleNumber = 0.0
    $elevationAngleValid = [double]::TryParse(
        $elevationAngle.Replace(',', '.'),
        [Globalization.NumberStyles]::Float,
        [Globalization.CultureInfo]::InvariantCulture,
        [ref]$elevationAngleNumber)
    if (-not $elevationAngleValid -or $elevationAngleNumber -le 0.0 -or $elevationAngleNumber -gt 90.0) {
        $statusText.Text = 'Elevation esik acisi 0 ile 90 derece arasinda olmalidir.'
        $statusText.Foreground = '#B91C1C'
        return
    }
    $elevationAngle = $elevationAngleNumber.ToString('0.######', [Globalization.CultureInfo]::InvariantCulture)
    $current = Read-State $StatePath
    $selectionActive = ([string]$current['CONTEXT'] -eq 'SELECT' -and [string]$current['SELECTION_ACTIVE'] -eq '1')
    if ($selectionActive) {
        if ([string]::IsNullOrWhiteSpace($mode) -and [string]::IsNullOrWhiteSpace($width) -and
            [string]::IsNullOrWhiteSpace($side) -and [string]::IsNullOrWhiteSpace($height) -and
            [string]::IsNullOrWhiteSpace($ladderBottom)) {
            $statusText.Text = 'Degistirilecek en az bir deger secilmelidir.'
            $statusText.Foreground = '#B91C1C'
            return
        }
    } elseif ([string]::IsNullOrWhiteSpace($mode) -or [string]::IsNullOrWhiteSpace($width) -or [string]::IsNullOrWhiteSpace($side)) {
        $statusText.Text = 'Tip, genislik ve yanak secilmelidir.'
        $statusText.Foreground = '#B91C1C'
        return
    }
    $current['MODE'] = $mode
    $current['WIDTH'] = $width
    $current['SIDE'] = $side
    $current['HEIGHT'] = $height
    $current['LADDER_BOTTOM'] = $ladderBottom
    $current['ELEVATION_ANGLE'] = $elevationAngle
    if (-not [string]::IsNullOrWhiteSpace($threeD)) { $current['THREE_D'] = $threeD }
    $current['CLOSED'] = '0'
    $current['PID'] = [string]$PID
    $heights = Add-UniqueValue (Split-Options $current['HEIGHT_OPTIONS']) $height
    $current['HEIGHT_OPTIONS'] = ($heights -join '|')
    if ($selectionActive) {
        $requestId = [string][DateTime]::UtcNow.Ticks
        $current['REQUEST'] = 'APPLY_SELECTION'
        $current['REQUEST_3D'] = ''
        $current['REQUEST_ID'] = $requestId
        $current['REQUEST_DONE'] = ''
        $current['STATUS'] = 'Secime uygulaniyor...'
    }
    Write-State $current
    if (-not [string]::IsNullOrWhiteSpace($height) -and -not $heightBox.Items.Contains($height)) { [void]$heightBox.Items.Add($height) }
    $statusText.Text = $(if ($selectionActive) { 'Secime uygulaniyor...' } else { 'Ayarlar uygulandi. Cizime devam edebilirsiniz.' })
    $statusText.Foreground = '#166534'
    if ($selectionActive) {
        if (-not (Send-CadCommand 'DT_PALETTE_APPLY')) {
            $statusText.Text = 'CAD komutu gonderilemedi. Paleti kapatip DT ile yeniden acin.'
            $statusText.Foreground = '#B91C1C'
            $current = Read-State $StatePath
            $current['REQUEST'] = ''
            $current['STATUS'] = $statusText.Text
            Write-State $current
        }
    } else {
        [void](Focus-CadWindow)
    }
})

$ladderButton.Add_Click({
    $mode = [string]$modeBox.SelectedItem
    $width = if ($widthBox.SelectedItem) { [string]$widthBox.SelectedItem.Tag } else { '' }
    $side = if ($sideBox.SelectedItem) { [string]$sideBox.SelectedItem.Tag } else { '' }
    $height = $heightBox.Text.Trim()
    $ladderBottom = $ladderBottomBox.Text.Trim()
    $topNumber = 0.0
    $bottomNumber = 0.0
    $topValid = [double]::TryParse(
        $height.Replace(',', '.'),
        [Globalization.NumberStyles]::Float,
        [Globalization.CultureInfo]::InvariantCulture,
        [ref]$topNumber)
    $bottomValid = [double]::TryParse(
        $ladderBottom.Replace(',', '.'),
        [Globalization.NumberStyles]::Float,
        [Globalization.CultureInfo]::InvariantCulture,
        [ref]$bottomNumber)
    if ([string]::IsNullOrWhiteSpace($mode) -or [string]::IsNullOrWhiteSpace($width) -or
        [string]::IsNullOrWhiteSpace($side) -or -not $topValid -or -not $bottomValid) {
        $statusText.Text = 'Merdiven icin tip, genislik, yanak, ust ve alt yukseklik girilmelidir.'
        $statusText.Foreground = '#B91C1C'
        return
    }
    if (-not (Test-LadderElevationPair $topNumber $bottomNumber)) {
        $statusText.Text = 'Merdiven ust ve alt yukseklikleri farkli olmalidir.'
        $statusText.Foreground = '#B91C1C'
        return
    }
    $current = Read-State $StatePath
    $current['MODE'] = $mode
    $current['WIDTH'] = $width
    $current['SIDE'] = $side
    $current['HEIGHT'] = $height
    $current['LADDER_BOTTOM'] = $ladderBottom
    $current['CONTEXT'] = 'LADDER'
    $current['REQUEST'] = 'LADDER'
    $current['REQUEST_ID'] = [string][DateTime]::UtcNow.Ticks
    $current['REQUEST_DONE'] = ''
    $current['STATUS'] = 'Merdiven yerlesimi aktif.'
    $current['CLOSED'] = '0'
    $current['PID'] = [string]$PID
    $heights = Add-UniqueValue (Split-Options $current['HEIGHT_OPTIONS']) $height
    $current['HEIGHT_OPTIONS'] = ($heights -join '|')
    Write-State $current
    $statusText.Text = 'Merdiven yerlesimi aktif: noktaya tiklayin, ESC ile bitirin.'
    $statusText.Foreground = '#166534'
    $ladderButton.Content = 'Merdiven Aktif'
    $ladderButton.Background = '#F59E0B'
    if (-not (Send-CadCommand 'DT_PALETTE_LADDER' -CancelCurrent -Silent)) {
        $statusText.Text = 'Merdiven komutu CAD icinde baslatilamadi.'
        $statusText.Foreground = '#B91C1C'
        $current = Read-State $StatePath
        $current['CONTEXT'] = 'SELECT'
        $current['REQUEST'] = ''
        $current['STATUS'] = $statusText.Text
        Write-State $current
    }
})

$closeButton.Add_Click({ $window.Close() })

$window.Add_Closing({
    $pollTimer.Stop()
    if (-not (Test-Path -LiteralPath $positionDir)) { [IO.Directory]::CreateDirectory($positionDir) | Out-Null }
    [IO.File]::WriteAllLines($positionPath, @(
        $window.Left.ToString([Globalization.CultureInfo]::InvariantCulture),
        $window.Top.ToString([Globalization.CultureInfo]::InvariantCulture)
    ))
    $current = Read-State $StatePath
    $current['CLOSED'] = '1'
    $current['PID'] = [string]$PID
    Write-State $current
})

if ($SelfTest) {
    if (Test-Path -LiteralPath $LogPath) { Remove-Item -LiteralPath $LogPath -Force }
    $zeroPair = if (Test-LadderElevationPair 0.0 0.0) { 'OK' } else { 'FAIL' }
    $sameNonZero = if (-not (Test-LadderElevationPair 250.0 250.0)) { 'OK' } else { 'FAIL' }
    Write-Output ('SELFTEST=OK;MODE=' + $state['MODE'] + ';WIDTH=' + $state['WIDTH'] + ';LADDER_BOTTOM=' + $state['LADDER_BOTTOM'] + ';ELEVATION_ANGLE=' + $state['ELEVATION_ANGLE'] + ';ZERO_PAIR=' + $zeroPair + ';SAME_NONZERO=' + $sameNonZero + ';WINDOW=OK')
    $mutex.ReleaseMutex()
    $mutex.Dispose()
    exit 0
}

try {
    [void]$window.ShowDialog()
} finally {
    try { $mutex.ReleaseMutex() } catch { }
    $mutex.Dispose()
}
