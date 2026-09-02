$ErrorActionPreference = 'Stop'

$securePassword = Read-Host 'Bypass sifresi' -AsSecureString
$passwordPointer = [IntPtr]::Zero
$password = $null
$random = $null
$pbkdf2 = $null

try {
    $passwordPointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($securePassword)
    $password = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($passwordPointer)

    $salt = New-Object byte[] 16
    $random = [Security.Cryptography.RandomNumberGenerator]::Create()
    $random.GetBytes($salt)

    $iterations = 210000
    $pbkdf2 = [Security.Cryptography.Rfc2898DeriveBytes]::new(
        $password,
        $salt,
        $iterations,
        [Security.Cryptography.HashAlgorithmName]::SHA256
    )
    $hash = $pbkdf2.GetBytes(32)

    $result = 'PBKDF2-SHA256${0}${1}${2}' -f `
        $iterations,
        [Convert]::ToBase64String($salt),
        [Convert]::ToBase64String($hash)

    Write-Output $result

    if (Get-Command Set-Clipboard -ErrorAction SilentlyContinue) {
        Set-Clipboard -Value $result
        Write-Host 'Dogrulama degeri panoya kopyalandi.'
    }
}
finally {
    if ($pbkdf2) {
        $pbkdf2.Dispose()
    }
    if ($random) {
        $random.Dispose()
    }
    if ($passwordPointer -ne [IntPtr]::Zero) {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($passwordPointer)
    }
    $password = $null
    $securePassword = $null
}
