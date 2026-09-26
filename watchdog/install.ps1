<#
.SYNOPSIS
  Installe le Watchdog MerePoule dans le terminal Weltrade et le compile.

.DESCRIPTION
  Copie watchdog\MQL5\ dans <dossier de donnees du terminal>\MQL5\, puis compile
  l'EA et le script de commande avec MetaEditor ; echoue sur la moindre erreur.
  Ne pose rien sur un graphique : le terminal peut rester ouvert.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File watchdog\install.ps1

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File watchdog\install.ps1 -DryRun
#>
[CmdletBinding()]
param([switch]$DryRun)

$ErrorActionPreference = "Stop"

$MetaEditor = "C:\Program Files\Weltrade MT5 Terminal\MetaEditor64.exe"
$DataId     = "37DFD387E83142603765C3D8E280A1B5"
$Data       = Join-Path $env:APPDATA "MetaQuotes\Terminal\$DataId\MQL5"
$Src        = Join-Path $PSScriptRoot "MQL5"
$Programs   = @("Experts\MerePoule\MerePoule.mq5", "Scripts\MerePoule\MerePouleCommand.mq5", "Scripts\MerePoule\MerePouleRegle.mq5",
                "Services\MerePoule\MerePouleLecteur.mq5")

foreach ($p in @($MetaEditor, $Data, $Src))
{
   if (-not (Test-Path $p)) { throw "Introuvable : $p" }
}
if ($DryRun) { Write-Host "MODE DRY-RUN : rien ne sera copie ni compile." -ForegroundColor Yellow }

Write-Host "==> Copie vers $Data" -ForegroundColor Cyan
Get-ChildItem $Src -Recurse -File | ForEach-Object {
   $rel = $_.FullName.Substring($Src.Length + 1)
   $dst = Join-Path $Data $rel
   Write-Host "    $rel"
   if (-not $DryRun)
   {
      New-Item -ItemType Directory -Force (Split-Path $dst) | Out-Null
      Copy-Item $_.FullName $dst -Force
   }
}

$failed = @()
foreach ($rel in $Programs)
{
   $file = Join-Path $Data $rel
   $log  = "$file.log"
   Write-Host "==> Compilation de $rel" -ForegroundColor Cyan
   if ($DryRun) { continue }
   if (Test-Path $log) { Remove-Item $log }
   Start-Process -FilePath $MetaEditor -ArgumentList @("/compile:`"$file`"", "/log:`"$log`"") -Wait | Out-Null
   # MetaEditor journalise en UTF-16.
   $lines = Get-Content $log -Encoding Unicode | Where-Object { $_ -match "error|warning|Result" }
   $lines | ForEach-Object { Write-Host "    $_" }
   if (($lines -join "`n") -notmatch "Result: 0 errors") { $failed += $rel }
}
if ($failed) { throw "Compilation en echec : $($failed -join ', '). Voir les .log a cote des sources." }

Write-Host "==> Fait. Poser Experts\MerePoule\MerePoule sur un graphique autre que ceux du robot." -ForegroundColor Cyan
Write-Host "    Lecteur (une fois) : Navigateur, Services, clic droit, Ajouter un service, MerePouleLecteur." -ForegroundColor Cyan
