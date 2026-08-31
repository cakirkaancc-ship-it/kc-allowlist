param(
    [Parameter(Mandatory = $true)]
    [string]$StatePath,
    [string]$PasswordUrl = '',
    [string]$UpdateManifestUrl = '',
    [string]$TargetDirectory = '',
    [string]$UpdateVersionPath = '',
    [ValidateSet('Settings','Message','License','Update')]
    [string]$Mode = 'Settings',
    [int]$HostPid = 0,
    [long]$HostHwnd = 0,
    [switch]$ElevatedUpdate,
    [switch]$SelfTest
)

$ErrorActionPreference = 'Stop'
$LogPath = $StatePath + '.log'
trap {
    try { [IO.File]::WriteAllText($LogPath, ($_ | Out-String), (New-Object Text.UTF8Encoding($false))) } catch { }
    exit 1
}

function Write-UpdateResult {
    param([string]$Value)
    [IO.File]::WriteAllText($StatePath + '.result', $Value, (New-Object Text.UTF8Encoding($false)))
}

function Quote-ProcessArgument {
    param([string]$Value)
    return '"' + $Value.Replace('"', '\"') + '"'
}

function Save-RemoteUpdateFile {
    param(
        [string]$Url,
        [string]$Destination
    )

    $uri = [Uri]$Url
    if ($uri.IsFile) {
        Copy-Item -LiteralPath $uri.LocalPath -Destination $Destination -Force
        return
    }

    $separator = if ($Url.Contains('?')) { '&' } else { '?' }
    $fetchUrl = $Url + $separator + 'kc_nonce=' + [DateTime]::UtcNow.Ticks
    $response = $null
    $inputStream = $null
    $outputStream = $null
    try {
        [Net.ServicePointManager]::SecurityProtocol =
            [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        $request = [Net.HttpWebRequest]::Create($fetchUrl)
        $request.Method = 'GET'
        $request.Timeout = 15000
        $request.ReadWriteTimeout = 15000
        $request.UserAgent = 'DEG-Auto-Update'
        $request.CachePolicy = New-Object Net.Cache.RequestCachePolicy([Net.Cache.RequestCacheLevel]::NoCacheNoStore)
        $response = $request.GetResponse()
        $inputStream = $response.GetResponseStream()
        $outputStream = [IO.File]::Open($Destination, [IO.FileMode]::Create, [IO.FileAccess]::Write, [IO.FileShare]::None)
        $inputStream.CopyTo($outputStream)
    } finally {
        if ($null -ne $outputStream) { $outputStream.Dispose() }
        if ($null -ne $inputStream) { $inputStream.Dispose() }
        if ($null -ne $response) { $response.Dispose() }
    }
}

function Read-UpdateManifest {
    param([string]$Path)

    $values = @{}
    $content = [IO.File]::ReadAllText($Path, [Text.Encoding]::UTF8)
    foreach ($line in ($content -split "`r?`n")) {
        $trimmed = $line.Trim().TrimStart([char]0xFEFF)
        if ([string]::IsNullOrEmpty($trimmed) -or $trimmed.StartsWith('#') -or $trimmed.StartsWith(';')) { continue }
        $colonIndex = $trimmed.IndexOf(':')
        if ($colonIndex -lt 1) { continue }
        $key = $trimmed.Substring(0, $colonIndex).Trim()
        $value = $trimmed.Substring($colonIndex + 1).Trim()
        if (-not [string]::IsNullOrEmpty($key)) { $values[$key] = $value }
    }
    return $values
}

function Convert-ToUpdateDate {
    param([string]$Value)

    $date = [DateTimeOffset]::MinValue
    $ok = [DateTimeOffset]::TryParse(
        $Value,
        [Globalization.CultureInfo]::InvariantCulture,
        [Globalization.DateTimeStyles]::AllowWhiteSpaces,
        [ref]$date)
    if ($ok) { return $date }
    return $null
}

function Get-UpdateFileNames {
    return @('DG_DO_R05.vlx', 'DG_DT_TAVA_PALET.ps1', 'DG_WINDOWS_UI.ps1')
}

function Test-UpdateHashesValid {
    param([hashtable]$Manifest)

    foreach ($name in (Get-UpdateFileNames)) {
        $hash = [string]$Manifest[$name]
        if ($hash -notmatch '^[0-9A-Fa-f]{64}$') { return $false }
    }
    return $true
}

function Test-InstalledFilesMatchManifest {
    param(
        [string]$Directory,
        [hashtable]$Manifest
    )

    foreach ($name in (Get-UpdateFileNames)) {
        $path = Join-Path $Directory $name
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $false }
        if ((Get-FileHash -Algorithm SHA256 -LiteralPath $path).Hash -cne ([string]$Manifest[$name]).ToUpperInvariant()) { return $false }
    }
    return $true
}

function Test-UpdateTargetWritable {
    param([string]$Directory)

    $probe = Join-Path $Directory ('.deg_update_write_' + [guid]::NewGuid().ToString('N') + '.tmp')
    try {
        [IO.File]::WriteAllText($probe, 'DEG', [Text.Encoding]::ASCII)
        Remove-Item -LiteralPath $probe -Force
        return $true
    } catch {
        if (Test-Path -LiteralPath $probe) { Remove-Item -LiteralPath $probe -Force -ErrorAction SilentlyContinue }
        return $false
    }
}

function Write-UpdateVersion {
    param(
        [string]$Path,
        [DateTimeOffset]$Date
    )

    $directory = Split-Path -Parent $Path
    if (-not [string]::IsNullOrWhiteSpace($directory)) {
        [void](New-Item -ItemType Directory -Path $directory -Force)
    }
    [IO.File]::WriteAllText($Path, $Date.ToUniversalTime().ToString('o'), (New-Object Text.UTF8Encoding($false)))
}

function Install-StagedUpdate {
    param(
        [string]$StageDirectory,
        [string]$Directory
    )

    $nonce = [guid]::NewGuid().ToString('N')
    $records = @()
    $success = $false
    try {
        foreach ($name in (Get-UpdateFileNames)) {
            $target = Join-Path $Directory $name
            $incoming = $target + '.kcnew.' + $nonce
            $backup = $target + '.kcbak.' + $nonce
            $hadOriginal = Test-Path -LiteralPath $target -PathType Leaf
            Copy-Item -LiteralPath (Join-Path $StageDirectory $name) -Destination $incoming -Force
            if ($hadOriginal) { Copy-Item -LiteralPath $target -Destination $backup -Force }
            $records += [pscustomobject]@{
                Target = $target
                Incoming = $incoming
                Backup = $backup
                HadOriginal = $hadOriginal
                Installed = $false
            }
        }

        foreach ($record in $records) {
            $record.Installed = $true
            if ($record.HadOriginal) {
                try {
                    [IO.File]::Replace($record.Incoming, $record.Target, $null, $true)
                } catch {
                    [IO.File]::Copy($record.Incoming, $record.Target, $true)
                    Remove-Item -LiteralPath $record.Incoming -Force -ErrorAction SilentlyContinue
                }
            } else {
                Move-Item -LiteralPath $record.Incoming -Destination $record.Target -Force
            }
        }
        $success = $true
    } catch {
        $installError = $_
        for ($index = $records.Count - 1; $index -ge 0; $index--) {
            $record = $records[$index]
            if ($record.Installed) {
                try {
                    if ($record.HadOriginal -and (Test-Path -LiteralPath $record.Backup)) {
                        Copy-Item -LiteralPath $record.Backup -Destination $record.Target -Force
                    } elseif (-not $record.HadOriginal -and (Test-Path -LiteralPath $record.Target)) {
                        Remove-Item -LiteralPath $record.Target -Force -ErrorAction SilentlyContinue
                    }
                } catch { }
            }
        }
        throw $installError
    } finally {
        foreach ($record in $records) {
            if (Test-Path -LiteralPath $record.Incoming) { Remove-Item -LiteralPath $record.Incoming -Force -ErrorAction SilentlyContinue }
            if ($success -and (Test-Path -LiteralPath $record.Backup)) { Remove-Item -LiteralPath $record.Backup -Force -ErrorAction SilentlyContinue }
        }
    }
}

function Invoke-ElevatedUpdate {
    $arguments =
        '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File ' + (Quote-ProcessArgument $PSCommandPath) +
        ' -Mode Update -StatePath ' + (Quote-ProcessArgument $StatePath) +
        ' -UpdateManifestUrl ' + (Quote-ProcessArgument $UpdateManifestUrl) +
        ' -TargetDirectory ' + (Quote-ProcessArgument $TargetDirectory) +
        ' -UpdateVersionPath ' + (Quote-ProcessArgument $UpdateVersionPath) +
        ' -ElevatedUpdate'
    $process = Start-Process -FilePath 'powershell.exe' -ArgumentList $arguments -Verb RunAs -Wait -PassThru -WindowStyle Hidden
    if ($process.ExitCode -ne 0 -and -not (Test-Path -LiteralPath ($StatePath + '.result'))) {
        Write-UpdateResult 'FAILED|Yonetici yetkisi alinamadi.'
    }
}

function Invoke-DegUpdate {
    $resultPath = $StatePath + '.result'
    if (-not $ElevatedUpdate -and (Test-Path -LiteralPath $resultPath)) {
        Remove-Item -LiteralPath $resultPath -Force -ErrorAction SilentlyContinue
    }

    if ([string]::IsNullOrWhiteSpace($UpdateManifestUrl) -or
        [string]::IsNullOrWhiteSpace($TargetDirectory) -or
        [string]::IsNullOrWhiteSpace($UpdateVersionPath) -or
        -not (Test-Path -LiteralPath $TargetDirectory -PathType Container)) {
        Write-UpdateResult 'FAILED|Guncelleme yolu gecersiz.'
        return
    }

    if (-not (Test-UpdateTargetWritable -Directory $TargetDirectory)) {
        if (-not $ElevatedUpdate) {
            try { Invoke-ElevatedUpdate } catch { Write-UpdateResult 'FAILED|Yonetici izni reddedildi.' }
        } else {
            Write-UpdateResult 'FAILED|Hedef klasore yazilamadi.'
        }
        return
    }

    $stageDirectory = Join-Path $env:TEMP ('DEG_update_' + [guid]::NewGuid().ToString('N'))
    try {
        [void](New-Item -ItemType Directory -Path $stageDirectory -Force)
        $manifestPath = Join-Path $stageDirectory 'guncelleme.txt'
        Save-RemoteUpdateFile -Url $UpdateManifestUrl -Destination $manifestPath
        $manifest = Read-UpdateManifest -Path $manifestPath
        $remoteDate = Convert-ToUpdateDate -Value ([string]$manifest['SURUM_TARIHI'])
        if ($null -eq $remoteDate -or -not (Test-UpdateHashesValid -Manifest $manifest)) {
            throw 'Manifest tarihi veya SHA256 degerleri gecersiz.'
        }

        $localDate = $null
        if (Test-Path -LiteralPath $UpdateVersionPath -PathType Leaf) {
            $localDate = Convert-ToUpdateDate -Value ([IO.File]::ReadAllText($UpdateVersionPath).Trim())
        }
        if ($null -ne $localDate -and $remoteDate -le $localDate) {
            Write-UpdateResult ('CURRENT|' + $remoteDate.ToUniversalTime().ToString('o'))
            return
        }

        if ($null -eq $localDate -and (Test-InstalledFilesMatchManifest -Directory $TargetDirectory -Manifest $manifest)) {
            Write-UpdateVersion -Path $UpdateVersionPath -Date $remoteDate
            Write-UpdateResult ('CURRENT|' + $remoteDate.ToUniversalTime().ToString('o'))
            return
        }

        $manifestUri = [Uri]$UpdateManifestUrl
        foreach ($name in (Get-UpdateFileNames)) {
            $fileUrl = ([Uri]::new($manifestUri, $name)).AbsoluteUri
            $destination = Join-Path $stageDirectory $name
            Save-RemoteUpdateFile -Url $fileUrl -Destination $destination
            $actualHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $destination).Hash
            if ($actualHash -cne ([string]$manifest[$name]).ToUpperInvariant()) {
                throw ($name + ' SHA256 dogrulamasi basarisiz.')
            }
        }

        Install-StagedUpdate -StageDirectory $stageDirectory -Directory $TargetDirectory
        Write-UpdateVersion -Path $UpdateVersionPath -Date $remoteDate
        Write-UpdateResult ('UPDATED|' + $remoteDate.ToUniversalTime().ToString('o'))
    } catch {
        try { [IO.File]::WriteAllText($LogPath, ($_ | Out-String), (New-Object Text.UTF8Encoding($false))) } catch { }
        Write-UpdateResult 'FAILED|Guncelleme tamamlanamadi.'
    } finally {
        if (Test-Path -LiteralPath $stageDirectory) {
            Remove-Item -LiteralPath $stageDirectory -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

if ($Mode -eq 'Update') {
    Invoke-DegUpdate
    exit 0
}

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName System.Windows.Forms

function Read-SettingRows {
    param([string]$Path)
    $rows = @()
    $index = 0
    if (-not (Test-Path -LiteralPath $Path)) { return $rows }
    foreach ($line in [IO.File]::ReadAllLines($Path, [Text.Encoding]::Default)) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        $parts = $line.Split("`t")
        if ($parts.Count -lt 8 -or $parts[0] -eq 'META') { continue }
        $rows += [pscustomobject]@{
            Kind = $parts[0]
            Key = $parts[1]
            Group = $parts[2]
            Label = $parts[3]
            Value = $parts[4]
            Default = $parts[5]
            Type = $parts[6]
            Options = $parts[7]
            Original = $parts[4]
            EditMode = ''
            Control = $null
            Index = $index
        }
        $index++
    }
    return $rows
}

function Read-Status {
    param([string]$Path)
    $result = @{}
    if (Test-Path -LiteralPath $Path) {
        foreach ($line in [IO.File]::ReadAllLines($Path, [Text.Encoding]::Default)) {
            $pos = $line.IndexOf('=')
            if ($pos -gt 0) {
                $result[$line.Substring(0, $pos).Trim().ToUpperInvariant()] = $line.Substring($pos + 1)
            }
        }
    }
    return $result
}

function Write-AtomicLines {
    param([string]$Path, [string[]]$Lines)
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) {
        [IO.Directory]::CreateDirectory($dir) | Out-Null
    }
    $lastError = $null
    for ($attempt = 1; $attempt -le 5; $attempt++) {
        $temp = $Path + '.tmp.' + $PID + '.' + $attempt
        try {
            [IO.File]::WriteAllLines($temp, $Lines, [Text.Encoding]::Default)
            Move-Item -LiteralPath $temp -Destination $Path -Force
            if (Test-Path -LiteralPath $Path) { return }
            throw 'Dosya hedefe tasinamadi.'
        } catch {
            $lastError = $_
            Start-Sleep -Milliseconds 120
        } finally {
            if (Test-Path -LiteralPath $temp) {
                Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue
            }
        }
    }
    try {
        [IO.File]::WriteAllLines($Path, $Lines, [Text.Encoding]::Default)
        return
    } catch {
        $lastError = $_
    }
    throw [InvalidOperationException]::new(('Kayit istek dosyasi yazilamadi: ' + $Path), $lastError.Exception)
}

Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class DEGWindowsUiFocus {
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool BringWindowToTop(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool ShowWindowAsync(IntPtr hWnd, int nCmdShow);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint processId);
}
'@

$initialForegroundHwnd = [long][DEGWindowsUiFocus]::GetForegroundWindow()
$script:HostCadProcessName = ''
if ($HostPid -le 0 -and -not $SelfTest) {
    try {
        $parentPid = [int](Get-CimInstance Win32_Process -Filter ('ProcessId=' + $PID)).ParentProcessId
        $parent = Get-Process -Id $parentPid -ErrorAction Stop
        if ($parent.ProcessName -match '^(acad|gcad|gstarcad)$') {
            $HostPid = $parentPid
        }
    } catch { }
}
if ($HostPid -gt 0) {
    try {
        $hostProcess = Get-Process -Id $HostPid -ErrorAction Stop
        $script:HostCadProcessName = [string]$hostProcess.ProcessName
        if ($HostHwnd -le 0 -and $hostProcess.MainWindowHandle -ne 0) {
            $HostHwnd = [long]$hostProcess.MainWindowHandle
        }
    } catch { }
}
if ($HostHwnd -le 0 -and -not $SelfTest -and $initialForegroundHwnd -gt 0) {
    $HostHwnd = $initialForegroundHwnd
}

function Get-CadWindowHandle {
    if ($HostHwnd -gt 0) { return [IntPtr]$HostHwnd }
    if ($HostPid -gt 0) {
        try {
            $process = Get-Process -Id $HostPid -ErrorAction Stop
            if ($process.MainWindowHandle -ne 0) { return $process.MainWindowHandle }
        } catch { }
    }
    foreach ($name in @('acad','gcad','gstarcad')) {
        try {
            $candidate = Get-Process -Name $name -ErrorAction Stop |
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
    [void][DEGWindowsUiFocus]::ShowWindowAsync($handle, 9)
    [void][DEGWindowsUiFocus]::BringWindowToTop($handle)
    return [DEGWindowsUiFocus]::SetForegroundWindow($handle)
}

function Get-CadProgIds {
    $ids = New-Object System.Collections.Generic.List[string]
    if ($script:HostCadProcessName -match '^(gcad|gstarcad)$') {
        foreach ($id in @('GstarCAD.Application','GCAD.Application','AutoCAD.Application')) { $ids.Add($id) }
    } else {
        foreach ($id in @('AutoCAD.Application','GstarCAD.Application','GCAD.Application')) { $ids.Add($id) }
    }
    foreach ($pattern in @('AutoCAD.Application*','GstarCAD.Application*','GCAD.Application*')) {
        try {
            foreach ($key in @(Get-ChildItem -Path ('Registry::HKEY_CLASSES_ROOT\' + $pattern) -ErrorAction SilentlyContinue)) {
                $progId = [string]$key.PSChildName
                if (-not [string]::IsNullOrWhiteSpace($progId) -and -not $ids.Contains($progId)) {
                    $ids.Add($progId)
                }
            }
        } catch { }
    }
    return @($ids)
}

function Send-CadCommand {
    param([string]$CadCommand)
    foreach ($progId in @(Get-CadProgIds)) {
        $app = $null
        $doc = $null
        try {
            $app = [Runtime.InteropServices.Marshal]::GetActiveObject($progId)
            $appHwnd = 0L
            try { $appHwnd = [long]$app.HWND } catch { }
            if ($HostHwnd -gt 0 -and $appHwnd -gt 0 -and $appHwnd -ne $HostHwnd) { continue }
            if ($HostPid -gt 0 -and $appHwnd -gt 0) {
                [uint32]$appPid = 0
                [void][DEGWindowsUiFocus]::GetWindowThreadProcessId([IntPtr]$appHwnd, [ref]$appPid)
                if ($appPid -gt 0 -and $appPid -ne $HostPid) { continue }
            }
            $doc = $app.ActiveDocument
            $doc.SendCommand($CadCommand + "`r")
            return $true
        } catch {
        } finally {
            if ($null -ne $doc) { try { [void][Runtime.InteropServices.Marshal]::ReleaseComObject($doc) } catch { } }
            if ($null -ne $app) { try { [void][Runtime.InteropServices.Marshal]::ReleaseComObject($app) } catch { } }
        }
    }
    if (Focus-CadWindow) {
        Start-Sleep -Milliseconds 250
        $previousClipboard = $null
        try {
            try { $previousClipboard = [Windows.Clipboard]::GetDataObject() } catch { }
            [Windows.Clipboard]::SetText($CadCommand)
            [System.Windows.Forms.SendKeys]::SendWait('^v')
            [System.Windows.Forms.SendKeys]::SendWait('{ENTER}')
            return $true
        } catch {
        } finally {
            if ($null -ne $previousClipboard) {
                try { [Windows.Clipboard]::SetDataObject($previousClipboard, $true) } catch { }
            }
        }
    }
    return $false
}

function Show-MessageWindow {
    $lines = if (Test-Path -LiteralPath $StatePath) { [IO.File]::ReadAllLines($StatePath, [Text.Encoding]::Default) } else { @('DEG','Mesaj okunamadi.') }
    $title = if ($lines.Count -gt 0 -and -not [string]::IsNullOrWhiteSpace($lines[0])) { $lines[0] } else { 'DEG' }
    $message = if ($lines.Count -gt 1) { [string]::Join([Environment]::NewLine, $lines[1..($lines.Count - 1)]) } else { '' }
    $xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Width="620" MinWidth="420" MaxWidth="920"
        Height="460" MinHeight="240" MaxHeight="760"
        WindowStartupLocation="CenterScreen" Topmost="True"
        Background="#F3F4F6" FontFamily="Segoe UI" FontSize="13">
  <Grid Margin="16">
    <Grid.RowDefinitions>
      <RowDefinition Height="*"/>
      <RowDefinition Height="Auto"/>
    </Grid.RowDefinitions>
    <TextBox x:Name="MessageText" Grid.Row="0" IsReadOnly="True" TextWrapping="Wrap"
             VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Auto"
             Background="White" BorderBrush="#D1D5DB" Padding="12"/>
    <StackPanel Grid.Row="1" Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,12,0,0">
      <Button x:Name="CopyButton" Content="Kopyala" Width="100" Height="34" Margin="0,0,8,0"/>
      <Button x:Name="CloseButton" Content="Kapat" Width="100" Height="34" IsDefault="True"/>
    </StackPanel>
  </Grid>
</Window>
'@
    $reader = New-Object System.Xml.XmlNodeReader([xml]$xaml)
    $window = [Windows.Markup.XamlReader]::Load($reader)
    $window.Title = $title
    $text = $window.FindName('MessageText')
    $copy = $window.FindName('CopyButton')
    $close = $window.FindName('CloseButton')
    $text.Text = $message
    $copy.Add_Click({ [Windows.Clipboard]::SetText($text.Text) })
    $close.Add_Click({ $window.Close() })
    if ($SelfTest) {
        Write-Output ('SELFTEST=OK;MODE=MESSAGE;TITLE=' + $title)
        return
    }
    [void]$window.ShowDialog()
}

function Get-LicensePasswordFromText {
    param([string]$Content)

    if ([string]::IsNullOrEmpty($Content)) { return $null }

    $expectedLabel = ([char]0x015E).ToString() + ([char]0x0130).ToString() + 'FRE'
    foreach ($line in ($Content -split "`r?`n")) {
        $colonIndex = $line.IndexOf(':')
        if ($colonIndex -lt 0) { continue }

        $label = $line.Substring(0, $colonIndex).Trim().TrimStart([char]0xFEFF)
        if ($label -cne $expectedLabel) { continue }

        $value = $line.Substring($colonIndex + 1).Trim()
        if (-not [string]::IsNullOrEmpty($value)) { return $value }
    }

    return $null
}

function Get-RemoteLicensePassword {
    param([string]$Url)

    if ([string]::IsNullOrWhiteSpace($Url)) { return $null }

    $separator = if ($Url.Contains('?')) { '&' } else { '?' }
    $fetchUrl = $Url + $separator + 'kc_nonce=' + [DateTime]::UtcNow.Ticks
    $response = $null
    $reader = $null
    try {
        [Net.ServicePointManager]::SecurityProtocol =
            [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        $request = [Net.HttpWebRequest]::Create($fetchUrl)
        $request.Method = 'GET'
        $request.Timeout = 10000
        $request.ReadWriteTimeout = 10000
        $request.UserAgent = 'DEG-License-Check'
        $request.CachePolicy = New-Object Net.Cache.RequestCachePolicy([Net.Cache.RequestCacheLevel]::NoCacheNoStore)
        $response = $request.GetResponse()
        $reader = New-Object IO.StreamReader($response.GetResponseStream(), [Text.Encoding]::UTF8, $true)
        $content = $reader.ReadToEnd()
        return Get-LicensePasswordFromText -Content $content
    } finally {
        if ($null -ne $reader) { $reader.Dispose() }
        if ($null -ne $response) { $response.Dispose() }
    }
}

function Show-LicenseWindow {
    $lines = if (Test-Path -LiteralPath $StatePath) { [IO.File]::ReadAllLines($StatePath, [Text.Encoding]::Default) } else { @('DEG - Izin Yok','Bu bilgisayar yetkili degil.') }
    $title = if ($lines.Count -gt 0 -and -not [string]::IsNullOrWhiteSpace($lines[0])) { $lines[0] } else { 'DEG - Izin Yok' }
    $message = if ($lines.Count -gt 1) { [string]::Join([Environment]::NewLine, $lines[1..($lines.Count - 1)]) } else { '' }
    $resultPath = $StatePath + '.result'
    if (Test-Path -LiteralPath $resultPath) { Remove-Item -LiteralPath $resultPath -Force -ErrorAction SilentlyContinue }
    $xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Width="620" MinWidth="420" MaxWidth="920"
        Height="520" MinHeight="360" MaxHeight="760"
        WindowStartupLocation="CenterScreen" Topmost="True"
        Background="#F3F4F6" FontFamily="Segoe UI" FontSize="13">
  <Grid Margin="16">
    <Grid.RowDefinitions>
      <RowDefinition Height="*"/>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="Auto"/>
    </Grid.RowDefinitions>
    <TextBox x:Name="MessageText" Grid.Row="0" IsReadOnly="True" TextWrapping="Wrap"
             VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Auto"
             Background="White" BorderBrush="#D1D5DB" Padding="12"/>
    <Grid Grid.Row="1" Margin="0,14,0,0">
      <Grid.ColumnDefinitions>
        <ColumnDefinition Width="Auto"/>
        <ColumnDefinition Width="*"/>
      </Grid.ColumnDefinitions>
      <TextBlock Grid.Column="0" Text="&#x15E;&#x130;FRE:" FontWeight="SemiBold" VerticalAlignment="Center" Margin="0,0,12,0"/>
      <PasswordBox x:Name="PasswordBox" Grid.Column="1" Height="34" Padding="8,5" VerticalContentAlignment="Center"/>
    </Grid>
    <TextBlock x:Name="StatusText" Grid.Row="2" MinHeight="22" Margin="0,7,0,0" Foreground="#B91C1C"/>
    <StackPanel Grid.Row="3" Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,8,0,0">
      <Button x:Name="CopyButton" Content="MAC Adreslerini Kopyala" Width="165" Height="34" Margin="0,0,8,0"/>
      <Button x:Name="AcceptButton" Content="Giris" Width="100" Height="34" Margin="0,0,8,0" IsDefault="True"/>
      <Button x:Name="CancelButton" Content="Kapat" Width="100" Height="34" IsCancel="True"/>
    </StackPanel>
  </Grid>
</Window>
'@
    $reader = New-Object System.Xml.XmlNodeReader([xml]$xaml)
    $window = [Windows.Markup.XamlReader]::Load($reader)
    $window.Title = $title
    $text = $window.FindName('MessageText')
    $password = $window.FindName('PasswordBox')
    $status = $window.FindName('StatusText')
    $copy = $window.FindName('CopyButton')
    $accept = $window.FindName('AcceptButton')
    $cancel = $window.FindName('CancelButton')
    $text.Text = $message
    if ($SelfTest) {
        Write-Output ('SELFTEST=OK;MODE=LICENSE;TITLE=' + $title)
        return
    }
    $writeResult = {
        param([string]$Value)
        [IO.File]::WriteAllText($resultPath, $Value, (New-Object Text.UTF8Encoding($false)))
    }
    $copy.Add_Click({ [Windows.Clipboard]::SetText($text.Text) })
    $accept.Add_Click({
        $accept.IsEnabled = $false
        $status.Text = 'Sifre GitHub uzerinden kontrol ediliyor...'
        try {
            $remotePassword = Get-RemoteLicensePassword -Url $PasswordUrl
            if ([string]::IsNullOrEmpty($remotePassword)) {
                $status.Text = 'GitHub dosyasinda SIFRE :deger satiri bulunamadi.'
            } elseif ($password.Password.Trim() -ceq $remotePassword) {
                & $writeResult 'OK'
                $window.Close()
            } else {
                $status.Text = 'Sifre yanlis.'
                $password.Clear()
                $password.Focus()
            }
        } catch {
            $status.Text = 'GitHub sayfasina ulasilamadi. Internet baglantisini kontrol edin.'
        } finally {
            $accept.IsEnabled = $true
        }
    })
    $cancel.Add_Click({
        & $writeResult 'CANCEL'
        $window.Close()
    })
    $window.Add_Closed({
        if (-not (Test-Path -LiteralPath $resultPath)) {
            & $writeResult 'CANCEL'
        }
    })
    $window.Add_ContentRendered({ $password.Focus() })
    [void]$window.ShowDialog()
}

if ($Mode -eq 'License') {
    Show-LicenseWindow
    exit 0
}

if ($Mode -eq 'Message') {
    Show-MessageWindow
    exit 0
}

$requestPath = $StatePath + '.request'
$statusPath = $StatePath + '.status'
$showPath = $StatePath + '.show'
# Tam request yolu kullanici adinda bosluk oldugunda bazi GstarCAD
# surumlerinde komut satirinda parcalaniyor. CAD ayni yolu kendi TEMP
# bilgisinden hesapladigi icin geri cagriya yalniz komut adini gonder.
$applyCadCommand = '(C:DO_WINDOWS_APPLY)'
$hostKey = if ($HostPid -gt 0) { [string]$HostPid } elseif ($HostHwnd -gt 0) { [string]$HostHwnd } else { '0' }
$createdNew = $false
$mutex = New-Object System.Threading.Mutex($true, ('Local\DEG_DO_WINDOWS_' + $hostKey), [ref]$createdNew)
if (-not $createdNew -and -not $SelfTest) {
    Write-AtomicLines $showPath @([string][DateTime]::UtcNow.Ticks)
    $mutex.Dispose()
    exit 0
}

$rows = @(Read-SettingRows $StatePath)
$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="DO Ayarlari R3" Width="920" Height="720"
        MinWidth="760" MinHeight="520" WindowStartupLocation="Manual" Topmost="True"
        Background="#F3F4F6" FontFamily="Segoe UI" FontSize="13">
  <Grid Margin="14">
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="*"/>
      <RowDefinition Height="Auto"/>
    </Grid.RowDefinitions>
    <Grid.ColumnDefinitions>
      <ColumnDefinition Width="165"/>
      <ColumnDefinition Width="14"/>
      <ColumnDefinition Width="*"/>
    </Grid.ColumnDefinitions>

    <TextBlock Grid.Row="0" Grid.ColumnSpan="3" Text="DO Komut Ayarlari" FontSize="20" FontWeight="SemiBold" Margin="0,0,0,12"/>
    <Border Grid.Row="1" Grid.Column="0" Background="White" BorderBrush="#D1D5DB" BorderThickness="1" Padding="6">
      <ListBox x:Name="CategoryList" BorderThickness="0" Background="Transparent"/>
    </Border>
    <Grid Grid.Row="1" Grid.Column="2">
      <Grid.RowDefinitions>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="*"/>
      </Grid.RowDefinitions>
      <TextBlock x:Name="PageTitle" Grid.Row="0" FontSize="17" FontWeight="SemiBold" Margin="2,0,0,10"/>
      <Grid Grid.Row="1" Margin="0,0,0,10">
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="*"/>
          <ColumnDefinition Width="Auto"/>
        </Grid.ColumnDefinitions>
        <TextBox x:Name="SearchBox" Grid.Column="0" Height="34" Padding="8,5" ToolTip="Ayar ara"/>
        <Button x:Name="ResetButton" Grid.Column="1" Content="Sayfayi Varsayilana Al" Height="34" Width="170" Margin="10,0,0,0"/>
      </Grid>
      <Border Grid.Row="2" Background="White" BorderBrush="#D1D5DB" BorderThickness="1">
        <ScrollViewer VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled">
          <StackPanel x:Name="PropertyPanel" Margin="10"/>
        </ScrollViewer>
      </Border>
    </Grid>
    <Grid Grid.Row="2" Grid.ColumnSpan="3" Margin="0,12,0,0">
      <Grid.ColumnDefinitions>
        <ColumnDefinition Width="*"/>
        <ColumnDefinition Width="Auto"/>
      </Grid.ColumnDefinitions>
      <TextBlock x:Name="StatusText" Grid.Column="0" Text="Hazir" VerticalAlignment="Center" Foreground="#374151"/>
      <StackPanel Grid.Column="1" Orientation="Horizontal">
        <Button x:Name="SaveButton" Content="Kaydet" Width="110" Height="36" Margin="0,0,8,0" IsDefault="True"/>
        <Button x:Name="CloseButton" Content="Kapat" Width="110" Height="36" IsCancel="True"/>
      </StackPanel>
    </Grid>
  </Grid>
</Window>
'@

$reader = New-Object System.Xml.XmlNodeReader([xml]$xaml)
$window = [Windows.Markup.XamlReader]::Load($reader)
$categoryList = $window.FindName('CategoryList')
$pageTitle = $window.FindName('PageTitle')
$searchBox = $window.FindName('SearchBox')
$propertyPanel = $window.FindName('PropertyPanel')
$resetButton = $window.FindName('ResetButton')
$statusText = $window.FindName('StatusText')
$saveButton = $window.FindName('SaveButton')
$closeButton = $window.FindName('CloseButton')

function Split-Options {
    param([string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return @() }
    return @($Value.Split('|') | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' })
}

function Set-RowValue {
    param($Row, [string]$Value, [string]$EditMode)
    $Row.Value = $Value
    $Row.EditMode = $EditMode
}

$aciColorNames = @{
    '0' = 'ByBlock'
    '1' = 'Kirmizi'
    '2' = 'Sari'
    '3' = 'Yesil'
    '4' = 'Cyan'
    '5' = 'Mavi'
    '6' = 'Magenta'
    '7' = 'Beyaz'
    '8' = 'Koyu Gri'
    '9' = 'Acik Gri'
    '256' = 'ByLayer'
}

function Test-ColorRow {
    param($Row)
    return ([string]$Row.Key).ToUpperInvariant().EndsWith('_COLOR')
}

function Get-ColorDisplayValue {
    param([string]$Value)
    $key = if ($null -eq $Value) { '' } else { $Value.Trim() }
    if ($aciColorNames.ContainsKey($key)) { return [string]$aciColorNames[$key] }
    return $key
}

function Get-ColorStorageValue {
    param([string]$Value)
    $text = if ($null -eq $Value) { '' } else { $Value.Trim() }
    foreach ($entry in $aciColorNames.GetEnumerator()) {
        if ($text.Equals([string]$entry.Value, [StringComparison]::OrdinalIgnoreCase)) {
            return [string]$entry.Key
        }
    }
    return $text
}

function Get-FriendlyWords {
    param([string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return '' }
    $text = $Value.Trim().Replace('*', '').Replace('_', ' ')
    if ($text.StartsWith('E ', [StringComparison]::OrdinalIgnoreCase)) { $text = $text.Substring(2) }
    $culture = [Globalization.CultureInfo]::GetCultureInfo('tr-TR')
    return $culture.TextInfo.ToTitleCase($text.ToLower($culture))
}

$configLabels = @{
    'DD_OFFSET' = 'Ofset'
    'DD_AGIZ_ARAMA' = 'Ana Hat Agiz Arama Mesafesi'
    'DD_BLOK_YAKINLIK' = 'Blok Yakinlik Mesafesi'
    'DD_DIRSEK_DIST' = 'Dirsek Baslama Mesafesi'
    'DD_DIRSEK_KACIS' = 'Dirsek Kacis Mesafesi'
    'DZ_OFFSET' = 'Ofset'
    'DZ_AGIZ_ARAMA' = 'Ana Hat Agiz Arama Mesafesi'
    'DZ_BLOK_YAKINLIK' = 'Blok Yakinlik Mesafesi'
    'DZ_DIRSEK_DIST' = 'Dirsek Baslama Mesafesi'
    'DZ_DIRSEK_KACIS' = 'Dirsek Kacis Mesafesi'
    'DC_DOWN_LEN' = 'Asagi Mesafe'
    'DC_FILLET_R' = 'Fillet'
    'PLAN_UNIT' = 'Olcu Birimi'
    'DO_KAYIT_PATH' = 'Dosya Lokasyonu'
    'DG_EXTRA_LIGHTING_LAYERS' = 'Ek Layerlar'
    'DG_KIT_LAYER' = 'Kit Sinyal Hatlari'
    'DG_ANAHTAR_LAYER' = 'Anahtar Hatlari'
    'DGT_CHAIN_COLOR' = 'Zincir Polyline Rengi'
    'DGT_TOL_SMALL_COLOR' = 'Tol <= 7 Cember Rengi'
    'DGT_TOL_BIG_COLOR' = 'Tol > 7 Cember Rengi'
    'DGT_SORTI_COLOR' = 'R2 Test Cemberi Rengi'
    'DGT_REF_COLOR' = 'Referans Zinciri Rengi'
    'DTT_OUTSIDE_GAP' = 'Cizgi Dis Uzunlugu'
    'DTT_RECT_WIDTH' = 'Dikdortgen Boyu'
    'DTT_RECT_HEIGHT' = 'Dikdortgen Eni'
    'DTT_ATT_TEXT_HEIGHT' = 'Attribute Yazi Yuksekligi'
    'DTT_ATT_TEXT_STYLE' = 'Attribute Yazi Stili'
    'DP_LIGHTING_LINE_LAYERS' = 'Aydinlatma Hatlari (, ile ayirin)'
    'DP_LIGHTING_COMB_LAYERS' = 'Aydinlatma Kombine Hatlari (, ile ayirin)'
    'DP_DATA_LINE_LAYERS' = 'Data Line Layerlari'
    'DP_DATA_COMB_LAYERS' = 'Data Kombine Layerlari'
    'DK_COPY_SPACING' = 'Kopya Araligi'
    'DK_NORMAL_GROUP_SPACING' = 'Ayni Kat Loop Araligi'
    'DK_NORMAL_FLOOR_SPACING' = 'Katlar Arasi Mesafe'
    'DK_TEXT_HEIGHT' = 'Yazi Yuksekligi'
    'DK_TEXT_OFFSET_Y' = 'Yazi Y Ofset'
    'DK_UNDER_X1' = 'Sol Ofset'
    'DK_UNDER_X2' = 'Sag Ofset'
    'DK_UNDER_W' = 'Alt Cizgi Genisligi'
    'DK_UNDER_H' = 'Alt Cizgi Yuksekligi'
    'DK_UNDER_Y_OFFSET' = 'Cizgi Y Kaydirma'
    'DKX_COPY_SPACING' = 'Kopya Araligi'
    'DKX_FIRSTSTART_X' = 'Ilk Baslangic X'
    'DKX_FIRSTSTART_Y' = 'Ilk Baslangic Y'
    'DKX_LASTBOTTOM_X' = 'Ana Hat X'
    'DKX_LASTBOTTOM_Y' = 'Ana Hat Y'
    'DKX_TEXT_OFFSET_Y' = 'Yazi Y Ofset'
    'DKX_TEXT_HEIGHT' = 'Yazi Yuksekligi'
    'DKX_MULTI_DX' = 'Coklu X Kaydirma'
    'DKX_MULTI_DROP_Y' = 'Coklu Y Dusum'
    'DKX_VLEN_MAIN' = 'Dikey Ana'
    'DKX_VLEN_SECONDARY' = 'Dikey Ikincil'
    'DKX_HLEN_DEFAULT' = 'Yatay Standart'
    'DKX_HLEN_LAST2' = 'Son 2li'
    'DKX_HLEN_LAST3_LEFT' = 'Son 3lu Sol'
    'DKX_HLEN_LAST3_RIGHT' = 'Son 3lu Sag'
    'DKX_DATA_SHIFT_Y' = 'Block Y Yukari Kaydirma'
    'DKX_DATA_SHIFT_BLOCKS' = 'Yukari Kayacak Blocklar (virgullu / pattern)'
    'DN_SKIP_BLOCKS' = 'Direkt Skip Block'
    'DN_SKIP_LAYER_PATTERNS' = 'Layer Skip Pattern'
    'DN_SKIP_LAYER_BLOCKS' = 'Layer Skip Block'
    'DN_FILTER_IGNORE_BLOCKS' = 'Ignore Block / Pattern'
    'DN_FILTER_CO_LAYER_PATTERNS' = 'CO Layer Pattern'
    'DN_FILTER_CO_BLOCKS' = 'CO Block'
    'DN_FILTER_FLASOR_LAYERS' = 'Flasor Layer'
    'DN_FILTER_FLASOR_BLOCKS' = 'Flasor Block Pattern'
    'DN_FILTER_SOUND_LAYER_PATTERNS' = 'Sounder Layer Pattern'
    'DN_FILTER_SOUND_BLOCK_PATTERNS' = 'Sounder Block Pattern'
    'DN_FILTER_FIRE_LAYER_PATTERNS' = 'Fire Layer Pattern'
    'DN_FILTER_FIRE_BLOCK_EXCLUDES' = 'Fire Exclude Block Name'
    'DS_ROW_SPACING' = 'Satir Araligi'
    'DS_SYMBOL_DX' = 'Sembol Yazi X'
    'DS_COUNT_DX' = 'Adet Yazi Ek X'
    'DS_TEXT_HEIGHT' = 'Yazi Yuksekligi'
    'DS_TABLE_BLOCK_W' = 'Block Bolumu'
    'DS_TABLE_SYMBOL_W' = 'Sembol Bolumu'
    'DS_TABLE_COUNT_W' = 'Adet Bolumu'
    'DS_SPECIAL_Y_BLOCKS' = 'Ozel Blocklar'
    'DS_SPECIAL_Y_OFFSET' = 'Y Yukari Kaydir'
    'DS_OTHER_Y_OFFSET' = 'Diger Block Y Asagi'
    'DS_EXCLUDE_BLOCKS' = 'Dahil Edilmeyen Blocklar'
    'DG_KNX_START_TOL' = 'KNX Baslangic'
    'DG_KNX_BLOCK_TOL' = 'KNX Block'
    'DG_KNX_END_TOL' = 'KNX Uc-Uc'
    'DG_REF_TOL' = 'Referans'
    'DG_CHAIN_TOL' = 'Zincir'
    'DG_REPORT_TOL' = 'Block Algilama'
    'DG_REF_DAL_TOL' = 'Dal Referans'
    'DG_DAL_SINGLE_TOL' = 'Tek Dal'
    'DG_P1_TOL' = 'P1 Ozel'
    'DN_CHAIN_TOL' = 'DN Zincir'
    'DN_BLOCK_TOL' = 'DN Block'
    'DN_DOSEME_TOL' = 'DN Doseme'
    'DN_MODL_TOL' = 'DN MODL'
    'DW_TOUCH_TOL' = 'DW Temas'
    'DR_TREE_TOL' = 'DR Agac'
}

$pageTitles = @{
    'PLAN' = 'Plan ve Olcu Birimi'
    'DG' = 'DG Hat ve Layer Ayarlari'
    'DGT' = 'DGT Renk ve Reset Ayarlari'
    'DN' = 'DN Numaralandirma ve Filtreler'
    'DK' = 'DK Kopyalama ve Cizim Ayarlari'
    'DP' = 'DP Metraj ve Layer Ayarlari'
    'BLOCKLAR' = 'DP Block Katsayilari'
    'DZ' = 'DZ Cizim Ayarlari'
    'DD' = 'DD Cizim Ayarlari'
    'DC' = 'DC Baglanti Ayarlari'
    'DS' = 'DS Sembol Listesi Ayarlari'
    'DT' = 'DT Kablo Tava Tipleri'
    'DTT' = 'DTT Tava Etiket Ayarlari'
    'TOL' = 'Temas ve Arama Toleranslari'
    'KOMUTLAR' = 'Komut Kisayollari'
    'KAYIT' = 'Dosya Kayit Ayarlari'
    'GENEL' = 'Genel Ayarlar'
}

function Get-DisplayLabel {
    param($Row)
    $key = [string]$Row.Key
    if ($configLabels.ContainsKey($key)) { return [string]$configLabels[$key] }
    if ($Row.Kind -eq 'CODE') {
        $type = ([string]$Row.Label).Split('-')[-1].Trim()
        $name = Get-FriendlyWords ([string]$Row.Default)
        if ([string]::IsNullOrWhiteSpace($name)) { $name = $key }
        return $key + ' - ' + $name + ' (' + (Get-FriendlyWords $type) + ')'
    }
    if ($Row.Kind -eq 'DPLINE') { return [string]$Row.Key }
    if ($Row.Kind -eq 'DPBLOCK') {
        $parts = ([string]$Row.Key).Split('^')
        $field = if ($parts.Count -gt 1) { $parts[1] } else { '' }
        return (Get-FriendlyWords $parts[0]) + ' - ' + (Get-FriendlyWords $field)
    }
    if ($key -match '^DT_TYPE([1-7])_(CODE|LAYER|COLOR|HATCH_PATTERN|HATCH_COLOR|HATCH_SCALE)$') {
        switch ($Matches[2]) {
            'CODE' { return 'Kisa Ad' }
            'LAYER' { return 'Layer Adi' }
            'COLOR' { return 'Cizgi Layer Rengi' }
            'HATCH_PATTERN' { return 'Hatch Deseni' }
            'HATCH_COLOR' { return 'Hatch Layer Rengi' }
            'HATCH_SCALE' { return 'Hatch Olcegi' }
        }
    }
    if ($key -match '^CMD_(.+)$') { return $Matches[1] + ' Komutu' }
    return Get-FriendlyWords $key
}

function Test-CodeInList {
    param([string]$Key, [string[]]$Codes)
    return $Codes -contains $Key
}

function Test-RowOnPage {
    param($Row, [string]$Category)
    if ([string]$Row.Group -eq $Category) { return $true }
    if ($Row.Kind -ne 'CODE') { return $false }
    $key = [string]$Row.Key
    if ($Category -eq 'DK') {
        return Test-CodeInList $key @('C1','C2','C3','C4','C9','C10','D1','D2','D3','D4','D5','D6','O1','O2','M1','M2','M3','M4','N2','L1','L2')
    }
    if ($Category -eq 'DN') {
        return Test-CodeInList $key @(
            'C9','D1','D2','D3','D4','D5','D6','E4','F5','H5',
            'M1','M2','M3','M4','N1','N2','O1','O2',
            'I1','I2','I3','I4','J1','J2','J3','J4','P1','P2',
            'K1','K2','K3','K4','K5','K6','K7','K8','K9','K10','K11','K12','K13','K14','K15','K16','K17','K18','K19',
            'L1','L2')
    }
    return $false
}

function Get-DtTypeSection {
    param([int]$Index)
    $codeRow = $script:rows | Where-Object { $_.Key -eq ('DT_TYPE' + $Index + '_CODE') } | Select-Object -First 1
    $code = if ($null -ne $codeRow) { [string]$codeRow.Value } else { '' }
    if ([string]::IsNullOrWhiteSpace($code)) { return 'Tava Tipi ' + $Index }
    return 'Tava Tipi ' + $Index + ' - ' + $code
}

function Get-RowSection {
    param($Row, [string]$Category)
    $key = [string]$Row.Key
    if ($Category -eq 'DT' -and $key -match '^DT_TYPE([1-7])_') { return Get-DtTypeSection ([int]$Matches[1]) }
    switch ($Category) {
        'DG' {
            if ($key -match '^[AB]') { return 'Aydinlatma / Priz' }
            if ($key -match '^C') { return 'Data / Fiber' }
            if ($key -match '^[EF]') { return 'Telefon / TV' }
            if ($key -match '^G') { return 'UPS' }
            if ($key -match '^H') { return 'Kartli Gecis' }
            if ($key -in @('DG_ANAHTAR_LAYER','DG_KIT_LAYER','DG_EXTRA_LIGHTING_LAYERS')) { return 'KNX / Buton / Anahtar / Kit' }
            return 'DG Genel'
        }
        'DGT' {
            if ($Row.Kind -eq 'ACTION') { return 'DGT Islemleri' }
            return 'DGT Renkleri'
        }
        'DN' {
            if ($key.StartsWith('DN_FILTER_')) { return 'DN Fire / Flasher Filter' }
            if ($key.StartsWith('DN_SKIP_')) { return 'DN skipThis' }
            if ($key -match '^(C9|E4|F5|H5)$') { return 'DN Hat Patternleri' }
            if ($key -match '^D') { return 'DN CCTV' }
            if ($key -match '^[MN]') { return 'Dosemeye Inis / Not' }
            if ($key -match '^[OP]') { return 'Kolon / Yardimci' }
            if ($key -match '^[IJ]') { return 'Buat / Pano' }
            if ($key -match '^[KL]') { return 'Yangin / Terminal' }
            return 'DN Genel'
        }
        'DK' {
            if ($key -match '^DK_NORMAL_(GROUP|FLOOR)_SPACING$' -or $key -match '^DK_LOOP_') { return 'DK Loop Ayarlari' }
            if ($key -match '^DK_UNDER_') { return 'DK Normal Alt Cizgi' }
            if ($key -match '^DKX_DATA_SHIFT_') { return 'DK DATA Block Kaydirma' }
            if ($key -match '^DKX_(MULTI|VLEN|HLEN)') { return 'DK DATA / CCTV Cizgi' }
            if ($key -match '^DKX_') { return 'DK DATA / CCTV Genel' }
            if ($key -match '^DK_') { return 'DK Normal' }
            if ($key -match '^C') { return 'DK DATA Layerlari' }
            if ($key -match '^D') { return 'DK CCTV Layerlari' }
            if ($key -match '^O') { return 'DK Cikti Layerlari' }
            return 'DK Yardimci'
        }
        'DP' {
            if ($Row.Kind -eq 'DPLINE') { return 'Plandaki E_ Hat Kat Sayilari' }
            if ($key.StartsWith('DP_LIGHTING_')) { return 'DP Aydinlatma Layerlari' }
            if ($key.StartsWith('DP_DATA_')) { return 'DP Data / Kombine Layerlari' }
            if ($key -match '^D[1-4]$') { return 'DP CCTV Hatlari' }
            if ($key -match '^D[5-6]$') { return 'DP CCTV Pattern / Keyword' }
            return 'DP Genel'
        }
        'BLOCKLAR' { return 'Block Basina Data / Telefon / TV' }
        'DD' { return 'DD Ayarlari' }
        'DZ' { return 'DZ Ayarlari' }
        'DC' { return 'DC Ayarlari' }
        'DS' {
            if ($key -match '^DS_TABLE_') { return 'DS Liste Bolum Araliklari' }
            if ($key -match '^DS_(SPECIAL|OTHER)') { return 'Ozel Block Kaydirma' }
            if ($key -eq 'DS_EXCLUDE_BLOCKS') { return 'Dahil Edilmeyen Blocklar' }
            return 'DS Mesafe Ayarlari'
        }
        'DTT' {
            if ($key -match '^DTT_ATT_') { return 'Attribute Yazi Ayarlari' }
            return 'DTT Tava Etiket Geometrisi'
        }
        'TOL' {
            if ($key -match '^DG_') { return 'DG / DGT / DATA Tol' }
            if ($key -match '^DN_') { return 'DN / Kolon Semasi Tol' }
            return 'DW / DR Tol'
        }
        'KOMUTLAR' {
            if ($key -in @('CMD_DG','CMD_DGT','CMD_DN','CMD_DK','CMD_DP','CMD_DD','CMD_DR')) { return 'Komut Adlari 1' }
            return 'Komut Adlari 2'
        }
        'PLAN' { return 'PLAN Ayarlari' }
        'KAYIT' { return 'Kayit Ayarlari' }
        default { return $Category + ' Ayarlari' }
    }
}

function Get-SectionRank {
    param([string]$Category, [string]$Section)
    $orders = @{
        'DG' = @('Aydinlatma / Priz','KNX / Buton / Anahtar / Kit','Data / Fiber','Telefon / TV','UPS','Kartli Gecis','DG Genel')
        'DGT' = @('DGT Renkleri','DGT Islemleri')
        'DN' = @('DN Hat Patternleri','DN CCTV','Dosemeye Inis / Not','Kolon / Yardimci','Buat / Pano','Yangin / Terminal','DN skipThis','DN Fire / Flasher Filter','DN Genel')
        'DK' = @('DK Normal','DK Normal Alt Cizgi','DK Loop Ayarlari','DK DATA / CCTV Genel','DK DATA / CCTV Cizgi','DK DATA Layerlari','DK DATA Block Kaydirma','DK CCTV Layerlari','DK Cikti Layerlari','DK Yardimci')
        'DP' = @('DP Aydinlatma Layerlari','DP Data / Kombine Layerlari','DP CCTV Hatlari','DP CCTV Pattern / Keyword','Plandaki E_ Hat Kat Sayilari','DP Genel')
        'DS' = @('DS Mesafe Ayarlari','DS Liste Bolum Araliklari','Ozel Block Kaydirma','Dahil Edilmeyen Blocklar')
        'DTT' = @('DTT Tava Etiket Geometrisi','Attribute Yazi Ayarlari')
        'TOL' = @('DG / DGT / DATA Tol','DN / Kolon Semasi Tol','DW / DR Tol')
        'KOMUTLAR' = @('Komut Adlari 1','Komut Adlari 2')
    }
    if ($Category -eq 'DT' -and $Section -match '^Tava Tipi ([1-7])') { return [int]$Matches[1] }
    if ($orders.ContainsKey($Category)) {
        $index = [array]::IndexOf([string[]]$orders[$Category], $Section)
        if ($index -ge 0) { return $index + 1 }
    }
    return 100
}

function Render-Rows {
    $propertyPanel.Children.Clear()
    $category = [string]$categoryList.SelectedItem
    $pageName = if ($pageTitles.ContainsKey($category)) { [string]$pageTitles[$category] } else { $category + ' Ayarlari' }
    $pageTitle.Text = 'DO - ' + $pageName
    $search = $searchBox.Text.Trim()
    $visible = @($script:rows | Where-Object {
        (Test-RowOnPage $_ $category) -and
        ([string]::IsNullOrWhiteSpace($search) -or
         (Get-DisplayLabel $_).IndexOf($search, [StringComparison]::OrdinalIgnoreCase) -ge 0 -or
         (Get-RowSection $_ $category).IndexOf($search, [StringComparison]::OrdinalIgnoreCase) -ge 0 -or
         $_.Key.IndexOf($search, [StringComparison]::OrdinalIgnoreCase) -ge 0)
    })
    $visible = @($visible | Sort-Object @{ Expression = { Get-SectionRank $category (Get-RowSection $_ $category) } }, Index)
    $sectionGroups = @($visible | Group-Object { Get-RowSection $_ $category })
    foreach ($sectionGroup in $sectionGroups) {
        $sectionBorder = New-Object Windows.Controls.Border
        $sectionBorder.BorderBrush = '#D1D5DB'
        $sectionBorder.BorderThickness = '1'
        $sectionBorder.CornerRadius = '4'
        $sectionBorder.Margin = '0,0,0,12'
        $sectionStack = New-Object Windows.Controls.StackPanel
        $sectionHeader = New-Object Windows.Controls.Border
        $sectionHeader.Background = '#EEF2F7'
        $sectionHeader.BorderBrush = '#CBD5E1'
        $sectionHeader.BorderThickness = '0,0,0,1'
        $sectionText = New-Object Windows.Controls.TextBlock
        $sectionText.Text = [string]$sectionGroup.Name
        $sectionText.FontSize = 15
        $sectionText.FontWeight = 'SemiBold'
        $sectionText.Foreground = '#1F2937'
        $sectionText.Padding = '10,8'
        $sectionHeader.Child = $sectionText
        [void]$sectionStack.Children.Add($sectionHeader)

        foreach ($row in $sectionGroup.Group) {
            $border = New-Object Windows.Controls.Border
            $border.BorderBrush = '#E5E7EB'
            $border.BorderThickness = '0,0,0,1'
            $border.Padding = '8,7'
            $grid = New-Object Windows.Controls.Grid
            [void]$grid.ColumnDefinitions.Add((New-Object Windows.Controls.ColumnDefinition -Property @{ Width = '255' }))
            [void]$grid.ColumnDefinitions.Add((New-Object Windows.Controls.ColumnDefinition -Property @{ Width = '*' }))
            $label = New-Object Windows.Controls.TextBlock
            $label.Text = Get-DisplayLabel $row
            $label.VerticalAlignment = 'Center'
            $label.Margin = '3,0,12,0'
            $label.ToolTip = $row.Key
            $label.TextWrapping = 'Wrap'
            [Windows.Controls.Grid]::SetColumn($label, 0)
            [void]$grid.Children.Add($label)

            if ($row.Type -eq 'ACTION') {
                $control = New-Object Windows.Controls.Button
                $control.Content = $row.Value
                $control.Height = 32
                $control.HorizontalAlignment = 'Left'
                $control.MinWidth = 150
                $currentRow = $row
                $control.Add_Click({
                    Set-RowValue $currentRow '1' 'ACTION'
                    $statusText.Text = 'Islem Kaydet ile uygulanacak.'
                    $statusText.Foreground = '#374151'
                }.GetNewClosure())
            } elseif ($row.Type -eq 'CHOICE') {
                $control = New-Object Windows.Controls.ComboBox
                $control.Height = 32
                $control.IsEditable = $true
                $isColorChoice = Test-ColorRow $row
                foreach ($option in (Split-Options $row.Options)) {
                    if ($isColorChoice) {
                        $entry = New-Object Windows.Controls.ComboBoxItem
                        $entry.Content = Get-ColorDisplayValue $option
                        $entry.Tag = $option
                        [void]$control.Items.Add($entry)
                        if ([string]$option -eq [string]$row.Value) { $control.SelectedItem = $entry }
                    } else {
                        [void]$control.Items.Add($option)
                    }
                }
                if ($isColorChoice) {
                    if ($null -eq $control.SelectedItem) {
                        $control.Text = Get-ColorDisplayValue ([string]$row.Value)
                    }
                } else {
                    $control.Text = $row.Value
                }
                $currentRow = $row
                $currentIsColorChoice = $isColorChoice
                $control.Add_SelectionChanged({
                    if ($null -ne $this.SelectedItem) {
                        $selectedValue =
                            if ($currentIsColorChoice -and $this.SelectedItem -is [Windows.Controls.ComboBoxItem]) {
                                [string]$this.SelectedItem.Tag
                            } else {
                                [string]$this.SelectedItem
                            }
                        Set-RowValue $currentRow $selectedValue 'SET'
                    }
                }.GetNewClosure())
                $control.Add_LostKeyboardFocus({
                    $typedValue = [string]$this.Text
                    if ($currentIsColorChoice) { $typedValue = Get-ColorStorageValue $typedValue }
                    Set-RowValue $currentRow $typedValue 'SET'
                }.GetNewClosure())
            } else {
                $inner = New-Object Windows.Controls.Grid
                [void]$inner.ColumnDefinitions.Add((New-Object Windows.Controls.ColumnDefinition -Property @{ Width = '*' }))
                if ($row.Type -eq 'PATH') {
                    [void]$inner.ColumnDefinitions.Add((New-Object Windows.Controls.ColumnDefinition -Property @{ Width = 'Auto' }))
                }
                $control = New-Object Windows.Controls.TextBox
                $control.Text = $row.Value
                $control.Height = if ($row.Type -eq 'LONG') { 58 } else { 32 }
                $control.Padding = '7,4'
                $control.VerticalContentAlignment = 'Center'
                if ($row.Type -eq 'LONG') {
                    $control.AcceptsReturn = $true
                    $control.TextWrapping = 'Wrap'
                    $control.VerticalScrollBarVisibility = 'Auto'
                }
                $currentRow = $row
                $control.Add_TextChanged({
                    Set-RowValue $currentRow ([string]$this.Text) 'SET'
                }.GetNewClosure())
                [Windows.Controls.Grid]::SetColumn($control, 0)
                [void]$inner.Children.Add($control)
                if ($row.Type -eq 'PATH') {
                    $browse = New-Object Windows.Controls.Button
                    $browse.Content = 'Gozat'
                    $browse.Width = 72
                    $browse.Height = 32
                    $browse.Margin = '8,0,0,0'
                    $pathBox = $control
                    $browse.Add_Click({
                        $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
                        if (-not [string]::IsNullOrWhiteSpace($pathBox.Text) -and (Test-Path -LiteralPath $pathBox.Text -PathType Container)) {
                            $dialog.SelectedPath = $pathBox.Text
                        }
                        if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { $pathBox.Text = $dialog.SelectedPath }
                        $dialog.Dispose()
                    }.GetNewClosure())
                    [Windows.Controls.Grid]::SetColumn($browse, 1)
                    [void]$inner.Children.Add($browse)
                }
                $control = $inner
            }
            $row.Control = $control
            [Windows.Controls.Grid]::SetColumn($control, 1)
            [void]$grid.Children.Add($control)
            $border.Child = $grid
            [void]$sectionStack.Children.Add($border)
        }
        $sectionBorder.Child = $sectionStack
        [void]$propertyPanel.Children.Add($sectionBorder)
    }
    if ($visible.Count -eq 0) {
        $empty = New-Object Windows.Controls.TextBlock
        $empty.Text = 'Bu aramaya uygun ayar bulunamadi.'
        $empty.Foreground = '#6B7280'
        $empty.Margin = '8'
        [void]$propertyPanel.Children.Add($empty)
    }
}

function Reload-Schema {
    $selected = [string]$categoryList.SelectedItem
    $script:rows = @(Read-SettingRows $StatePath)
    $available = @($script:rows | ForEach-Object { $_.Group } | Select-Object -Unique)
    $categories = @($available | Sort-Object `
        @{ Expression = {
            if ($_ -eq 'PLAN') { 0 }
            elseif ($_ -like 'D*') { 1 }
            elseif ($_ -eq 'TOL') { 2 }
            else { 3 }
        } },
        @{ Expression = { [string]$_ } })
    $categoryList.Items.Clear()
    foreach ($category in $categories) { [void]$categoryList.Items.Add($category) }
    if ($categories -contains $selected) { $categoryList.SelectedItem = $selected }
    elseif ($categoryList.Items.Count -gt 0) { $categoryList.SelectedIndex = 0 }
    Render-Rows
}

Reload-Schema

$positionDir = Split-Path -Parent $StatePath
if ([string]::IsNullOrWhiteSpace($positionDir)) {
    $positionDir = Join-Path ([Environment]::GetFolderPath('ApplicationData')) 'DEG'
}
$positionPath = Join-Path $positionDir 'do_windows_position.txt'
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
    $window.Left = [System.Windows.SystemParameters]::WorkArea.Right - $window.Width - 35
    $window.Top = [System.Windows.SystemParameters]::WorkArea.Top + 45
}

$categoryList.Add_SelectionChanged({ Render-Rows })
$searchBox.Add_TextChanged({ Render-Rows })
$resetButton.Add_Click({
    $category = [string]$categoryList.SelectedItem
    foreach ($row in @($script:rows | Where-Object { (Test-RowOnPage $_ $category) -and $_.Type -ne 'ACTION' })) {
        Set-RowValue $row $row.Default 'RESET'
    }
    Render-Rows
    $statusText.Text = $category + ' varsayilanlari hazir. Kaydet ile uygulayin.'
    $statusText.Foreground = '#374151'
})

$script:pendingSave = $false
$script:pendingSaveSince = [DateTime]::MinValue
$script:pendingLastAttempt = [DateTime]::MinValue
$script:pendingAttempts = 0

function Invoke-CadApply {
    $script:pendingAttempts++
    $script:pendingLastAttempt = [DateTime]::UtcNow
    return (Send-CadCommand $applyCadCommand)
}

$saveButton.Add_Click({
    try {
        $changed = @($script:rows | Where-Object { -not [string]::IsNullOrWhiteSpace($_.EditMode) })
        if ($changed.Count -eq 0) {
            $statusText.Text = 'Degisen ayar yok.'
            $statusText.Foreground = '#374151'
            return
        }
        $request = @()
        $request += ('REQUEST' + "`t" + [string][DateTime]::UtcNow.Ticks)
        foreach ($row in $changed) {
            $value = ([string]$row.Value).Replace("`t", ' ').Replace("`r", ' ').Replace("`n", ' ')
            $request += ($row.EditMode + "`t" + $row.Kind + "`t" + $row.Key + "`t" + $value)
        }
        if (Test-Path -LiteralPath $statusPath) {
            Remove-Item -LiteralPath $statusPath -Force -ErrorAction SilentlyContinue
        }
        $script:lastStatusWrite = 0L
        Write-AtomicLines $requestPath $request
        $script:pendingSave = $true
        $script:pendingSaveSince = [DateTime]::UtcNow
        $script:pendingLastAttempt = [DateTime]::MinValue
        $script:pendingAttempts = 0
        $saveButton.IsEnabled = $false
        $statusText.Text = 'Ayarlar CAD icinde kaydediliyor...'
        $statusText.Foreground = '#166534'
        if (-not (Invoke-CadApply)) {
            $statusText.Text = 'GstarCAD baglantisi deneniyor...'
            $statusText.Foreground = '#92400E'
        }
    } catch {
        $script:pendingSave = $false
        $saveButton.IsEnabled = $true
        $statusText.Text = 'Kaydetme baslatilamadi: ' + $_.Exception.Message
        $statusText.Foreground = '#B91C1C'
        try {
            [IO.File]::AppendAllText($LogPath, ([Environment]::NewLine + [DateTime]::Now.ToString('s') + ' SAVE: ' + ($_ | Out-String)), (New-Object Text.UTF8Encoding($false)))
        } catch { }
    }
})

$closeButton.Add_Click({ $window.Close() })

$lastStatusWrite = 0L
$lastShowWrite = 0L
$pollTimer = New-Object Windows.Threading.DispatcherTimer
$pollTimer.Interval = [TimeSpan]::FromMilliseconds(350)
$pollTimer.Add_Tick({
    try {
        if (Test-Path -LiteralPath $statusPath) {
            $write = (Get-Item -LiteralPath $statusPath).LastWriteTimeUtc.Ticks
            if ($write -ne $script:lastStatusWrite) {
                $script:lastStatusWrite = $write
                $status = Read-Status $statusPath
                $script:pendingSave = $false
                $saveButton.IsEnabled = $true
                $statusText.Text = [string]$status['MESSAGE']
                $statusText.Foreground = if ([string]$status['OK'] -eq '1') { '#166534' } else { '#B91C1C' }
                if ([string]$status['OK'] -eq '1') { Reload-Schema }
            }
        }
        if ($script:pendingSave) {
            $now = [DateTime]::UtcNow
            $elapsed = ($now - $script:pendingSaveSince).TotalSeconds
            $sinceAttempt = ($now - $script:pendingLastAttempt).TotalSeconds
            if ($elapsed -ge 10.0) {
                $script:pendingSave = $false
                $saveButton.IsEnabled = $true
                $statusText.Text = 'GstarCAD ayar komutunu calistirmadi. Paneli kapatip DO ile yeniden acin.'
                $statusText.Foreground = '#B91C1C'
            } elseif ($script:pendingAttempts -lt 4 -and $sinceAttempt -ge 1.5) {
                [void](Invoke-CadApply)
            }
        }
        if (Test-Path -LiteralPath $showPath) {
            $write = (Get-Item -LiteralPath $showPath).LastWriteTimeUtc.Ticks
            if ($write -ne $script:lastShowWrite) {
                $script:lastShowWrite = $write
                $window.Show()
                $window.WindowState = 'Normal'
                $window.Activate()
                $window.Topmost = $false
                $window.Topmost = $true
            }
        }
    } catch { }
})
$pollTimer.Start()

$window.Add_Closing({
    $pollTimer.Stop()
    if (-not (Test-Path -LiteralPath $positionDir)) { [IO.Directory]::CreateDirectory($positionDir) | Out-Null }
    [IO.File]::WriteAllLines($positionPath, @(
        $window.Left.ToString([Globalization.CultureInfo]::InvariantCulture),
        $window.Top.ToString([Globalization.CultureInfo]::InvariantCulture)
    ))
})

if ($SelfTest) {
    $cadProgIds = @(Get-CadProgIds)
    if ($cadProgIds.Count -lt 3 -or
        $cadProgIds -notcontains 'AutoCAD.Application' -or
        $cadProgIds -notcontains 'GstarCAD.Application' -or
        $applyCadCommand -ne '(C:DO_WINDOWS_APPLY)') {
        throw 'CAD geri cagri yapilandirmasi hatali.'
    }
    if ((Get-ColorDisplayValue '7') -ne 'Beyaz' -or
        (Get-ColorDisplayValue '6') -ne 'Magenta' -or
        (Get-ColorDisplayValue '4') -ne 'Cyan' -or
        (Get-ColorStorageValue 'Beyaz') -ne '7' -or
        (Get-ColorStorageValue '200,151,210') -ne '200,151,210') {
        throw 'Renk ad/deger eslemesi hatali.'
    }
    $renderedCategories = 0
    foreach ($category in @($categoryList.Items)) {
        $categoryList.SelectedItem = $category
        Render-Rows
        $renderedCategories++
    }
    $dtSections = @($script:rows |
        Where-Object { Test-RowOnPage $_ 'DT' } |
        ForEach-Object { Get-RowSection $_ 'DT' } |
        Select-Object -Unique)
    if ($dtSections.Count -lt 7) { throw 'DT bolumleri eksik olusturuldu.' }
    if (Test-Path -LiteralPath $LogPath) { Remove-Item -LiteralPath $LogPath -Force }
    Write-Output ('SELFTEST=OK;MODE=SETTINGS;ROWS=' + $rows.Count + ';CATEGORIES=' + $renderedCategories + ';DTSECTIONS=' + $dtSections.Count + ';CADIDS=' + $cadProgIds.Count + ';COLORS=OK;WINDOW=OK')
    if ($createdNew) { $mutex.ReleaseMutex() }
    $mutex.Dispose()
    exit 0
}

try {
    [void]$window.ShowDialog()
} finally {
    try { if ($createdNew) { $mutex.ReleaseMutex() } } catch { }
    $mutex.Dispose()
}
