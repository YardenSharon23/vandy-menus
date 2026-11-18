<#
  Scrapes the weekly hours NetNutrition lists for every Vanderbilt dining location
  and writes one JSON file.

  Usage: .\scrape-hours.ps1 [-Out hours.json]
  Output: {updated, units:[{id, name, group, days:{Sunday:[{o:"7:00 AM",c:"3:00 PM"}, ...], ...}}]}
  A day with no ranges is closed.
#>
param([string]$Out = "hours.json", [int]$DelayMs = 50)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$base = 'https://netnutrition.cbord.com/nn-prod/vucampusdining'

function Decode([string]$s) { ([System.Net.WebUtility]::HtmlDecode(($s -replace '<[^>]+>', '')) -replace '\s+', ' ').Trim() }

$halls = 1, 2, 3, 11, 20, 21, 19
$marts = 12, 13, 14, 15

$null = Invoke-WebRequest -Uri $base -SessionVariable s -UseBasicParsing -MaximumRedirection 20
$landing = (Invoke-WebRequest -Uri $base -WebSession $s -UseBasicParsing).Content
$units = [regex]::Matches($landing, 'unitsSelectUnit\((\d+)\);"[^>]*>([^<]+)</a>') | ForEach-Object {
  [pscustomobject]@{ id = [int]$_.Groups[1].Value; name = ((Decode $_.Groups[2].Value) -replace '\s*-\s*Contains Peanuts.*$', '') }
} | Sort-Object id -Unique

$outUnits = @()
foreach ($u in $units) {
  Start-Sleep -Milliseconds $DelayMs
  $html = (Invoke-WebRequest -Uri "$base/Unit/GetHoursOfOperationMarkup" -Method Post -Body @{ unitOid = $u.id } -WebSession $s -UseBasicParsing).Content
  $days = [ordered]@{ Sunday = @(); Monday = @(); Tuesday = @(); Wednesday = @(); Thursday = @(); Friday = @(); Saturday = @() }
  foreach ($row in [regex]::Matches($html, '<tr[^>]*>([\s\S]*?)</tr>')) {
    $cells = [regex]::Matches($row.Groups[1].Value, '<td[^>]*>([\s\S]*?)</td>') | ForEach-Object { Decode $_.Groups[1].Value }
    if ($cells.Count -ge 3 -and $days.Contains($cells[0])) { $days[$cells[0]] += [pscustomobject]@{ o = $cells[1]; c = $cells[2] } }
  }
  # NetNutrition lists ranges in any order; sort each day by opening time.
  foreach ($d in @($days.Keys)) {
    $days[$d] = @($days[$d] | Sort-Object { [datetime]::ParseExact($_.o, 'h:mm tt', [Globalization.CultureInfo]::InvariantCulture) })
  }
  $group = if ($halls -contains $u.id) { 'Dining halls' } elseif ($marts -contains $u.id) { 'Munchie Marts' } else { 'Cafés & more' }
  $outUnits += [ordered]@{ id = $u.id; name = $u.name; group = $group; days = $days }
  Write-Host ("{0,-40} {1}" -f $u.name, (($days.Keys | ForEach-Object { "$($_.Substring(0,3)):$($days[$_].Count)" }) -join ' '))
}

$result = [ordered]@{ updated = (Get-Date).ToUniversalTime().ToString('o'); source = $base; units = $outUnits }
$json = $result | ConvertTo-Json -Depth 8 -Compress
[IO.File]::WriteAllText((Join-Path (Get-Location) $Out), $json, (New-Object Text.UTF8Encoding $false))
Write-Host "Saved $Out"
