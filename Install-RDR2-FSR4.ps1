<#
.SYNOPSIS
  Instala o OptiScaler (FSR 4.x) no Red Dead Redemption 2 (Steam) da forma recomendada
  pelo wiki oficial do OptiScaler: como winmm.dll, com spoofing DESLIGADO (Dxgi=false),
  usando entradas FSR2 no DirectX 12.

.DESCRIPTION
  - Acha a pasta do RDR2 sozinho (Steam) ou usa -GamePath
  - Faz backup de qualquer DLL/INI que ja exista (nada e apagado, so movido)
  - Baixa a ultima release ESTAVEL do OptiScaler (github.com/optiscaler/OptiScaler)
  - Instala como winmm.dll (nao usa dxgi.dll)
  - Ajusta o OptiScaler.ini: Dxgi=false e Dx12Upscaler=fsr31 (= FSR3.X/4)
  - -Uninstall remove tudo e restaura o backup

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\Install-RDR2-FSR4.ps1
  powershell -ExecutionPolicy Bypass -File .\Install-RDR2-FSR4.ps1 -Watermark
  powershell -ExecutionPolicy Bypass -File .\Install-RDR2-FSR4.ps1 -Uninstall
  powershell -ExecutionPolicy Bypass -File .\Install-RDR2-FSR4.ps1 -ArchivePath "C:\Users\voce\Downloads\OptiScaler.7z"

.NOTES
  Use apenas no modo historia (single player). Nao use mods em RDR Online.
#>
[CmdletBinding()]
param(
    [string]$GamePath,
    [string]$ArchivePath,
    [switch]$Uninstall,
    [switch]$Watermark,
    [switch]$CopyDriverFsr4Dll
)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

function Write-Step($m) { Write-Host "`n==> $m" -ForegroundColor Cyan }
function Write-Ok($m)   { Write-Host "    [OK] $m" -ForegroundColor Green }
function Write-Warn2($m){ Write-Host "    [!]  $m" -ForegroundColor Yellow }
function Write-Info($m) { Write-Host "    $m" -ForegroundColor Gray }

# Arquivos/pastas que uma instalacao do OptiScaler costuma deixar na pasta do jogo
$KnownOptiFiles = @(
    'dxgi.dll','winmm.dll','version.dll','d3d12.dll','dbghelp.dll','wininet.dll','winhttp.dll',
    'OptiScaler.dll','OptiScaler.asi','OptiScaler.ini','OptiScaler.log',
    'nvapi64.dll','nvngx.dll','fakenvapi.dll','fakenvapi.ini',
    'amd_fidelityfx_upscaler_dx12.dll','amd_fidelityfx_framegeneration_dx12.dll',
    'amd_fidelityfx_dx12.dll','amd_fidelityfx_vk.dll','amdxcffx64.dll',
    'dlssg_to_fsr3_amd_is_better.dll','dlssg_to_fsr3.ini',
    'libxess.dll','libxess_dx11.dll','libxess_fg.dll','libxell.dll',
    'setup_windows.bat','remove_optiscaler.bat','setup_linux.sh','remove_optiscaler.sh'
)
$KnownOptiDirs = @('D3D12_Optiscaler','OptiScaler')

# ---------------------------------------------------------------- utilidades
function Find-Rdr2Folder {
    $libs = New-Object System.Collections.Generic.List[string]
    $steam = $null
    foreach ($k in 'HKCU:\Software\Valve\Steam','HKLM:\SOFTWARE\WOW6432Node\Valve\Steam') {
        try {
            $p = Get-ItemProperty -Path $k -ErrorAction Stop
            if ($p.SteamPath)   { $steam = $p.SteamPath; break }
            if ($p.InstallPath) { $steam = $p.InstallPath; break }
        } catch {}
    }
    if ($steam) {
        $steam = $steam -replace '/', '\'
        $libs.Add($steam)
        $vdf = Join-Path $steam 'steamapps\libraryfolders.vdf'
        if (Test-Path $vdf) {
            foreach ($m in [regex]::Matches((Get-Content $vdf -Raw), '"path"\s+"([^"]+)"')) {
                $libs.Add(($m.Groups[1].Value -replace '\\\\', '\'))
            }
        }
    }
    foreach ($lib in ($libs | Select-Object -Unique)) {
        $candidate = Join-Path $lib 'steamapps\common\Red Dead Redemption 2'
        if (Test-Path (Join-Path $candidate 'RDR2.exe')) { return $candidate }
    }
    return $null
}

function Set-IniValue([string]$File, [string]$Key, [string]$Value) {
    $lines = [System.IO.File]::ReadAllLines($File)
    $pattern = '^\s*' + [regex]::Escape($Key) + '\s*='
    $hit = $false
    for ($i = 0; $i -lt $lines.Length; $i++) {
        if ($lines[$i] -match $pattern) { $lines[$i] = "$Key=$Value"; $hit = $true }
    }
    if ($hit) {
        $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
        [System.IO.File]::WriteAllLines($File, $lines, $utf8NoBom)
        Write-Ok "OptiScaler.ini: $Key=$Value"
    } else {
        Write-Warn2 "Chave '$Key' nao encontrada no OptiScaler.ini (versao diferente?). Ajuste pelo menu in-game (Insert)."
    }
}

function Get-7z([string]$WorkDir) {
    foreach ($p in @("$env:ProgramFiles\7-Zip\7z.exe", "${env:ProgramFiles(x86)}\7-Zip\7z.exe")) {
        if ($p -and (Test-Path $p)) { return $p }
    }
    $cmd = Get-Command 7z.exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    Write-Info "7-Zip nao encontrado; baixando 7zr.exe (extrator oficial standalone) ..."
    $p = Join-Path $WorkDir '7zr.exe'
    Invoke-WebRequest -Uri 'https://www.7-zip.org/a/7zr.exe' -OutFile $p -UseBasicParsing
    return $p
}

function Move-ToBackup([string]$GameDir, [string]$BackupDir, [string[]]$Names) {
    $moved = 0
    foreach ($n in $Names) {
        $src = Join-Path $GameDir $n
        if (Test-Path -LiteralPath $src) {
            if (-not (Test-Path $BackupDir)) { New-Item -ItemType Directory -Path $BackupDir | Out-Null }
            Move-Item -LiteralPath $src -Destination (Join-Path $BackupDir $n) -Force
            Write-Info "backup: $n"
            $moved++
        }
    }
    return $moved
}

# ---------------------------------------------------------------- inicio
Write-Host ''
Write-Host '=== RDR2 + OptiScaler (FSR 4.x) - instalador ===' -ForegroundColor White

# 1) Localiza o jogo
Write-Step 'Procurando o Red Dead Redemption 2'
if (-not $GamePath) { $GamePath = Find-Rdr2Folder }
if (-not $GamePath) {
    $GamePath = Read-Host 'Nao achei automaticamente. Cole o caminho da pasta onde esta o RDR2.exe'
}
$GamePath = $GamePath.Trim('"').TrimEnd('\')
if (-not (Test-Path (Join-Path $GamePath 'RDR2.exe'))) {
    throw "RDR2.exe nao encontrado em: $GamePath"
}
Write-Ok "Pasta do jogo: $GamePath"

if (Get-Process -Name 'RDR2','PlayRDR2' -ErrorAction SilentlyContinue) {
    throw 'Feche o Red Dead Redemption 2 antes de continuar.'
}

# ---------------------------------------------------------------- desinstalar
if ($Uninstall) {
    Write-Step 'Desinstalando OptiScaler'
    $ini = Join-Path $GamePath 'OptiScaler.ini'
    if (-not (Test-Path $ini)) {
        Write-Warn2 'OptiScaler.ini nao existe na pasta - nao parece haver instalacao. Nada a remover.'
    } else {
        $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
        $removed = Join-Path $GamePath "_OptiScaler_removed_$stamp"
        [void](Move-ToBackup $GamePath $removed ($KnownOptiFiles + $KnownOptiDirs))
        Write-Ok "Arquivos do OptiScaler movidos para: $removed"
    }
    $lastBackup = Get-ChildItem -Path $GamePath -Directory -Filter '_OptiScaler_backup_*' -ErrorAction SilentlyContinue |
                  Sort-Object Name -Descending | Select-Object -First 1
    if ($lastBackup) {
        Get-ChildItem -LiteralPath $lastBackup.FullName | ForEach-Object {
            Move-Item -LiteralPath $_.FullName -Destination (Join-Path $GamePath $_.Name) -Force
            Write-Info "restaurado: $($_.Name)"
        }
        Remove-Item -LiteralPath $lastBackup.FullName -Force -Recurse
        Write-Ok 'Backup anterior restaurado.'
    }
    Write-Host "`nPronto. (Se quiser, tambem pode usar 'Verificar integridade' na Steam.)" -ForegroundColor Green
    return
}

# ---------------------------------------------------------------- diagnostico
Write-Step 'Verificando o sistema'
try {
    $gpus = Get-CimInstance Win32_VideoController | ForEach-Object { $_.Name }
    Write-Info ("GPU(s): " + ($gpus -join ' | '))
    if (-not ($gpus -match 'RX\s*9\d{3}')) {
        Write-Warn2 'Nenhuma Radeon RX 9000 detectada. FSR 4 oficial exige RDNA4 (ou RDNA3 com INT8 no OptiScaler 0.9.4+).'
    }
} catch {}
$amdxc = Join-Path $env:WINDIR 'System32\amdxcffx64.dll'
if (Test-Path $amdxc) {
    Write-Ok ("Driver AMD com FSR4 encontrado (amdxcffx64.dll v" + (Get-Item $amdxc).VersionInfo.FileVersion + ')')
} else {
    Write-Warn2 'amdxcffx64.dll NAO esta em System32 -> atualize o driver Adrenalin (instalacao completa).'
}
$sysXml = Join-Path $env:USERPROFILE 'Documents\Rockstar Games\Red Dead Redemption 2\Settings\system.xml'
if (Test-Path $sysXml) {
    $m = [regex]::Match((Get-Content $sysXml -Raw), 'kSettingAPI_(\w+)')
    if ($m.Success) {
        if ($m.Groups[1].Value -match 'DX12') { Write-Ok "API grafica no jogo: $($m.Groups[1].Value)" }
        else { Write-Warn2 "API grafica no jogo: $($m.Groups[1].Value) -> mude para DirectX 12 (Opcoes > Graficos > Avancado)." }
    }
}

# ---------------------------------------------------------------- baixar
$work = Join-Path $env:TEMP ('rdr2_opti_' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $work | Out-Null

try {
    if ($ArchivePath) {
        Write-Step "Usando arquivo local: $ArchivePath"
        if (-not (Test-Path $ArchivePath)) { throw "Arquivo nao encontrado: $ArchivePath" }
        $archive = $ArchivePath
    } else {
        Write-Step 'Baixando a ultima release estavel do OptiScaler'
        $rel = Invoke-RestMethod -Uri 'https://api.github.com/repos/optiscaler/OptiScaler/releases/latest' `
                                 -Headers @{ 'User-Agent' = 'rdr2-opti-installer' }
        $asset = $rel.assets | Where-Object { $_.name -like '*.7z' } | Select-Object -First 1
        if (-not $asset) { throw 'Nao achei o .7z na release. Baixe manualmente e use -ArchivePath.' }
        Write-Info "Versao: $($rel.tag_name)  |  arquivo: $($asset.name)"
        $archive = Join-Path $work $asset.name
        Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $archive -UseBasicParsing
        Write-Ok 'Download concluido'
    }

    Write-Step 'Extraindo'
    $sevenZip = Get-7z $work
    $extract = Join-Path $work 'extracted'
    & $sevenZip x $archive "-o$extract" -y | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Falha ao extrair (7z codigo $LASTEXITCODE)." }

    $optiDll = Get-ChildItem -Path $extract -Recurse -Filter 'OptiScaler.dll' |
               Sort-Object { $_.FullName.Length } | Select-Object -First 1
    if (-not $optiDll) { throw 'OptiScaler.dll nao encontrado dentro do arquivo baixado.' }
    $srcDir = $optiDll.DirectoryName
    Write-Ok "Conteudo localizado em: $srcDir"

    # ------------------------------------------------------------ backup
    Write-Step 'Fazendo backup de arquivos existentes'
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $backup = Join-Path $GamePath "_OptiScaler_backup_$stamp"
    $incoming = Get-ChildItem -LiteralPath $srcDir | ForEach-Object { $_.Name }
    $toBackup = ($KnownOptiFiles + $KnownOptiDirs + $incoming) | Select-Object -Unique
    $n = Move-ToBackup $GamePath $backup $toBackup
    if ($n -eq 0) { Write-Info 'Nada para salvar (pasta limpa).' } else { Write-Ok "$n item(ns) movido(s) para $backup" }

    # ------------------------------------------------------------ instalar
    Write-Step 'Instalando como winmm.dll (sem dxgi.dll)'
    # fakenvapi/nvapi64 nao sao necessarios para entradas FSR2 e o wiki do RDR2 recomenda remover em alguns casos
    $exclude = @('fakenvapi.dll', 'fakenvapi.ini', 'nvapi64.dll', 'nvngx.dll',
                 'setup_windows.bat', 'remove_optiscaler.bat', 'setup_linux.sh', 'remove_optiscaler.sh')
    Get-ChildItem -LiteralPath $srcDir -Force | Where-Object { $exclude -notcontains $_.Name } | ForEach-Object {
        Copy-Item -LiteralPath $_.FullName -Destination $GamePath -Recurse -Force
    }
    Move-Item -LiteralPath (Join-Path $GamePath 'OptiScaler.dll') -Destination (Join-Path $GamePath 'winmm.dll') -Force
    Write-Ok 'OptiScaler.dll -> winmm.dll'

    if ($CopyDriverFsr4Dll -and (Test-Path $amdxc)) {
        Copy-Item -LiteralPath $amdxc -Destination $GamePath -Force
        Write-Ok 'amdxcffx64.dll do driver copiado para a pasta do jogo'
        Write-Warn2 'Lembre: apos atualizar o driver AMD, apague essa copia (ou rode o script de novo).'
    }

    # ------------------------------------------------------------ configurar
    Write-Step 'Configurando OptiScaler.ini'
    $iniPath = Join-Path $GamePath 'OptiScaler.ini'
    if (-not (Test-Path $iniPath)) { throw 'OptiScaler.ini nao foi copiado.' }
    Set-IniValue $iniPath 'Dxgi' 'false'            # desliga spoofing (causa artefatos/crash no RDR2 segundo o wiki)
    Set-IniValue $iniPath 'Dx12Upscaler' 'fsr31'    # FSR3.X/4 (FSR 4.x em RDNA4)
    if ($Watermark) { Set-IniValue $iniPath 'Fsr4EnableWatermark' 'true' }

} finally {
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}

# ---------------------------------------------------------------- final
Write-Host @'

==================== PRONTO. AGORA NO JOGO ====================
 1) Opcoes > Graficos > Avancado:
      - API grafica = DirectX 12   (NAO Vulkan)
      - Upscaling   = FSR 2        (NAO DLSS, NAO TAA puro)
      - Qualidade   = Quality ou Balanced (evite Native AA / Ultra Quality)
      - Modo de tela = Janela sem bordas (borderless)
 2) Entre na campanha (so single player) e aperte INSERT para abrir o menu do OptiScaler.
 3) No menu: Upscaler = "FSR3.X/4". Para confirmar que e FSR4 e nao fallback FSR3,
    rode este script com -Watermark (aparece uma marca d'agua na tela) e depois sem ele.
 4) Se a imagem ainda estiver estranha:
      - ative "Non-Linear Color Space"
      - ative "Auto Exposure" em Init Parameters
      - teste outro preset (Quality <-> Balanced)
 5) Problemas? Rode com -Uninstall para voltar ao estado anterior.
================================================================
'@ -ForegroundColor White
