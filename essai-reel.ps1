<#
.SYNOPSIS
  Essai reel de MerePoule : le Watchdog pose dans MT5 et la passerelle, de bout en bout.

.DESCRIPTION
  Prerequis : MT5 ouvert et connecte, Watchdog 1.21 pose sur un graphique sans robot.

  Construit la passerelle, la lance sur un port d'essai avec une base neuve (la
  vraie base n'est jamais touchee), enrole un telephone fictif, puis verifie :
    1. chaque Watchdog est vivant et son statut complet
    2. son journal est lu
    3. -Pause    : PAUSE executee, robot coupe, positions gardees
    4. -Relaunch : RELANCER executee, robot relance
    5. -Robot    : reglage du robot hors bornes refuse, puis sa valeur actuelle
                   reecrite sur un graphique (le robot redemarre, le lot ne change pas)

  Sans -Pause, -Relaunch ni -Robot, rien n'est envoye au Watchdog : lecture seule.
  Code de sortie : 0 si tout est vert, 1 sinon.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File essai-reel.ps1

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File essai-reel.ps1 -Pause -Relaunch

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File essai-reel.ps1 -Robot
#>
[CmdletBinding()]
param(
   [switch]$Pause,
   [switch]$Relaunch,
   [switch]$Robot,
   [long]$Account = 0,         # 0 = premier compte trouve
   [string]$Common = "",       # dossier commun de MT5 ; vide = celui du compte Windows courant
   [int]$Port = 8799
)

$ErrorActionPreference = "Stop"
$Work = Join-Path $env:TEMP "merepoule-essai"
$Exe  = Join-Path $Work "merepoule-gateway.exe"
$Data = Join-Path $Work ("data-" + (Get-Date -Format "yyyyMMdd-HHmmss"))
$Pin  = "482913"
$Base = "http://127.0.0.1:$Port/api/v1"
if (-not $Common) { $Common = Join-Path $env:APPDATA "MetaQuotes\Terminal\Common\Files" }

$script:failures = 0
function Step([string]$m) { Write-Host "==> $m" -ForegroundColor Cyan }
function Ok([string]$m)   { Write-Host "    OK     $m" -ForegroundColor Green }
function Ko([string]$m)   { Write-Host "    ECHEC  $m" -ForegroundColor Red; $script:failures++ }
function Info([string]$m) { Write-Host "           $m" }

function Api([string]$method, [string]$path, $body = $null, [string]$token = "") {
   $req = @{ Method = $method; Uri = "$Base$path"; ContentType = "application/json; charset=utf-8" }
   if ($token) { $req["Headers"] = @{ Authorization = "Bearer $token" } }
   if ($null -ne $body) { $req["Body"] = [Text.Encoding]::UTF8.GetBytes(($body | ConvertTo-Json -Compress)) }
   try { return Invoke-RestMethod @req }
   catch {
      $resp = $_.Exception.Response
      if ($resp) {
         $text = (New-Object IO.StreamReader($resp.GetResponseStream())).ReadToEnd()
         throw "HTTP $([int]$resp.StatusCode) sur $method $path : $text"
      }
      throw
   }
}

function Status([long]$acc, [string]$token) { return (Api GET "/accounts/$acc/status" $null $token) }

# Attend l'issue d'une demande : executed, refused ou timeout (10 s cote passerelle).
function WaitRequest([long]$acc, [string]$id, [string]$token) {
   $deadline = (Get-Date).AddSeconds(15)
   do {
      Start-Sleep -Milliseconds 500
      $r = Api GET "/accounts/$acc/requests/$id" $null $token
   } while ($r.state -eq "pending" -and (Get-Date) -lt $deadline)
   return $r
}

function FirstLine([string]$s) { return ($s -split "`n")[0] }

# --- Construction
Step "Construction de la passerelle"
New-Item -ItemType Directory -Force $Work, $Data | Out-Null
$env:GOTOOLCHAIN = "local"
Push-Location (Join-Path $PSScriptRoot "gateway")
try {
   go build -o $Exe ./cmd/merepoule-gateway
   if ($LASTEXITCODE -ne 0) { throw "go build en echec" }
} finally { Pop-Location }
Ok $Exe

# --- Diagnostic, sans passerelle
Step "Diagnostic des Watchdogs"
& $Exe diag -common $Common
if ($LASTEXITCODE -eq 1) { throw "Aucun dossier MerePoule : MT5 ouvert et Watchdog 1.21 pose ?" }

# --- Passerelle d'essai
Step "Passerelle d'essai sur le port $Port"
Info "base neuve : $Data"
$proc = Start-Process -FilePath $Exe -NoNewWindow -PassThru `
   -ArgumentList @("serve", "-common", "`"$Common`"", "-data", "`"$Data`"", "-listen", "127.0.0.1:$Port") `
   -RedirectStandardError (Join-Path $Data "serve.log")
try {
   $deadline = (Get-Date).AddSeconds(10)
   while ($true) {
      try { $h = Api GET "/health"; break }
      catch { if ((Get-Date) -gt $deadline) { throw "la passerelle ne repond pas, voir $Data\serve.log" }; Start-Sleep -Milliseconds 300 }
   }
   Ok "passerelle en service"

   Step "Enrolement d'un telephone d'essai"
   $out  = (& $Exe enroll -common $Common -data $Data -name "Essai reel") -join "`n"
   $code = ([regex]"[A-Z0-9]{5}-[A-Z0-9]{5}").Match($out).Value
   $dev  = Api POST "/devices" @{ code = $code; pin = $Pin }
   $token = $dev.token
   Ok "appareil $($dev.device_id), jeton recu"

   Step "Comptes"
   Start-Sleep -Seconds 2   # premier passage de la lecture des Watchdogs
   $accounts = @((Api GET "/accounts" $null $token).accounts)
   if ($accounts.Count -eq 0) { throw "aucun compte vu par la passerelle" }
   foreach ($a in $accounts) { Info ("{0} '{1}' : {2}, Watchdog {3}, statut il y a {4} s" -f $a.account, $a.label, $a.state, $a.watchdog, $a.age_s) }
   $acc = if ($Account -ne 0) { $Account } else { [long]$accounts[0].account }
   Ok "compte essaye : $acc"

   Step "Statut du compte $acc"
   $st = Status $acc $token
   $s  = $st.status
   if ($st.stale) { Ko "statut perime ($($st.age_s) s) : Watchdog muet" } else { Ok "Watchdog vivant, statut il y a $($st.age_s) s" }
   if ([version]$s.watchdog -ge [version]"1.21") { Ok "version $($s.watchdog)" } else { Ko "version $($s.watchdog), 1.21 attendue" }
   foreach ($f in "stop_out_level", "symbols", "targets", "saved_charts", "shield", "config") {
      if ($null -eq $s.$f) { Ko "champ $f absent du statut" }
   }
   Info ("etat {0}, equity {1}, solde {2}, marge {3} % (stop-out {4} {5})" -f $s.state, $s.equity, $s.balance, $s.margin_level, $s.stop_out_level, $s.stop_out_mode)
   Info ("{0} position(s) : {1}" -f $s.positions, (($s.symbols | ForEach-Object { "$($_.symbol) $($_.positions)" }) -join ", "))
   Info ("robot : {0} graphique(s) {1} ; {2} modele(s) enregistre(s)" -f $s.target_charts, (($s.targets | ForEach-Object { "$($_.expert) sur $($_.symbol)" }) -join ", "), $s.saved_charts)
   foreach ($t in $s.targets) {
      $inp = if ($t.inputs) { ($t.inputs.PSObject.Properties | ForEach-Object { "$($_.Name)=$($_.Value)" }) -join ", " } else { "" }
      Info ("  {0} : {1}" -f $t.symbol, $(if ($inp) { $inp } else { "reglages pas encore lus" }))
   }
   foreach ($p in $s.robot_params) { Info ("modifiable a distance : {0} ({1}) de {2} a {3}" -f $p.label, $p.name, $p.min, $p.max) }
   Info ("bouclier : actif {0}, budget {1}, {2} groupe(s), {3} protegee(s), {4} sans stop loss" -f $s.shield.active, $s.shield.budget, $s.shield.groups, $s.shield.protected, $s.shield.unprotected)
   if ($s.shield.active -and $s.shield.unprotected -gt 0) { Ko "$($s.shield.unprotected) position(s) sans stop loss du Bouclier : voir le journal (shield_failed)" }
   if ($s.target_charts -eq 0 -and $s.state -eq "RUN") { Ko "aucun graphique du robot trouve : verifier InpTargetExperts" }

   Step "Journal"
   $ev = @((Api GET "/accounts/$acc/events?since=0&limit=500" $null $token).events)
   Ok "$($ev.Count) evenement(s) lus"
   foreach ($e in ($ev | Select-Object -Last 6)) { Info ("#{0} {1} : {2}" -f $e.seq, $e.type, (FirstLine $e.message)) }

   if ($Pause) {
      Step "PAUSE"
      $before = (Status $acc $token).status
      $r = Api POST "/accounts/$acc/pause" @{ reason = "essai reel" } $token
      if (-not $r.request_id) { Info "deja en PAUSE" }
      else {
         $res = WaitRequest $acc $r.request_id $token
         if ($res.state -eq "executed") { Ok ("executee : " + (FirstLine $res.detail)) } else { Ko ("{0} : {1}" -f $res.state, $res.detail) }
      }
      Start-Sleep -Seconds 2
      $after = (Status $acc $token).status
      if ($after.state -eq "PAUSE") { Ok "etat PAUSE" } else { Ko "etat $($after.state)" }
      if ($after.target_charts -eq 0) { Ok "graphiques du robot fermes" } else { Ko "$($after.target_charts) graphique(s) du robot encore ouverts" }
      if ($after.positions -eq $before.positions) { Ok "positions gardees : $($after.positions)" }
      else { Info "positions : $($before.positions) avant, $($after.positions) apres (stop loss ou regle ?)" }
      if ($after.saved_charts -ge $before.target_charts) { Ok "$($after.saved_charts) modele(s) enregistre(s) pour RELANCER" }
      else { Ko "$($after.saved_charts) modele(s) enregistre(s) pour $($before.target_charts) graphique(s)" }
   }

   if ($Relaunch) {
      Step "RELANCER"
      $r = Api POST "/accounts/$acc/relaunch" @{ pin = $Pin } $token
      $res = WaitRequest $acc $r.request_id $token
      if ($res.state -eq "executed") { Ok ("executee : " + (FirstLine $res.detail)) } else { Ko ("{0} : {1}" -f $res.state, $res.detail) }
      Start-Sleep -Seconds 5   # le modele charge l'EA de facon asynchrone
      $after = (Status $acc $token).status
      if ($after.state -eq "RUN") { Ok "etat RUN" } else { Ko "etat $($after.state)" }
      if ($after.target_charts -gt 0) { Ok ("robot relance : " + (($after.targets | ForEach-Object { "$($_.expert) sur $($_.symbol) $($_.period)" }) -join ", ")) }
      else { Ko "aucun graphique du robot apres la relance" }
      Info "A verifier dans MT5 : Algo Trading actif sur les graphiques rouverts, memes parametres qu'avant."
   }

   if ($Robot) {
      Step "REGLAGE DU ROBOT (valeur actuelle reecrite, un seul graphique)"
      $s = (Status $acc $token).status
      $p = @($s.robot_params)[0]
      if (-not $p) { throw "aucun reglage modifiable : Watchdog 1.22 et InpRobotParams ?" }
      $t = @($s.targets | Where-Object { $_.inputs.($p.name) })[0]
      if (-not $t) { throw "aucun graphique du robot ne porte $($p.name) (reglages lus chaque minute : reessayer)" }
      $current = [double]::Parse($t.inputs.($p.name), [Globalization.CultureInfo]::InvariantCulture)
      try {
         Api PUT "/accounts/$acc/robot/params" @{ pin = $Pin; param = $p.name; value = $p.max + 1 } $token | Out-Null
         Ko "valeur hors bornes acceptee"
      } catch {
         if ("$_" -match "HTTP 422") { Ok "valeur hors bornes refusee par la passerelle (422)" } else { throw }
      }
      $r = Api PUT "/accounts/$acc/robot/params" @{ pin = $Pin; param = $p.name; value = $current; symbol = $t.symbol } $token
      $res = WaitRequest $acc $r.request_id $token
      if ($res.state -eq "executed") { Ok ("executee : " + (FirstLine $res.detail)) } else { Ko ("{0} : {1}" -f $res.state, $res.detail) }
      Start-Sleep -Seconds 15   # rechargement de l'EA puis relecture des reglages
      $t2 = @((Status $acc $token).status.targets | Where-Object { $_.symbol -eq $t.symbol })[0]
      if ($t2 -and $t2.inputs.($p.name) -eq $t.inputs.($p.name)) { Ok ("{0} relu sur {1} : {2}" -f $p.label, $t.symbol, $t2.inputs.($p.name)) }
      else { Ko "reglage non relu apres le redemarrage du robot" }
      Info "A verifier dans l'onglet Experts de MT5 : le robot sur $($t.symbol) a redemarre (INIT OK)."
   }
}
catch { Ko $_.Exception.Message }
finally {
   Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
}

Step "Bilan"
if ($script:failures -eq 0) { Write-Host "    Tout est vert." -ForegroundColor Green; exit 0 }
Write-Host "    $($script:failures) echec(s). Journal de la passerelle : $Data\serve.log" -ForegroundColor Red
exit 1
