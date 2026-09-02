param(
    [Parameter(Mandatory = $true)]
    [string]$StatePath,
    [string]$PasswordUrl = '',
    [string]$DeviceCodePath = '',
    [string]$DeviceCode = '',
    [string]$LicenseMarkerBaseUrl = '',
    [string]$LicenseGrantPath = '',
    [string]$LicenseOverridePath = '',
    [ValidateRange(1, 168)]
    [int]$LicenseGrantHours = 24,
    [string]$UpdateApiUrl = '',
    [string]$UpdateContentsApiUrl = '',
    [string]$UpdateRawBaseUrl = '',
    [string]$TargetDirectory = '',
    [string]$UpdateStatePath = '',
    [string]$PendingDirectory = '',
    [string]$PendingVersion = '',
    [int]$WaitForPid = 0,
    [ValidateSet('Settings','Message','License','LicenseCheck','DeviceCode','Update','ApplyPending')]
    [string]$Mode = 'Settings',
    [int]$HostPid = 0,
    [long]$HostHwnd = 0,
    [switch]$ElevatedUpdate,
    [switch]$ShowProgress,
    [string]$UpdateUserSid = '',
    [switch]$SelfTest
)

function ConvertTo-DEGCompatiblePath {
    param([AllowEmptyString()][string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) { return $Path }
    $candidate = [Environment]::ExpandEnvironmentVariables($Path.Trim().Trim('"'))
    try { $candidate = [IO.Path]::GetFullPath($candidate) } catch { return $candidate }

    # Bazi ANSI tabanli CAD surumleri ASLI~1 kismini ASLI\~1 olarak donduruyor.
    # Yalnizca bozuk yol yoksa ve birlestirilmis yol/ust klasor varsa onar.
    if (-not (Test-Path -LiteralPath $candidate)) {
        $repaired = [Text.RegularExpressions.Regex]::Replace($candidate, '\\~(?=\d+(?:\\|$))', '~')
        if ($repaired -cne $candidate) {
            $repairedParent = [IO.Path]::GetDirectoryName($repaired)
            if ((Test-Path -LiteralPath $repaired) -or
                (-not [string]::IsNullOrWhiteSpace($repairedParent) -and
                 (Test-Path -LiteralPath $repairedParent -PathType Container))) {
                $candidate = $repaired
            }
        }
    }

    # Gecerli 8.3 yolunu (or. ASLI~1) gercek Unicode uzun yola cevir.
    try {
        if (Test-Path -LiteralPath $candidate) {
            return (Get-Item -LiteralPath $candidate -Force).FullName
        }
        $parent = [IO.Path]::GetDirectoryName($candidate)
        if (-not [string]::IsNullOrWhiteSpace($parent) -and
            (Test-Path -LiteralPath $parent -PathType Container)) {
            $longParent = (Get-Item -LiteralPath $parent -Force).FullName
            return Join-Path $longParent ([IO.Path]::GetFileName($candidate))
        }
    } catch { }
    return $candidate
}

$StatePath       = ConvertTo-DEGCompatiblePath $StatePath
$DeviceCodePath  = ConvertTo-DEGCompatiblePath $DeviceCodePath
$LicenseGrantPath = ConvertTo-DEGCompatiblePath $LicenseGrantPath
$LicenseOverridePath = ConvertTo-DEGCompatiblePath $LicenseOverridePath
$TargetDirectory = ConvertTo-DEGCompatiblePath $TargetDirectory
$UpdateStatePath = ConvertTo-DEGCompatiblePath $UpdateStatePath
$PendingDirectory = ConvertTo-DEGCompatiblePath $PendingDirectory

if ($Mode -eq 'Update' -and
    (-not [string]::IsNullOrWhiteSpace($TargetDirectory)) -and
    (-not (Test-Path -LiteralPath $TargetDirectory -PathType Container))) {
    $scriptDirectory = ConvertTo-DEGCompatiblePath (Split-Path -Parent $PSCommandPath)
    $requiredFiles = @('DG_DO_R05.VLX', 'DG_DT_TAVA_PALET.ps1', 'DG_WINDOWS_UI.ps1')
    $scriptDirectoryIsTarget = -not ($requiredFiles | Where-Object {
        -not (Test-Path -LiteralPath (Join-Path $scriptDirectory $_) -PathType Leaf)
    })
    if ($scriptDirectoryIsTarget) { $TargetDirectory = $scriptDirectory }
}

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Security
$LogPath = $StatePath + '.log'
trap {
    $trapText = try { [string]$_.Exception.Message } catch { 'Beklenmeyen PowerShell hatasi.' }
    $trapText = ($trapText -replace '[\r\n|]+', ' ').Trim()
    try { [IO.File]::WriteAllText($LogPath, ($_ | Out-String), (New-Object Text.UTF8Encoding($false))) } catch { }
    try { Write-UpdateResult ('FAILED|' + $trapText) } catch { }
    exit 1
}

function Write-UpdateResult {
    param([string]$Value)
    [IO.File]::WriteAllText($StatePath + '.result', $Value, (New-Object Text.UTF8Encoding($false)))
}

function Get-UpdateErrorSummary {
    param([object]$ErrorRecord)

    $exception = if ($null -ne $ErrorRecord) { $ErrorRecord.Exception } else { $null }
    $message = if ($null -ne $exception) { [string]$exception.Message } else { [string]$ErrorRecord }
    $prefix = ''
    if ($exception -is [Net.WebException]) {
        switch ($exception.Status) {
            ([Net.WebExceptionStatus]::Timeout) { $prefix = 'GitHub baglantisi zaman asimina ugradi. '; break }
            ([Net.WebExceptionStatus]::NameResolutionFailure) { $prefix = 'GitHub adresi cozumlenemedi. Internet veya DNS baglantisini kontrol edin. '; break }
            ([Net.WebExceptionStatus]::ProxyNameResolutionFailure) { $prefix = 'Vekil sunucu adresi cozumlenemedi. '; break }
            ([Net.WebExceptionStatus]::TrustFailure) { $prefix = 'Guvenli GitHub baglantisi kurulamadi. Windows sertifikalarini kontrol edin. '; break }
            default { }
        }
        try {
            if ($null -ne $exception.Response) {
                $statusCode = [int]$exception.Response.StatusCode
                if ($statusCode -eq 403 -or $statusCode -eq 429) {
                    $prefix = 'GitHub erisim limiti veya ag engeliyle karsilasti. '
                } elseif ($statusCode -eq 404) {
                    $prefix = 'GitHub guncelleme dosyasi bulunamadi. '
                } elseif ($statusCode -eq 407) {
                    $prefix = 'Vekil sunucu oturum acma bilgisi istiyor. '
                } elseif ($statusCode -ge 500) {
                    $prefix = 'GitHub gecici bir sunucu hatasi dondurdu. '
                }
            }
        } catch { }
    } elseif ($exception -is [UnauthorizedAccessException]) {
        $prefix = 'Guncelleme klasorune yazma izni yok. '
    } elseif ($exception -is [IO.IOException]) {
        $prefix = 'Guncelleme dosyalarindan biri baska bir program tarafindan kullaniliyor. '
    }
    $summary = ($prefix + $message) -replace '[\r\n|]+', ' '
    $summary = $summary.Trim()
    if ([string]::IsNullOrWhiteSpace($summary)) { $summary = 'Bilinmeyen guncelleme hatasi.' }
    if ($summary.Length -gt 700) { $summary = $summary.Substring(0, 700) }
    return $summary
}

function Write-UpdateFailure {
    param(
        [object]$ErrorRecord,
        [string]$Context = ''
    )

    $summary = Get-UpdateErrorSummary -ErrorRecord $ErrorRecord
    if (-not [string]::IsNullOrWhiteSpace($Context)) {
        $summary = $Context.Trim() + ': ' + $summary
    }
    try {
        $details = @(
            ('Zaman: ' + [DateTime]::Now.ToString('yyyy-MM-dd HH:mm:ss')),
            ('Bilgisayar: ' + $env:COMPUTERNAME),
            ('Windows: ' + [Environment]::OSVersion.VersionString),
            ('PowerShell: ' + $PSVersionTable.PSVersion.ToString()),
            ('Hedef: ' + $TargetDirectory),
            ('Ozet: ' + $summary),
            '',
            ($ErrorRecord | Out-String)
        ) -join "`r`n"
        [IO.File]::WriteAllText($LogPath, $details, (New-Object Text.UTF8Encoding($false)))
    } catch { }
    Write-UpdateResult ('FAILED|' + $summary)
}

function Test-DeviceCodeFormat {
    param([string]$Code)
    return (-not [string]::IsNullOrWhiteSpace($Code)) -and
        ($Code.Trim().ToUpperInvariant() -cmatch '^KCPC-[0-9A-F]{8}-[0-9A-F]{8}-[0-9A-F]{8}-[0-9A-F]{8}$')
}

function New-DeviceSecret {
    $bytes = New-Object byte[] 32
    $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
    try {
        $rng.GetBytes($bytes)
    } finally {
        $rng.Dispose()
    }
    return ,$bytes
}

function Get-MachineIdentity {
    $machineGuid = [Microsoft.Win32.Registry]::GetValue(
        'HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Cryptography',
        'MachineGuid',
        $null)
    if ([string]::IsNullOrWhiteSpace([string]$machineGuid)) {
        throw 'Windows makine kimligi okunamadi.'
    }
    return ([string]$machineGuid).Trim().ToUpperInvariant()
}

function Get-DeviceCodeFromSecret {
    param([byte[]]$Secret)
    if ($null -eq $Secret -or $Secret.Length -ne 32) {
        throw 'Cihaz gizli anahtari gecersiz.'
    }
    $machineBytes = [Text.Encoding]::UTF8.GetBytes('DEG-KC-DEVICE-V1|' + (Get-MachineIdentity) + '|')
    $inputBytes = New-Object byte[] ($machineBytes.Length + $Secret.Length)
    [Array]::Copy($machineBytes, 0, $inputBytes, 0, $machineBytes.Length)
    [Array]::Copy($Secret, 0, $inputBytes, $machineBytes.Length, $Secret.Length)
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $digest = $sha.ComputeHash($inputBytes)
    } finally {
        $sha.Dispose()
    }
    $hex = ([BitConverter]::ToString($digest, 0, 16)).Replace('-', '')
    return ('KCPC-{0}-{1}-{2}-{3}' -f
        $hex.Substring(0, 8),
        $hex.Substring(8, 8),
        $hex.Substring(16, 8),
        $hex.Substring(24, 8))
}

function Read-ProtectedDeviceSecret {
    param([string]$Path)
    $entropy = [Text.Encoding]::UTF8.GetBytes('DEG-KC-DEVICE-V1')
    $encoded = [IO.File]::ReadAllText($Path, [Text.Encoding]::ASCII).Trim()
    $protectedBytes = [Convert]::FromBase64String($encoded)
    $secret = [Security.Cryptography.ProtectedData]::Unprotect(
        $protectedBytes,
        $entropy,
        [Security.Cryptography.DataProtectionScope]::LocalMachine)
    if ($null -eq $secret -or $secret.Length -ne 32) {
        throw 'Kayitli cihaz gizli anahtari gecersiz.'
    }
    return ,$secret
}

function Get-OrCreateDeviceCode {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) {
        throw 'Cihaz kodu dosya yolu verilmedi.'
    }

    $fullPath = [IO.Path]::GetFullPath($Path)
    $directory = [IO.Path]::GetDirectoryName($fullPath)
    if ([string]::IsNullOrWhiteSpace($directory)) {
        throw 'Cihaz kodu klasoru bulunamadi.'
    }
    [void][IO.Directory]::CreateDirectory($directory)

    if ([IO.File]::Exists($fullPath)) {
        $secret = Read-ProtectedDeviceSecret -Path $fullPath
        return Get-DeviceCodeFromSecret -Secret $secret
    }

    $secret = New-DeviceSecret
    $entropy = [Text.Encoding]::UTF8.GetBytes('DEG-KC-DEVICE-V1')
    $protectedBytes = [Security.Cryptography.ProtectedData]::Protect(
        $secret,
        $entropy,
        [Security.Cryptography.DataProtectionScope]::LocalMachine)
    $encoded = [Convert]::ToBase64String($protectedBytes)
    $tempPath = $fullPath + '.new_' + [Diagnostics.Process]::GetCurrentProcess().Id
    [IO.File]::WriteAllText($tempPath, $encoded, [Text.Encoding]::ASCII)

    if ([IO.File]::Exists($fullPath)) {
        [IO.File]::Delete($tempPath)
        $secret = Read-ProtectedDeviceSecret -Path $fullPath
        return Get-DeviceCodeFromSecret -Secret $secret
    }
    [IO.File]::Move($tempPath, $fullPath)
    return Get-DeviceCodeFromSecret -Secret $secret
}

function Remove-LicenseFile {
    param([string]$Path)
    if (-not [string]::IsNullOrWhiteSpace($Path) -and [IO.File]::Exists($Path)) {
        try { [IO.File]::Delete($Path) } catch { }
    }
}

function Write-ProtectedLicenseData {
    param(
        [Parameter(Mandatory = $true)][object]$Data,
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Purpose
    )

    $fullPath = [IO.Path]::GetFullPath($Path)
    $directory = [IO.Path]::GetDirectoryName($fullPath)
    if ([string]::IsNullOrWhiteSpace($directory)) { throw 'Lisans kayit klasoru bulunamadi.' }
    [void][IO.Directory]::CreateDirectory($directory)

    $plainBytes = [Text.Encoding]::UTF8.GetBytes(($Data | ConvertTo-Json -Compress))
    $entropy = [Text.Encoding]::UTF8.GetBytes($Purpose)
    $protectedBytes = [Security.Cryptography.ProtectedData]::Protect(
        $plainBytes,
        $entropy,
        [Security.Cryptography.DataProtectionScope]::CurrentUser)
    $encoded = [Convert]::ToBase64String($protectedBytes)
    $suffix = [Diagnostics.Process]::GetCurrentProcess().Id.ToString() + '_' + [Guid]::NewGuid().ToString('N')
    $tempPath = $fullPath + '.new_' + $suffix
    $backupPath = $fullPath + '.bak_' + $suffix

    try {
        [IO.File]::WriteAllText($tempPath, $encoded, [Text.Encoding]::ASCII)
        if ([IO.File]::Exists($fullPath)) {
            [IO.File]::Replace($tempPath, $fullPath, $backupPath, $true)
            Remove-LicenseFile -Path $backupPath
        } else {
            [IO.File]::Move($tempPath, $fullPath)
        }
    } finally {
        Remove-LicenseFile -Path $tempPath
        Remove-LicenseFile -Path $backupPath
        if ($null -ne $plainBytes) { [Array]::Clear($plainBytes, 0, $plainBytes.Length) }
    }
}

function Read-ProtectedLicenseData {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Purpose
    )

    if ([string]::IsNullOrWhiteSpace($Path) -or -not [IO.File]::Exists($Path)) { return $null }
    $plainBytes = $null
    try {
        $encoded = [IO.File]::ReadAllText($Path, [Text.Encoding]::ASCII).Trim()
        $protectedBytes = [Convert]::FromBase64String($encoded)
        $entropy = [Text.Encoding]::UTF8.GetBytes($Purpose)
        $plainBytes = [Security.Cryptography.ProtectedData]::Unprotect(
            $protectedBytes,
            $entropy,
            [Security.Cryptography.DataProtectionScope]::CurrentUser)
        $json = [Text.Encoding]::UTF8.GetString($plainBytes)
        return ($json | ConvertFrom-Json)
    } catch {
        return $null
    } finally {
        if ($null -ne $plainBytes) { [Array]::Clear($plainBytes, 0, $plainBytes.Length) }
    }
}

function Write-ProtectedLicenseGrant {
    param([string]$Path, [string]$Code, [int]$Hours)
    $now = [DateTimeOffset]::UtcNow
    $data = [pscustomobject]@{
        version    = 'KC-GRANT-V1'
        deviceCode = $Code.Trim().ToUpperInvariant()
        issuedUtc  = $now.ToString('o')
        expiresUtc = $now.AddHours($Hours).ToString('o')
    }
    Write-ProtectedLicenseData -Data $data -Path $Path -Purpose 'DEG-KC-LICENSE-GRANT-V1'
}

function Test-ProtectedLicenseGrant {
    param([string]$Path, [string]$Code, [int]$Hours)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    $data = Read-ProtectedLicenseData -Path $Path -Purpose 'DEG-KC-LICENSE-GRANT-V1'
    $valid = $false
    try {
        if ($null -eq $data -or $data.version -cne 'KC-GRANT-V1') { return $false }
        if ([string]$data.deviceCode -cne $Code.Trim().ToUpperInvariant()) { return $false }
        $issued = [DateTimeOffset]::Parse([string]$data.issuedUtc, [Globalization.CultureInfo]::InvariantCulture)
        $expires = [DateTimeOffset]::Parse([string]$data.expiresUtc, [Globalization.CultureInfo]::InvariantCulture)
        $now = [DateTimeOffset]::UtcNow
        if ($issued -gt $now.AddMinutes(5)) { return $false }
        if ($expires -le $now) { return $false }
        if ($expires -le $issued) { return $false }
        if ($expires -gt $issued.AddHours($Hours).AddMinutes(1)) { return $false }
        $valid = $true
        return $true
    } catch {
        return $false
    } finally {
        if (-not $valid) { Remove-LicenseFile -Path $Path }
    }
}

function Get-WindowsBootToken {
    try {
        $boot = (Get-CimInstance Win32_OperatingSystem -ErrorAction Stop).LastBootUpTime
        return ([DateTime]$boot).ToUniversalTime().Ticks.ToString([Globalization.CultureInfo]::InvariantCulture)
    } catch {
        $os = Get-WmiObject Win32_OperatingSystem -ErrorAction Stop
        $boot = [Management.ManagementDateTimeConverter]::ToDateTime([string]$os.LastBootUpTime)
        return $boot.ToUniversalTime().Ticks.ToString([Globalization.CultureInfo]::InvariantCulture)
    }
}

function Write-ProtectedSessionOverride {
    param([string]$Path, [string]$Code)
    $data = [pscustomobject]@{
        version    = 'KC-BOOT-OVERRIDE-V1'
        deviceCode = $Code.Trim().ToUpperInvariant()
        bootToken  = Get-WindowsBootToken
    }
    Write-ProtectedLicenseData -Data $data -Path $Path -Purpose 'DEG-KC-BOOT-OVERRIDE-V1'
}

function Test-ProtectedSessionOverride {
    param([string]$Path, [string]$Code)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    $data = Read-ProtectedLicenseData -Path $Path -Purpose 'DEG-KC-BOOT-OVERRIDE-V1'
    $valid = $false
    try {
        if ($null -eq $data -or $data.version -cne 'KC-BOOT-OVERRIDE-V1') { return $false }
        if ([string]$data.deviceCode -cne $Code.Trim().ToUpperInvariant()) { return $false }
        if ([string]$data.bootToken -cne (Get-WindowsBootToken)) { return $false }
        $valid = $true
        return $true
    } catch {
        return $false
    } finally {
        if (-not $valid) { Remove-LicenseFile -Path $Path }
    }
}

function Get-RemoteUtf8TextNoCache {
    param([string]$Url, [string]$UserAgent = 'DEG-License-Check')
    if ([string]::IsNullOrWhiteSpace($Url)) { throw 'Uzak lisans adresi verilmedi.' }
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
        $request.UserAgent = $UserAgent
        $request.CachePolicy = New-Object Net.Cache.RequestCachePolicy([Net.Cache.RequestCacheLevel]::NoCacheNoStore)
        $response = $request.GetResponse()
        $reader = New-Object IO.StreamReader($response.GetResponseStream(), [Text.Encoding]::UTF8, $true)
        $content = $reader.ReadToEnd()
        if ($content.Length -gt 8192) { throw 'Uzak lisans yaniti beklenenden buyuk.' }
        return $content
    } finally {
        if ($null -ne $reader) { $reader.Dispose() }
        if ($null -ne $response) { $response.Dispose() }
    }
}

function Test-RemoteDeviceMarker {
    param([string]$BaseUrl, [string]$Code)
    if (-not (Test-DeviceCodeFormat -Code $Code)) { return $false }
    $normalizedCode = $Code.Trim().ToUpperInvariant()
    $url = $BaseUrl.TrimEnd('/') + '/' + [Uri]::EscapeDataString($normalizedCode + '.lic')
    try {
        $content = Get-RemoteUtf8TextNoCache -Url $url -UserAgent 'DEG-Device-License-Check'
        return $content.Trim() -ceq $normalizedCode
    } catch [Net.WebException] {
        if ($null -ne $_.Exception.Response -and [int]$_.Exception.Response.StatusCode -eq 404) {
            return $false
        }
        throw
    }
}

function Invoke-DeviceLicenseCheck {
    param([string]$Code)
    if (-not (Test-DeviceCodeFormat -Code $Code)) { return 'DENIED|INVALID_DEVICE_CODE' }
    $normalizedCode = $Code.Trim().ToUpperInvariant()

    if (Test-ProtectedSessionOverride -Path $LicenseOverridePath -Code $normalizedCode) {
        return 'OK|OVERRIDE'
    }
    if (Test-ProtectedLicenseGrant -Path $LicenseGrantPath -Code $normalizedCode -Hours $LicenseGrantHours) {
        return 'OK|GRANT'
    }

    try {
        if (Test-RemoteDeviceMarker -BaseUrl $LicenseMarkerBaseUrl -Code $normalizedCode) {
            Write-ProtectedLicenseGrant -Path $LicenseGrantPath -Code $normalizedCode -Hours $LicenseGrantHours
            return 'OK|ONLINE'
        }
        return 'DENIED|MARKER_NOT_FOUND'
    } catch {
        try {
            [IO.File]::WriteAllText($LogPath, ($_ | Out-String), (New-Object Text.UTF8Encoding($false)))
        } catch { }
        return 'OFFLINE|REMOTE_CHECK_FAILED'
    }
}

$script:UpdateWindow = $null
$script:UpdateStatus = $null
$script:UpdateDetail = $null
$script:UpdateBar = $null
$script:UpdateDownloadedBytes = [long]0
$script:UpdateTotalBytes = [long]0

function Initialize-UpdateProgressWindow {
    if (-not $ShowProgress) { return }
    Add-Type -AssemblyName PresentationFramework
    Add-Type -AssemblyName PresentationCore
    Add-Type -AssemblyName WindowsBase
    $xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="DEG Guncelleme" Width="520" Height="210"
        WindowStartupLocation="CenterScreen" ResizeMode="NoResize"
        Topmost="True" ShowInTaskbar="True" Background="#F8FAFC">
  <Grid Margin="22">
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="*"/>
    </Grid.RowDefinitions>
    <TextBlock Text="DEG guncelleniyor" FontSize="20" FontWeight="SemiBold" Foreground="#111827"/>
    <TextBlock x:Name="StatusText" Grid.Row="1" Margin="0,16,0,8" Text="Hazirlaniyor..." FontSize="14" Foreground="#1F2937"/>
    <ProgressBar x:Name="ProgressBar" Grid.Row="2" Height="18" Minimum="0" Maximum="100" Value="0"/>
    <TextBlock x:Name="DetailText" Grid.Row="3" Margin="0,9,0,0" Text="" FontSize="12" Foreground="#64748B" TextWrapping="Wrap"/>
  </Grid>
</Window>
'@
    $reader = New-Object Xml.XmlNodeReader ([xml]$xaml)
    $script:UpdateWindow = [Windows.Markup.XamlReader]::Load($reader)
    $script:UpdateStatus = $script:UpdateWindow.FindName('StatusText')
    $script:UpdateDetail = $script:UpdateWindow.FindName('DetailText')
    $script:UpdateBar = $script:UpdateWindow.FindName('ProgressBar')
    [void]$script:UpdateWindow.Show()
    [void]$script:UpdateWindow.Dispatcher.Invoke([Action]{}, [Windows.Threading.DispatcherPriority]::Render)
}

function Set-UpdateProgress {
    param(
        [string]$Status,
        [int]$Value,
        [string]$Detail = ''
    )
    if ($null -eq $script:UpdateWindow) { return }
    $script:UpdateStatus.Text = $Status
    $script:UpdateDetail.Text = $Detail
    $script:UpdateBar.Value = [Math]::Max(0, [Math]::Min(100, $Value))
    [void]$script:UpdateWindow.Dispatcher.Invoke([Action]{}, [Windows.Threading.DispatcherPriority]::Render)
}

function Close-UpdateProgressWindow {
    if ($null -ne $script:UpdateWindow) {
        try { $script:UpdateWindow.Close() } catch { }
    }
    $script:UpdateWindow = $null
    $script:UpdateStatus = $null
    $script:UpdateDetail = $null
    $script:UpdateBar = $null
}

function Finish-UpdateProgressWindow {
    if ($null -eq $script:UpdateWindow) { return }
    $resultPath = $StatePath + '.result'
    $result = if (Test-Path -LiteralPath $resultPath) { [IO.File]::ReadAllText($resultPath).Trim() } else { 'FAILED|RESULT_MISSING' }
    if ($result -like 'UPDATED|PENDING|*') {
        Set-UpdateProgress -Status 'Dosyalar indirildi' -Value 100 -Detail 'Kurulum CAD kapatildiginda otomatik tamamlanacak.'
        Start-Sleep -Milliseconds 1200
    } elseif ($result -like 'UPDATED|*') {
        Set-UpdateProgress -Status 'Guncelleme tamamlandi' -Value 100 -Detail 'CAD programini yeniden baslatin.'
        Start-Sleep -Milliseconds 900
    } elseif ($result -like 'CURRENT|*') {
        Set-UpdateProgress -Status 'Dosyalar zaten guncel' -Value 100 -Detail ''
        Start-Sleep -Milliseconds 700
    } else {
        $failureDetail = 'Bilinmeyen guncelleme hatasi.'
        if ($result -like 'FAILED|*' -and $result.Length -gt 7) {
            $failureDetail = $result.Substring(7).Trim()
        }
        Set-UpdateProgress -Status 'Guncelleme tamamlanamadi' -Value 100 -Detail $failureDetail
        Start-Sleep -Milliseconds 450
        Close-UpdateProgressWindow
        [void][Windows.MessageBox]::Show(
            "Guncelleme tamamlanamadi.`n`n$failureDetail`n`nGunluk: $LogPath",
            'DEG Guncelleme',
            [Windows.MessageBoxButton]::OK,
            [Windows.MessageBoxImage]::Error)
        return
    }
    Close-UpdateProgressWindow
}

function Quote-ProcessArgument {
    param([string]$Value)
    return '"' + $Value.Replace('"', '\"') + '"'
}

function Save-RemoteUpdateFileOnce {
    param(
        [string]$Url,
        [string]$Destination,
        [string]$DisplayName = ''
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
        $request.AutomaticDecompression = [Net.DecompressionMethods]::GZip -bor [Net.DecompressionMethods]::Deflate
        if ($null -ne $request.Proxy) {
            $request.Proxy.Credentials = [Net.CredentialCache]::DefaultNetworkCredentials
        }
        $request.CachePolicy = New-Object Net.Cache.RequestCachePolicy([Net.Cache.RequestCacheLevel]::NoCacheNoStore)
        $response = $request.GetResponse()
        $inputStream = $response.GetResponseStream()
        $outputStream = [IO.File]::Open($Destination, [IO.FileMode]::Create, [IO.FileAccess]::Write, [IO.FileShare]::None)
        $buffer = New-Object byte[] 65536
        while (($read = $inputStream.Read($buffer, 0, $buffer.Length)) -gt 0) {
            $outputStream.Write($buffer, 0, $read)
            $script:UpdateDownloadedBytes += [long]$read
            if ($script:UpdateTotalBytes -gt 0) {
                $ratio = [Math]::Min(1.0, [double]$script:UpdateDownloadedBytes / [double]$script:UpdateTotalBytes)
                $value = 30 + [int][Math]::Floor(45.0 * $ratio)
                $detail = ('{0:N1} / {1:N1} MB' -f ($script:UpdateDownloadedBytes / 1MB), ($script:UpdateTotalBytes / 1MB))
                Set-UpdateProgress -Status ('Indiriliyor: ' + $DisplayName) -Value $value -Detail $detail
            }
        }
    } finally {
        if ($null -ne $outputStream) { $outputStream.Dispose() }
        if ($null -ne $inputStream) { $inputStream.Dispose() }
        if ($null -ne $response) { $response.Dispose() }
    }
}

function Save-RemoteUpdateFile {
    param(
        [string]$Url,
        [string]$Destination,
        [string]$DisplayName = ''
    )

    $downloadedBefore = $script:UpdateDownloadedBytes
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        try {
            Save-RemoteUpdateFileOnce -Url $Url -Destination $Destination -DisplayName $DisplayName
            return
        } catch {
            $script:UpdateDownloadedBytes = $downloadedBefore
            if (Test-Path -LiteralPath $Destination) {
                Remove-Item -LiteralPath $Destination -Force -ErrorAction SilentlyContinue
            }
            if ($attempt -ge 3) { throw }
            Set-UpdateProgress -Status ('Baglanti yeniden deneniyor: ' + $DisplayName) -Value 28 -Detail ('Deneme ' + ($attempt + 1) + ' / 3')
            Start-Sleep -Milliseconds (700 * $attempt)
        }
    }
}

function Get-UpdateFileNames {
    return @('DG_DO_R05.VLX', 'DG_DT_TAVA_PALET.ps1', 'DG_WINDOWS_UI.ps1')
}

function Get-GitHubJsonOnce {
    param([string]$Url)

    $uri = [Uri]$Url
    if ($uri.IsFile) {
        return ([IO.File]::ReadAllText($uri.LocalPath, [Text.Encoding]::UTF8) | ConvertFrom-Json)
    }

    [Net.ServicePointManager]::SecurityProtocol =
        [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    $headers = @{
        'Accept' = 'application/vnd.github+json'
        'X-GitHub-Api-Version' = '2022-11-28'
    }
    $separator = if ($Url.Contains('?')) { '&' } else { '?' }
    $fetchUrl = $Url + $separator + 'kc_nonce=' + [DateTime]::UtcNow.Ticks
    $request = [Net.HttpWebRequest]::Create($fetchUrl)
    $request.Method = 'GET'
    $request.Timeout = 15000
    $request.ReadWriteTimeout = 15000
    $request.UserAgent = 'DEG-Auto-Update'
    $request.Accept = $headers.Accept
    $request.Headers['X-GitHub-Api-Version'] = $headers['X-GitHub-Api-Version']
    $request.AutomaticDecompression = [Net.DecompressionMethods]::GZip -bor [Net.DecompressionMethods]::Deflate
    if ($null -ne $request.Proxy) {
        $request.Proxy.Credentials = [Net.CredentialCache]::DefaultNetworkCredentials
    }
    $request.CachePolicy = New-Object Net.Cache.RequestCachePolicy([Net.Cache.RequestCacheLevel]::NoCacheNoStore)
    $response = $null
    $reader = $null
    try {
        $response = $request.GetResponse()
        $reader = New-Object IO.StreamReader($response.GetResponseStream(), [Text.Encoding]::UTF8, $true)
        return ($reader.ReadToEnd() | ConvertFrom-Json)
    } finally {
        if ($null -ne $reader) { $reader.Dispose() }
        if ($null -ne $response) { $response.Dispose() }
    }
}

function Get-GitHubJson {
    param([string]$Url)

    for ($attempt = 1; $attempt -le 3; $attempt++) {
        try {
            return Get-GitHubJsonOnce -Url $Url
        } catch {
            if ($attempt -ge 3) { throw }
            Set-UpdateProgress -Status 'GitHub baglantisi yeniden deneniyor' -Value 8 -Detail ('Deneme ' + ($attempt + 1) + ' / 3')
            Start-Sleep -Milliseconds (700 * $attempt)
        }
    }
}

function Get-GitBlobSha {
    param([string]$Path)

    $bytes = [IO.File]::ReadAllBytes($Path)
    $header = [Text.Encoding]::ASCII.GetBytes(('blob ' + $bytes.Length + [char]0))
    $payload = New-Object byte[] ($header.Length + $bytes.Length)
    [Array]::Copy($header, 0, $payload, 0, $header.Length)
    [Array]::Copy($bytes, 0, $payload, $header.Length, $bytes.Length)
    $sha1 = [Security.Cryptography.SHA1]::Create()
    try {
        return (($sha1.ComputeHash($payload) | ForEach-Object { $_.ToString('x2') }) -join '')
    } finally {
        $sha1.Dispose()
    }
}

function Get-UpdateFileMetadata {
    param([object[]]$Contents)

    $metadata = @{}
    foreach ($name in (Get-UpdateFileNames)) {
        $item = @($Contents | Where-Object { [string]$_.name -ieq $name })
        if ($item.Count -ne 1 -or
            [string]$item[0].type -cne 'file' -or
            [long]$item[0].size -le 0 -or
            [string]::IsNullOrWhiteSpace([string]$item[0].download_url) -or
            [string]$item[0].sha -notmatch '^[0-9A-Fa-f]{40}$') {
            throw ($name + ' GitHub bilgisinde eksik veya gecersiz.')
        }
        $metadata[$name] = $item[0]
    }
    return $metadata
}

function Test-FileMatchesMetadata {
    param(
        [string]$Path,
        [object]$Metadata
    )

    try {
        if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $false }
        if ((Get-Item -LiteralPath $Path).Length -ne [long]$Metadata.size) { return $false }
        return ((Get-GitBlobSha -Path $Path) -ceq ([string]$Metadata.sha).ToLowerInvariant())
    } catch {
        return $false
    }
}

function Test-InstalledFilesMatchMetadata {
    param(
        [string]$Directory,
        [hashtable]$Metadata
    )

    foreach ($name in (Get-UpdateFileNames)) {
        $path = Join-Path $Directory $name
        if (-not (Test-FileMatchesMetadata -Path $path -Metadata $Metadata[$name])) { return $false }
    }
    return $true
}

function Get-FileSha256 {
    param([string]$Path)

    $sha256 = [Security.Cryptography.SHA256]::Create()
    $stream = $null
    try {
        $stream = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
        return (($sha256.ComputeHash($stream) | ForEach-Object { $_.ToString('x2') }) -join '')
    } finally {
        if ($null -ne $stream) { $stream.Dispose() }
        $sha256.Dispose()
    }
}

function Resolve-UpdateRawBaseUrl {
    if (-not [string]::IsNullOrWhiteSpace($UpdateRawBaseUrl)) {
        return $UpdateRawBaseUrl.TrimEnd('/')
    }

    $match = [regex]::Match(
        $UpdateContentsApiUrl,
        '^https://api\.github\.com/repos/([^/]+)/([^/]+)/contents/(.+?)(?:\?.*)?$',
        [Text.RegularExpressions.RegexOptions]::IgnoreCase)
    if (-not $match.Success) {
        throw 'GitHub ham dosya adresi olusturulamadi.'
    }
    $branch = 'main'
    $branchMatch = [regex]::Match($UpdateApiUrl, '(?:[?&])sha=([^&]+)', [Text.RegularExpressions.RegexOptions]::IgnoreCase)
    if ($branchMatch.Success) {
        $branch = [Uri]::UnescapeDataString($branchMatch.Groups[1].Value)
    }
    return ('https://raw.githubusercontent.com/{0}/{1}/refs/heads/{2}/{3}' -f
        $match.Groups[1].Value,
        $match.Groups[2].Value,
        $branch,
        $match.Groups[3].Value.Trim('/'))
}

function Get-StagedUpdateToken {
    param([string]$StageDirectory)

    $lines = foreach ($name in (Get-UpdateFileNames)) {
        $path = Join-Path $StageDirectory $name
        $item = Get-Item -LiteralPath $path
        $name.ToLowerInvariant() + '|' + $item.Length + '|' + (Get-FileSha256 -Path $path)
    }
    $bytes = [Text.Encoding]::UTF8.GetBytes(($lines -join "`n"))
    $sha256 = [Security.Cryptography.SHA256]::Create()
    try {
        $hash = (($sha256.ComputeHash($bytes) | ForEach-Object { $_.ToString('x2') }) -join '')
    } finally {
        $sha256.Dispose()
    }
    return ('files-' + $hash)
}

function Test-StagedFilesMatchInstalled {
    param(
        [string]$StageDirectory,
        [string]$Directory
    )

    try {
        foreach ($name in (Get-UpdateFileNames)) {
            $staged = Join-Path $StageDirectory $name
            $installed = Join-Path $Directory $name
            if (-not (Test-Path -LiteralPath $installed -PathType Leaf)) { return $false }
            if ((Get-Item -LiteralPath $staged).Length -ne (Get-Item -LiteralPath $installed).Length) { return $false }
            if ((Get-FileSha256 -Path $staged) -cne (Get-FileSha256 -Path $installed)) { return $false }
        }
        return $true
    } catch {
        return $false
    }
}

function Test-StagedUpdateFiles {
    param([string]$StageDirectory)

    foreach ($name in (Get-UpdateFileNames)) {
        $path = Join-Path $StageDirectory $name
        if (-not (Test-Path -LiteralPath $path -PathType Leaf) -or (Get-Item -LiteralPath $path).Length -le 0) {
            throw ($name + ' indirilemedi veya bos geldi.')
        }
        $firstLine = [IO.File]::ReadLines($path) | Select-Object -First 1
        if ([string]$firstLine -like 'version https://git-lfs.github.com/spec/*') {
            throw ($name + ' yerine Git LFS isaret dosyasi indirildi.')
        }
    }
    Test-PowerShellSyntax -Path (Join-Path $StageDirectory 'DG_DT_TAVA_PALET.ps1')
    Test-PowerShellSyntax -Path (Join-Path $StageDirectory 'DG_WINDOWS_UI.ps1')
}

function Write-UpdateCommitBestEffort {
    param(
        [string]$Path,
        [string]$CommitSha
    )

    try {
        Write-UpdateCommit -Path $Path -CommitSha $CommitSha
        return $true
    } catch {
        try {
            Add-Content -LiteralPath $LogPath -Value ("`r`nUyari: Surum kaydi yazilamadi: " + $_.Exception.Message) -Encoding UTF8
        } catch { }
        return $false
    }
}

function Test-PowerShellSyntax {
    param([string]$Path)

    $tokens = $null
    $errors = $null
    [void][Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
    if (@($errors).Count -gt 0) {
        throw ((Split-Path -Leaf $Path) + ' PowerShell soz dizimi gecersiz.')
    }
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

function Grant-UpdateTargetWriteAccess {
    param(
        [string]$Directory,
        [string]$UserSid
    )

    if ([string]::IsNullOrWhiteSpace($UserSid)) {
        $UserSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    }
    $identity = New-Object Security.Principal.SecurityIdentifier($UserSid)
    $rights = [Security.AccessControl.FileSystemRights]::Modify
    $inheritance = [Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit'
    $propagation = [Security.AccessControl.PropagationFlags]::None
    $rule = New-Object Security.AccessControl.FileSystemAccessRule($identity, $rights, $inheritance, $propagation, [Security.AccessControl.AccessControlType]::Allow)
    $acl = Get-Acl -LiteralPath $Directory
    $acl.SetAccessRule($rule)
    Set-Acl -LiteralPath $Directory -AclObject $acl
}

function Write-UpdateCommit {
    param(
        [string]$Path,
        [string]$CommitSha
    )

    $directory = Split-Path -Parent $Path
    if (-not [string]::IsNullOrWhiteSpace($directory)) {
        [void](New-Item -ItemType Directory -Path $directory -Force)
    }
    [IO.File]::WriteAllText($Path, $CommitSha.ToLowerInvariant(), (New-Object Text.UTF8Encoding($false)))
}

function Get-DeepestException {
    param([object]$ErrorRecord)

    $exception = if ($null -ne $ErrorRecord -and $null -ne $ErrorRecord.Exception) {
        $ErrorRecord.Exception
    } elseif ($ErrorRecord -is [Exception]) {
        $ErrorRecord
    } else {
        $null
    }
    while ($null -ne $exception -and $null -ne $exception.InnerException) {
        $exception = $exception.InnerException
    }
    return $exception
}

function Remove-FileReadOnlyAttribute {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return }
    $attributes = [IO.File]::GetAttributes($Path)
    if (($attributes -band [IO.FileAttributes]::ReadOnly) -ne 0) {
        [IO.File]::SetAttributes($Path, ($attributes -band (-bnot [IO.FileAttributes]::ReadOnly)))
    }
}

function Install-OneStagedFile {
    param([object]$Record)

    $lastError = $null
    for ($attempt = 1; $attempt -le 6; $attempt++) {
        try {
            if ($Record.HadOriginal) {
                Remove-FileReadOnlyAttribute -Path $Record.Target
                try {
                    [IO.File]::Replace($Record.Incoming, $Record.Target, $null, $true)
                } catch {
                    [IO.File]::Copy($Record.Incoming, $Record.Target, $true)
                    Remove-Item -LiteralPath $Record.Incoming -Force -ErrorAction SilentlyContinue
                }
            } else {
                Move-Item -LiteralPath $Record.Incoming -Destination $Record.Target -Force
            }
            return
        } catch {
            $lastError = $_
            if ($attempt -lt 6) { Start-Sleep -Milliseconds (350 * $attempt) }
        }
    }

    $deepest = Get-DeepestException -ErrorRecord $lastError
    $message = $Record.Name + ' kurulamadi: ' + $(if ($null -ne $deepest) { $deepest.Message } else { [string]$lastError })
    if ($deepest -is [UnauthorizedAccessException]) {
        throw [UnauthorizedAccessException]::new($message, $deepest)
    }
    if ($deepest -is [IO.IOException]) {
        throw [IO.IOException]::new($message, $deepest)
    }
    throw $message
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
                Name = $name
                Target = $target
                Incoming = $incoming
                Backup = $backup
                HadOriginal = $hadOriginal
                Installed = $false
            }
        }

        foreach ($record in $records) {
            Install-OneStagedFile -Record $record
            $record.Installed = $true
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

function Test-DeferredInstallCandidate {
    param([object]$ErrorRecord)

    $exception = if ($null -ne $ErrorRecord) { $ErrorRecord.Exception } else { $null }
    while ($null -ne $exception) {
        if ($exception -is [UnauthorizedAccessException]) { return $false }
        if ($exception -is [IO.IOException]) { return $true }
        $exception = $exception.InnerException
    }
    return $false
}

function Get-UpdateHostProcessId {
    if ($HostPid -gt 0) { return $HostPid }

    try {
        $processId = $PID
        for ($depth = 0; $depth -lt 5; $depth++) {
            $processInfo = Get-CimInstance Win32_Process -Filter ('ProcessId=' + $processId) -ErrorAction Stop
            $processId = [int]$processInfo.ParentProcessId
            if ($processId -le 0) { break }
            $parent = Get-Process -Id $processId -ErrorAction Stop
            if ($parent.ProcessName -match '^(acad|gcad|gstarcad)$') { return $processId }
        }
    } catch { }
    return 0
}

function Get-PendingUpdateArguments {
    param(
        [string]$ScriptPath,
        [string]$PendingPath,
        [string]$Version,
        [int]$CadProcessId
    )

    return (
        '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File ' + (Quote-ProcessArgument $ScriptPath) +
        ' -Mode ApplyPending -StatePath ' + (Quote-ProcessArgument (Join-Path $PendingPath 'apply.state')) +
        ' -TargetDirectory ' + (Quote-ProcessArgument $TargetDirectory) +
        ' -UpdateStatePath ' + (Quote-ProcessArgument $UpdateStatePath) +
        ' -PendingDirectory ' + (Quote-ProcessArgument $PendingPath) +
        ' -PendingVersion ' + (Quote-ProcessArgument $Version) +
        ' -WaitForPid ' + $CadProcessId)
}

function Queue-PendingUpdate {
    param(
        [string]$StageDirectory,
        [string]$Version
    )

    $pendingPath = Join-Path $TargetDirectory ('.deg_update_pending_' + [guid]::NewGuid().ToString('N'))
    [void](New-Item -ItemType Directory -Path $pendingPath -Force)
    foreach ($name in (Get-UpdateFileNames)) {
        Copy-Item -LiteralPath (Join-Path $StageDirectory $name) -Destination (Join-Path $pendingPath $name) -Force
    }
    Test-StagedUpdateFiles -StageDirectory $pendingPath

    $pendingScript = Join-Path $pendingPath 'DG_WINDOWS_UI.ps1'
    $cadProcessId = Get-UpdateHostProcessId
    $arguments = Get-PendingUpdateArguments -ScriptPath $pendingScript -PendingPath $pendingPath -Version $Version -CadProcessId $cadProcessId
    $runOnceRegistered = $false
    $helperStarted = $false
    $runOncePath = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\RunOnce'
    try {
        [void](New-Item -Path $runOncePath -Force)
        Set-ItemProperty -Path $runOncePath -Name 'DEG_Pending_Update' -Value ('powershell.exe ' + $arguments) -Force
        $runOnceRegistered = $true
    } catch { }
    try {
        [void](Start-Process -FilePath 'powershell.exe' -ArgumentList $arguments -WindowStyle Hidden -PassThru)
        $helperStarted = $true
    } catch { }
    if (-not $runOnceRegistered -and -not $helperStarted) {
        throw 'Bekleyen guncelleme icin arka plan kurucusu baslatilamadi.'
    }
    return $pendingPath
}

function Invoke-PendingUpdate {
    if ([string]::IsNullOrWhiteSpace($PendingDirectory) -or
        [string]::IsNullOrWhiteSpace($TargetDirectory) -or
        [string]::IsNullOrWhiteSpace($PendingVersion) -or
        -not (Test-Path -LiteralPath $PendingDirectory -PathType Container) -or
        -not (Test-Path -LiteralPath $TargetDirectory -PathType Container)) {
        Write-UpdateResult 'FAILED|Bekleyen guncelleme bilgisi gecersiz.'
        return
    }

    if ($WaitForPid -gt 0) {
        try {
            $waitProcess = Get-Process -Id $WaitForPid -ErrorAction Stop
            $waitProcess.WaitForExit()
        } catch { }
    }
    Start-Sleep -Milliseconds 800

    $deadline = [DateTime]::UtcNow.AddHours(12)
    while ($true) {
        try {
            Install-StagedUpdate -StageDirectory $PendingDirectory -Directory $TargetDirectory
            [void](Write-UpdateCommitBestEffort -Path $UpdateStatePath -CommitSha $PendingVersion)
            Write-UpdateResult ('UPDATED|' + $PendingVersion)
            try {
                Remove-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\RunOnce' -Name 'DEG_Pending_Update' -ErrorAction SilentlyContinue
            } catch { }
            Start-Sleep -Milliseconds 200
            try { [IO.Directory]::Delete([IO.Path]::GetFullPath($PendingDirectory), $true) } catch { }
            return
        } catch {
            if ((Test-DeferredInstallCandidate -ErrorRecord $_) -and [DateTime]::UtcNow -lt $deadline) {
                Start-Sleep -Seconds 2
            } else {
                Write-UpdateFailure -ErrorRecord $_ -Context 'Bekleyen guncelleme kurulamadi'
                return
            }
        }
    }
}

function Invoke-ElevatedUpdate {
    $requestingUserSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $arguments =
        '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File ' + (Quote-ProcessArgument $PSCommandPath) +
        ' -Mode Update -StatePath ' + (Quote-ProcessArgument $StatePath) +
        ' -UpdateApiUrl ' + (Quote-ProcessArgument $UpdateApiUrl) +
        ' -UpdateContentsApiUrl ' + (Quote-ProcessArgument $UpdateContentsApiUrl) +
        ' -UpdateRawBaseUrl ' + (Quote-ProcessArgument $UpdateRawBaseUrl) +
        ' -TargetDirectory ' + (Quote-ProcessArgument $TargetDirectory) +
        ' -UpdateStatePath ' + (Quote-ProcessArgument $UpdateStatePath) +
        ' -UpdateUserSid ' + (Quote-ProcessArgument $requestingUserSid) +
        ' -ElevatedUpdate'
    if ($ShowProgress) { $arguments += ' -ShowProgress' }
    if ($ShowProgress) {
        Set-UpdateProgress -Status 'Yonetici izni bekleniyor' -Value 24 -Detail 'Bu izin yalnizca sonraki guncellemeleri izinsiz yapabilmek icin bir kez gereklidir.'
        Start-Sleep -Milliseconds 250
        Close-UpdateProgressWindow
    }
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

    if ([string]::IsNullOrWhiteSpace($UpdateApiUrl) -or
        [string]::IsNullOrWhiteSpace($UpdateContentsApiUrl) -or
        [string]::IsNullOrWhiteSpace($TargetDirectory) -or
        [string]::IsNullOrWhiteSpace($UpdateStatePath) -or
        -not (Test-Path -LiteralPath $TargetDirectory -PathType Container)) {
        Write-UpdateResult 'FAILED|Guncelleme yolu gecersiz.'
        return
    }

    $stageDirectory = Join-Path $env:TEMP ('DEG_update_' + [guid]::NewGuid().ToString('N'))
    try {
        $localVersion = ''
        if (Test-Path -LiteralPath $UpdateStatePath -PathType Leaf) {
            try { $localVersion = [IO.File]::ReadAllText($UpdateStatePath).Trim().ToLowerInvariant() } catch { $localVersion = '' }
        }

        $metadata = $null
        $remoteVersion = ''
        $apiError = $null
        Set-UpdateProgress -Status 'Guncelleme bilgisi kontrol ediliyor' -Value 5 -Detail 'GitHub baglantisi kuruluyor...'
        try {
            $commits = @(Get-GitHubJson -Url $UpdateApiUrl)
            if ($commits.Count -lt 1 -or [string]$commits[0].sha -notmatch '^[0-9A-Fa-f]{40,64}$') {
                throw 'GitHub guncelleme commit bilgisi gecersiz.'
            }
            $remoteVersion = ([string]$commits[0].sha).ToLowerInvariant()
            if ($localVersion -ceq $remoteVersion) {
                Write-UpdateResult ('CURRENT|' + $remoteVersion)
                return
            }

            Set-UpdateProgress -Status 'Dosya listesi aliniyor' -Value 15 -Detail 'Yeni surum bulundu.'
            $contentsSeparator = if ($UpdateContentsApiUrl.Contains('?')) { '&' } else { '?' }
            $contentsUrl = $UpdateContentsApiUrl + $contentsSeparator + 'ref=' + [Uri]::EscapeDataString($remoteVersion)
            $metadata = Get-UpdateFileMetadata -Contents @(Get-GitHubJson -Url $contentsUrl)
            if (Test-InstalledFilesMatchMetadata -Directory $TargetDirectory -Metadata $metadata) {
                [void](Write-UpdateCommitBestEffort -Path $UpdateStatePath -CommitSha $remoteVersion)
                Write-UpdateResult ('CURRENT|' + $remoteVersion)
                return
            }
        } catch {
            $apiError = $_
            $metadata = $null
        }

        [void](New-Item -ItemType Directory -Path $stageDirectory -Force)
        $script:UpdateDownloadedBytes = [long]0
        if ($null -ne $metadata) {
            $script:UpdateTotalBytes = [long](($metadata.Values | Measure-Object -Property size -Sum).Sum)
            foreach ($name in (Get-UpdateFileNames)) {
                $destination = Join-Path $stageDirectory $name
                Save-RemoteUpdateFile -Url ([string]$metadata[$name].download_url) -Destination $destination -DisplayName $name
                if (-not (Test-FileMatchesMetadata -Path $destination -Metadata $metadata[$name])) {
                    throw ($name + ' Git blob SHA dogrulamasi basarisiz.')
                }
            }
        } else {
            $apiSummary = Get-UpdateErrorSummary -ErrorRecord $apiError
            Set-UpdateProgress -Status 'Alternatif indirme baglantisi kullaniliyor' -Value 20 -Detail $apiSummary
            try {
                $rawBase = Resolve-UpdateRawBaseUrl
                $script:UpdateTotalBytes = [long]0
                $rawIndex = 0
                foreach ($name in (Get-UpdateFileNames)) {
                    $rawIndex++
                    Set-UpdateProgress -Status ('Indiriliyor: ' + $name) -Value (20 + ($rawIndex * 15)) -Detail 'GitHub ham dosya baglantisi'
                    $destination = Join-Path $stageDirectory $name
                    Save-RemoteUpdateFile -Url ($rawBase.TrimEnd('/') + '/' + [Uri]::EscapeDataString($name)) -Destination $destination -DisplayName $name
                }
                Test-StagedUpdateFiles -StageDirectory $stageDirectory
                $remoteVersion = Get-StagedUpdateToken -StageDirectory $stageDirectory
                if ($localVersion -ceq $remoteVersion -or
                    (Test-StagedFilesMatchInstalled -StageDirectory $stageDirectory -Directory $TargetDirectory)) {
                    [void](Write-UpdateCommitBestEffort -Path $UpdateStatePath -CommitSha $remoteVersion)
                    Write-UpdateResult ('CURRENT|' + $remoteVersion)
                    return
                }
            } catch {
                $rawSummary = Get-UpdateErrorSummary -ErrorRecord $_
                throw ('GitHub API: ' + $apiSummary + ' Ham dosya baglantisi: ' + $rawSummary)
            }
        }

        Set-UpdateProgress -Status 'Dosyalar dogrulaniyor' -Value 78 -Detail 'Dosya ve PowerShell kontrolleri yapiliyor.'
        Test-StagedUpdateFiles -StageDirectory $stageDirectory

        if ($ElevatedUpdate) {
            try { Grant-UpdateTargetWriteAccess -Directory $TargetDirectory -UserSid $UpdateUserSid } catch { }
        }
        Set-UpdateProgress -Status 'Kurulum klasoru denetleniyor' -Value 82 -Detail $TargetDirectory
        if (-not (Test-UpdateTargetWritable -Directory $TargetDirectory)) {
            if (-not $ElevatedUpdate) {
                try { Invoke-ElevatedUpdate } catch { Write-UpdateFailure -ErrorRecord $_ -Context 'Yonetici izni alinamadi' }
            } else {
                Write-UpdateResult 'FAILED|Hedef klasore yazilamadi. Klasor izinlerini kontrol edin.'
            }
            return
        }

        Set-UpdateProgress -Status 'Yeni surum kuruluyor' -Value 88 -Detail $TargetDirectory
        try {
            Install-StagedUpdate -StageDirectory $stageDirectory -Directory $TargetDirectory
        } catch {
            $directInstallError = $_
            if (Test-DeferredInstallCandidate -ErrorRecord $_) {
                $pendingPath = Queue-PendingUpdate -StageDirectory $stageDirectory -Version $remoteVersion
                try {
                    [IO.File]::WriteAllText(
                        (Join-Path $pendingPath 'direct_install_error.log'),
                        ($directInstallError | Out-String),
                        (New-Object Text.UTF8Encoding($false)))
                } catch { }
                Write-UpdateResult ('UPDATED|PENDING|' + $remoteVersion)
                return
            }
            throw
        }
        Set-UpdateProgress -Status 'Kurulum kaydi tamamlaniyor' -Value 96 -Detail ''
        [void](Write-UpdateCommitBestEffort -Path $UpdateStatePath -CommitSha $remoteVersion)
        Write-UpdateResult ('UPDATED|' + $remoteVersion)
    } catch {
        Write-UpdateFailure -ErrorRecord $_
    } finally {
        if (Test-Path -LiteralPath $stageDirectory) {
            Remove-Item -LiteralPath $stageDirectory -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

if ($Mode -eq 'ApplyPending') {
    Invoke-PendingUpdate
    exit 0
}

if ($Mode -eq 'Update') {
    if ($ShowProgress) { Initialize-UpdateProgressWindow }
    try {
        Invoke-DegUpdate
    } finally {
        if ($ShowProgress) { Finish-UpdateProgressWindow }
    }
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

function Get-RemoteLicenseVerifier {
    param([string]$Url)
    if ([string]::IsNullOrWhiteSpace($Url)) { return $null }
    $content = Get-RemoteUtf8TextNoCache -Url $Url -UserAgent 'DEG-Bypass-Verifier-Check'
    $value = $content.Trim().TrimStart([char]0xFEFF)
    if ($value -notmatch '^PBKDF2-SHA256\$[0-9]+\$[A-Za-z0-9+/]+={0,2}\$[A-Za-z0-9+/]+={0,2}$') {
        return $null
    }
    return $value
}

function Test-FixedTimeByteArrayEqual {
    param([byte[]]$Left, [byte[]]$Right)
    if ($null -eq $Left -or $null -eq $Right -or $Left.Length -ne $Right.Length) { return $false }
    $difference = 0
    for ($i = 0; $i -lt $Left.Length; $i++) {
        $difference = $difference -bor ($Left[$i] -bxor $Right[$i])
    }
    return $difference -eq 0
}

function Test-Pbkdf2Sha256Password {
    param([string]$Password, [string]$Verifier)
    if ([string]::IsNullOrEmpty($Password) -or [string]::IsNullOrWhiteSpace($Verifier)) { return $false }

    $derived = $null
    $expected = $null
    $salt = $null
    $pbkdf2 = $null
    try {
        $parts = $Verifier.Trim().Split('$')
        if ($parts.Count -ne 4 -or $parts[0] -cne 'PBKDF2-SHA256') { return $false }
        $iterations = 0
        if (-not [int]::TryParse($parts[1], [ref]$iterations)) { return $false }
        if ($iterations -lt 100000 -or $iterations -gt 5000000) { return $false }
        $salt = [Convert]::FromBase64String($parts[2])
        $expected = [Convert]::FromBase64String($parts[3])
        if ($salt.Length -lt 16 -or $expected.Length -lt 32 -or $expected.Length -gt 64) { return $false }

        $pbkdf2 = [Security.Cryptography.Rfc2898DeriveBytes]::new(
            $Password,
            $salt,
            $iterations,
            [Security.Cryptography.HashAlgorithmName]::SHA256)
        $derived = $pbkdf2.GetBytes($expected.Length)
        return Test-FixedTimeByteArrayEqual -Left $derived -Right $expected
    } catch {
        return $false
    } finally {
        if ($null -ne $pbkdf2) { $pbkdf2.Dispose() }
        if ($null -ne $derived) { [Array]::Clear($derived, 0, $derived.Length) }
        if ($null -ne $expected) { [Array]::Clear($expected, 0, $expected.Length) }
        if ($null -ne $salt) { [Array]::Clear($salt, 0, $salt.Length) }
    }
}

function Show-LicenseWindow {
    $lines = if (Test-Path -LiteralPath $StatePath) { [IO.File]::ReadAllLines($StatePath, [Text.Encoding]::Default) } else { @('DEG', $DeviceCode) }
    $title = if ($lines.Count -gt 0 -and -not [string]::IsNullOrWhiteSpace($lines[0])) { $lines[0] } else { 'DEG' }
    $message = if ($lines.Count -gt 1) { [string]::Join([Environment]::NewLine, $lines[1..($lines.Count - 1)]) } else { '' }
    $resultPath = $StatePath + '.result'
    if (Test-Path -LiteralPath $resultPath) { Remove-Item -LiteralPath $resultPath -Force -ErrorAction SilentlyContinue }
    $xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Width="620" MinWidth="420" MaxWidth="920"
        Height="460" MinHeight="350" MaxHeight="650"
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
      <TextBlock Grid.Column="0" Text="S&#x130;FRE:" FontWeight="SemiBold" VerticalAlignment="Center" Margin="0,0,12,0"/>
      <PasswordBox x:Name="PasswordBox" Grid.Column="1" Height="34" Padding="8,5" VerticalContentAlignment="Center"/>
    </Grid>
    <TextBlock x:Name="StatusText" Grid.Row="2" MinHeight="22" Margin="0,8,0,0" Foreground="#B91C1C"/>
    <StackPanel Grid.Row="3" Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,8,0,0">
      <Button x:Name="CopyButton" Content="Cihaz Kodunu Kopyala" Width="185" Height="34" Margin="0,0,8,0"/>
      <Button x:Name="AcceptButton" Content="Giris" Width="100" Height="34" Margin="0,0,8,0" IsDefault="True"/>
      <Button x:Name="CloseButton" Content="Kapat" Width="100" Height="34" IsCancel="True"/>
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
    $close = $window.FindName('CloseButton')
    $text.Text = $message
    if ($SelfTest) {
        Write-Output ('SELFTEST=OK;MODE=LICENSE;TITLE=' + $title)
        return
    }
    $writeResult = {
        param([string]$Value)
        [IO.File]::WriteAllText($resultPath, $Value, (New-Object Text.UTF8Encoding($false)))
    }
    $copy.Add_Click({
        if (Test-DeviceCodeFormat -Code $DeviceCode) {
            [Windows.Clipboard]::SetText($DeviceCode.Trim().ToUpperInvariant())
            $status.Text = 'Cihaz kodu panoya kopyalandi.'
        } else {
            $status.Foreground = '#B91C1C'
            $status.Text = 'Cihaz kodu olusturulamadi.'
        }
    })
    $accept.Add_Click({
        $accept.IsEnabled = $false
        $status.Text = 'Sifre kontrol ediliyor...'
        try {
            $remoteVerifier = Get-RemoteLicenseVerifier -Url $PasswordUrl
            if ([string]::IsNullOrEmpty($remoteVerifier)) {
                $status.Text = 'Bypass dogrulama degeri bulunamadi.'
            } else {
                $candidate = $password.Password
                try {
                    if (Test-Pbkdf2Sha256Password -Password $candidate -Verifier $remoteVerifier) {
                        Write-ProtectedSessionOverride -Path $LicenseOverridePath -Code $DeviceCode
                        & $writeResult 'OK'
                        $window.Close()
                    } else {
                        $status.Text = 'Sifre yanlis.'
                        $password.Clear()
                        $password.Focus()
                    }
                } finally {
                    $candidate = $null
                }
            }
        } catch {
            $status.Text = 'Sifre kontrolune ulasilamadi. Internet baglantisini kontrol edin.'
        } finally {
            $accept.IsEnabled = $true
        }
    })
    $close.Add_Click({
        & $writeResult 'CLOSED'
        $window.Close()
    })
    $window.Add_Closed({
        if (-not (Test-Path -LiteralPath $resultPath)) {
            & $writeResult 'CLOSED'
        }
    })
    $window.Add_ContentRendered({ $password.Focus() })
    [void]$window.ShowDialog()
}

if ($Mode -eq 'DeviceCode') {
    $code = Get-OrCreateDeviceCode -Path $DeviceCodePath
    Write-UpdateResult ('OK|' + $code)
    exit 0
}

if ($Mode -eq 'LicenseCheck') {
    Write-UpdateResult (Invoke-DeviceLicenseCheck -Code $DeviceCode)
    exit 0
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
    'DK_NORMAL_AREA_LAYERS' = 'Normal Loop Polyline Layerlari'
    'DK_COMBINED_RISER_LAYERS' = 'Kombine Polyline Layerlari'
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
            if ($key -eq 'DK_NORMAL_AREA_LAYERS') { return 'DK Normal Loop Layerlari' }
            if ($key -eq 'DK_COMBINED_RISER_LAYERS') { return 'DK Kombine Layerlari' }
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
        'DK' = @('DK Normal Loop Layerlari','DK Kombine Layerlari','DK Normal','DK Normal Alt Cizgi','DK Loop Ayarlari','DK DATA / CCTV Genel','DK DATA / CCTV Cizgi','DK DATA Layerlari','DK DATA Block Kaydirma','DK CCTV Layerlari','DK Cikti Layerlari','DK Yardimci')
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

$script:lastStatusWrite = if (Test-Path -LiteralPath $statusPath) {
    (Get-Item -LiteralPath $statusPath).LastWriteTimeUtc.Ticks
} else { 0L }
$script:lastShowWrite = if (Test-Path -LiteralPath $showPath) {
    (Get-Item -LiteralPath $showPath).LastWriteTimeUtc.Ticks
} else { 0L }
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
