[CmdletBinding()]
param(
    [string[]]$f,
    [string]$d,
    [switch]$full,
    [string[]]$e,
    [switch]$h,
    [int]$p,
    [int]$b
)

# Mostrar ayuda
function Show-Help {
    Write-Host @"
Uso de aishell1:

  -f archivo1 archivo2   Incluye uno o más archivos específicos en el contexto.
  -d directorio          Incluye archivos especiales (.json, .yml, Dockerfile, etc.) dentro del directorio indicado.
  -full                  Leer archivos completos sin límite de líneas o peso.
  -e bN,pN               Incluir errores recientes. Usa bN para Bash y pN para PowerShell (ej. -e b5,p3).
  -p N                   Incluir los últimos N comandos de PowerShell.
  -b N                   Incluir los últimos N comandos de Bash/WSL.
  -h                     Mostrar esta ayuda y salir.

Notas:
  - El modelo utilizado es local: 'ollama run gemma2:2b'.
  - El contenido de archivos grandes puede truncarse a 500 líneas o 32KB si no se usa -full.
"@ -ForegroundColor Cyan
}

if ($h) {
    Show-Help
    exit
}

# Función para truncar archivos
function Get-LimitedFileContent {
    param (
        [string]$FilePath,
        [switch]$FullMode
    )
    $maxLines = 500
    $maxBytes = 32KB

    if (Test-Path $FilePath) {
        if ($FullMode) {
            return (Get-Content -Path $FilePath -Raw)
        }

        $lines = Get-Content -Path $FilePath -TotalCount $maxLines
        $text = ($lines -join "`n")
        if ([Text.Encoding]::UTF8.GetByteCount($text) -gt $maxBytes) {
            $truncated = [Text.Encoding]::UTF8.GetString(
                [Text.Encoding]::UTF8.GetBytes($text)[0..($maxBytes - 1)]
            )
            return "$truncated`n[Contenido truncado: superó 32KB]"
        }
        if ($lines.Count -eq $maxLines) {
            return "$text`n[Contenido truncado: superó 500 líneas]"
        }
        return $text
    } else {
        return "[Archivo no encontrado]"
    }
}

# Función para ejecutar el modelo local
function Ask-Ollama {
    param(
        [string]$Prompt
    )

    try {
        $tempPromptFile = [System.IO.Path]::GetTempFileName()
        $tempOutputFile = [System.IO.Path]::GetTempFileName()

        $cleanedPrompt = ($Prompt -split "`r?`n") -join "`n"
        Set-Content -Path $tempPromptFile -Value $cleanedPrompt -Encoding UTF8

        $cmd = "type `"$tempPromptFile`" | ollama run gemma2:2b > `"$tempOutputFile`" 2>&1"
        Start-Process -FilePath "cmd.exe" `
                      -ArgumentList "/c", $cmd `
                      -WindowStyle Hidden `
                      -Wait

        $output = Get-Content $tempOutputFile -Raw
        Remove-Item $tempPromptFile, $tempOutputFile -ErrorAction SilentlyContinue
        return $output
    } catch {
        Write-Host "Error al ejecutar Ollama: $($_.Exception.Message)" -ForegroundColor Red
        return $null
    }
}

# Obtener historial
function Get-RecentPSCommands {
    param($count)
    try {
        return (Get-History | Select-Object -Last $count | ForEach-Object { $_.CommandLine }) -join "`n"
    } catch {
        return "[No se pudo obtener historial de PowerShell]"
    }
}

function Get-RecentBashCommands {
    param($count)
    try {
        wsl bash -c "history -a" | Out-Null
        $bashHistory = wsl cat ~/.bash_history -ErrorAction Stop
        return ($bashHistory -split "`n" | Select-Object -Last $count) -join "`n"
    } catch {
        return "[No se pudo obtener historial de Bash]"
    }
}

# Variables de recolección
$combinedHistory = ""
$errorContent = ""
$fileContent = ""
$directoryContent = ""

# Historiales
if ($p) {
    $combinedHistory += "`n=== Últimos $p comandos de PowerShell ===`n$(Get-RecentPSCommands -count $p)"
}
if ($b) {
    $combinedHistory += "`n=== Últimos $b comandos de Bash ===`n$(Get-RecentBashCommands -count $b)"
}
if (-not $p -and -not $b) {
    $combinedHistory = "=== No se especificaron flags -p ni -b: no se ha incluido historial ==="
}

# Parseo de errores
$includePSErrors = $false
$includeBashErrors = $false
$psErrorCount = 0
$bashErrorCount = 0

if ($e) {
    foreach ($item in $e) {
        foreach ($token in ($item -split ',')) {
            if ($token -match '^p(\d+)$') {
                $includePSErrors = $true
                $psErrorCount = [int]$Matches[1]
            } elseif ($token -match '^b(\d+)$') {
                $includeBashErrors = $true
                $bashErrorCount = [int]$Matches[1]
            } else {
                Write-Host "Error en -e: formato no válido. Usa pN o bN." -ForegroundColor Red
                exit 1
            }
        }
    }
}

# Errores recientes
if ($includePSErrors -and $Error.Count -gt 0) {
    $psErrors = ($Error | Select-Object -Last $psErrorCount | ForEach-Object { $_.ToString() }) -join "`n"
    $errorContent += "`n=== Últimos $psErrorCount errores de PowerShell ===`n$psErrors"
}
if ($includeBashErrors) {
    try {
        $bashErrorHistory = wsl cat ~/.bash_history
        $bashErrors = $bashErrorHistory -split "`n" | Select-Object -Last $bashErrorCount
        $errorContent += "`n=== Últimos $bashErrorCount comandos Bash tras errores ===`n$($bashErrors -join "`n")"
    } catch {
        $errorContent += "`n(No se pudieron obtener errores de Bash)"
    }
}

# Archivos con -f
if ($f) {
    foreach ($file in $f) {
        $resolved = Resolve-Path $file -ErrorAction SilentlyContinue
        if ($resolved) {
            $fileContent += "`n=== Contenido de '$file' ===`n$(Get-LimitedFileContent -FilePath $resolved -FullMode:$full)"
        } else {
            $fileContent += "`n[No se encontró el archivo '$file']"
        }
    }
}

# Archivos en directorio con -d
if ($d) {
    $resolvedDir = Resolve-Path $d -ErrorAction SilentlyContinue
    if ($resolvedDir) {
        $directoryContent += "`n=== Archivos en '$d' ===`n$(Get-ChildItem -Path $resolvedDir | Select-Object Name, Length | Out-String)"
        $specialFiles = Get-ChildItem -Path $resolvedDir -Recurse -Include *.json,*.yaml,*.yml,Dockerfile,*.env,*.conf,*.ini -ErrorAction SilentlyContinue
        foreach ($file in $specialFiles) {
            $directoryContent += "`n=== Contenido especial: '$($file.Name)' ===`n$(Get-LimitedFileContent -FilePath $file.FullName -FullMode:$full)"
        }
    } else {
        $directoryContent += "`n[Directorio '$d' no encontrado]"
    }
}

# Contexto adicional
$currentDirectory = (Get-Location).Path
Write-Host "CONTEXTO ADICIONAL (puedes pegar errores, fragmentos, etc):" -ForegroundColor Yellow
$userInput = Read-Host

# Construir prompt final
$prompt = @"
Eres un asistente de terminal llamado 'aishell'. No eres un comando del sistema operativo ni ejecutas acciones directamente. 
Tu única función es analizar historial, archivos proporcionados, errores detectados y contexto adicional para ofrecer soluciones técnicas claras y específicas.
El resto de tu respuesta debe ser explicaciones normales en texto plano, en Español.

=== DIRECTORIO ACTUAL ===
$currentDirectory

=== HISTORIAL ===
$combinedHistory

=== ERRORES ===
$errorContent

=== ARCHIVOS ===
$fileContent

=== DIRECTORIO ===
$directoryContent

=== CONTEXTO ADICIONAL DEL USUARIO ===
$userInput
"@

# Llamar al modelo local
$response = Ask-Ollama -Prompt $prompt

# Mostrar resultado
if ($response) {
    Write-Host "`nRespuesta de AI Shell:" -ForegroundColor Green
    $response -split "`n" | ForEach-Object {
        Write-Host $_ -ForegroundColor Yellow
    }
} else {
    Write-Host "No se recibió respuesta de la IA." -ForegroundColor DarkRed
}

# Detener el modelo (opcional)
try {
    ollama stop gemma2:2b | Out-Null
    Start-Sleep -Seconds 1
    $ollamaProc = Get-Process -Name "ollama" -ErrorAction SilentlyContinue
    if ($ollamaProc) { $ollamaProc | Stop-Process -Force }
} catch {
    Write-Host "No se pudo detener Ollama completamente: $($_.Exception.Message)" -ForegroundColor DarkRed
}
