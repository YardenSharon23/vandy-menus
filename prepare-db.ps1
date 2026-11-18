<#
  Downloads the published menus from GitHub Pages and splits them into one
  compact JSON file per dining hall per day, ready to load into the app's
  database (collection "menus", doc id "<date>__<hallId>").

  Usage: .\prepare-db.ps1 [-OutDir db-upload]
  Prints a JSON manifest: [{doc_id, file, date, hallId, items}]
#>
param(
  [string]$Base = 'https://yardensharon23.github.io/vandy-menus/menus',
  [string]$OutDir = 'db-upload'
)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$short = @{ 1 = 'Rand'; 2 = 'Commons'; 3 = 'Kissam'; 11 = 'EBI'; 20 = 'Rothschild'; 21 = 'Carmichael'; 19 = 'Zeppos' }

if (Test-Path $OutDir) { Remove-Item -Recurse -Force $OutDir }
New-Item -ItemType Directory -Force $OutDir | Out-Null

$index = Invoke-RestMethod "$Base/index.json"
$manifest = @()
foreach ($date in $index.dates) {
  $day = Invoke-RestMethod "$Base/$date.json"
  foreach ($h in $day.halls) {
    $meals = @()
    $count = 0
    foreach ($m in $h.meals) {
      $items = @()
      foreach ($i in $m.items) {
        if ($null -eq $i.calories) { continue }
        $o = [ordered]@{ n = $i.name; s = $i.station; v = $i.serving; k = $i.calories; p = $i.protein_g; c = $i.carbs_g; f = $i.fat_g }
        if ($null -ne $i.grams) { $o.g = $i.grams }
        if ($i.fiber_g) { $o.fi = $i.fiber_g }
        if ($i.sugar_g) { $o.su = $i.sugar_g }
        if ($i.sodium_mg) { $o.na = $i.sodium_mg }
        if ($i.tags -and @($i.tags).Count) { $o.t = (@($i.tags) -join ',') }
        $items += $o
      }
      if ($items.Count) { $meals += [ordered]@{ meal = $m.meal; items = $items }; $count += $items.Count }
    }
    if (-not $meals.Count) { continue }
    $docId = "{0}__{1}" -f $date, $h.id
    $file = Join-Path $OutDir "$docId.json"
    $body = [ordered]@{ date = $date; hallId = [int]$h.id; hall = $short[[int]$h.id]; scrapedAt = $day.scrapedAt; meals = $meals }
    $json = $body | ConvertTo-Json -Depth 8 -Compress
    [IO.File]::WriteAllText((Resolve-Path $OutDir).Path + "\$docId.json", $json, (New-Object Text.UTF8Encoding $false))
    $manifest += [ordered]@{ doc_id = $docId; file = (Resolve-Path $file).Path; date = $date; hallId = [int]$h.id; items = $count; kb = [math]::Round($json.Length / 1KB, 1) }
  }
}
# Opening hours for every location: one document, id "hours" (no date; never deleted).
try {
  $hours = Invoke-RestMethod ($Base -replace '/menus$', '/hours.json')
  $hjson = $hours | ConvertTo-Json -Depth 8 -Compress
  $hfile = (Resolve-Path $OutDir).Path + "\hours.json"
  [IO.File]::WriteAllText($hfile, $hjson, (New-Object Text.UTF8Encoding $false))
  $manifest += [ordered]@{ doc_id = 'hours'; file = $hfile; date = ''; hallId = 0; items = @($hours.units).Count; kb = [math]::Round($hjson.Length / 1KB, 1) }
} catch { Write-Warning "No hours file yet: $($_.Exception.Message)" }

$manifest | ConvertTo-Json -Compress
