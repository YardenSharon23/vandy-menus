<#
  Vanderbilt dining menu + nutrition scraper (NetNutrition / CBORD).
  Collects every item on a given day's menus for the chosen dining halls,
  with serving size and macros, and writes one JSON file.

  Usage:
    .\scrape-menus.ps1                       # today, main dining halls
    .\scrape-menus.ps1 -Units 1 -Out rand.json
    .\scrape-menus.ps1 -Date 2026-11-18
#>
param(
  # NetNutrition unit ids: 1 Rand, 2 Commons, 3 Kissam, 11 EBI, 20 Rothschild, 21 Carmichael, 19 Zeppos
  [int[]]$Units = @(1, 2, 3, 11, 20, 21, 19),
  [datetime]$Date = (Get-Date),
  [string]$Out = "menus.json",
  [int]$DelayMs = 50
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$base = 'https://netnutrition.cbord.com/nn-prod/vucampusdining'

function Decode([string]$s) {
  $s = $s -replace '<[^>]+>', ''
  $s = [System.Net.WebUtility]::HtmlDecode($s)
  return ($s -replace '\s+', ' ').Trim()
}

function New-Session {
  $null = Invoke-WebRequest -Uri $base -SessionVariable sess -UseBasicParsing -MaximumRedirection 20
  return $sess
}

function Post($sess, $path, $body) {
  Start-Sleep -Milliseconds $DelayMs
  return (Invoke-WebRequest -Uri "$base/$path" -Method Post -Body $body -WebSession $sess -UseBasicParsing).Content
}

function Get-Panel($json, $id) {
  return (($json | ConvertFrom-Json).panels | Where-Object id -eq $id).html
}

# Number parser: "NA", "", "<1" -> null / numeric
function Num([string]$s) {
  $s = ($s -replace '[^0-9.]', '')
  if ($s -eq '') { return $null }
  return [double]$s
}

$dateLabel = $Date.ToString('dddd, MMMM d, yyyy', [Globalization.CultureInfo]::InvariantCulture)
$result = [ordered]@{
  date      = $Date.ToString('yyyy-MM-dd')
  scrapedAt = (Get-Date).ToUniversalTime().ToString('o')
  source    = $base
  halls     = @()
}

# Unit names from the landing page
$s0 = New-Session
$landing = (Invoke-WebRequest -Uri $base -WebSession $s0 -UseBasicParsing).Content
$unitNames = @{}
[regex]::Matches($landing, 'unitsSelectUnit\((\d+)\);"[^>]*>([^<]+)</a>') | ForEach-Object {
  $unitNames[[int]$_.Groups[1].Value] = (Decode $_.Groups[2].Value)
}

foreach ($unit in $Units) {
  $hallName = $unitNames[$unit]
  Write-Host "== $hallName ($unit)"
  $hall = [ordered]@{ id = $unit; name = $hallName; meals = @() }

  $sess = New-Session
  $menuPanel = Get-Panel (Post $sess 'Unit/SelectUnitFromUnitsList' @{ unitOid = $unit }) 'menuPanel'
  if (-not $menuPanel) { Write-Host "   no menus"; $result.halls += $hall; continue }

  # Menu panel is a list of day cards: <header>date</header> then meal links
  $dayBlocks = [regex]::Split($menuPanel, "(?=<[^>]*card-title)")
  $menus = @()
  foreach ($blk in $dayBlocks) {
    $t = [regex]::Match($blk, 'card-title[^>]*>([^<]+)')
    if (-not $t.Success -or (Decode $t.Groups[1].Value) -ne $dateLabel) { continue }
    [regex]::Matches($blk, 'menuListSelectMenu\((\d+)\)[^>]*>\s*([^<]+)') | ForEach-Object {
      $menus += [pscustomobject]@{ oid = $_.Groups[1].Value; meal = (Decode $_.Groups[2].Value) }
    }
  }
  if ($menus.Count -eq 0) { Write-Host "   nothing served on $dateLabel" }

  foreach ($menu in $menus) {
    # Fresh session per menu so item selections don't leak between menus
    $sess = New-Session
    $null = Post $sess 'Unit/SelectUnitFromUnitsList' @{ unitOid = $unit }
    $items = Get-Panel (Post $sess 'Menu/SelectMenu' @{ menuOid = $menu.oid }) 'itemPanel'

    # Walk rows in order: station header rows and item rows
    $list = New-Object System.Collections.ArrayList
    $station = $null
    foreach ($row in [regex]::Matches($items, "<tr[\s\S]*?</tr>")) {
      $r = $row.Value
      if ($r -match 'cbo_nn_itemGroupRow') {
        $station = Decode ([regex]::Match($r, "<div role='button'>([\s\S]*?)<i").Groups[1].Value)
        continue
      }
      $m = [regex]::Match($r, "id='showNutrition_(-?\d+)'[\s\S]*?class='cbo_nn_itemHover'>([^<]+)")
      if (-not $m.Success) { continue }
      $tds = [regex]::Matches($r, "<td[^>]*>([\s\S]*?)</td>")
      $serving = if ($tds.Count -ge 3) { Decode $tds[2].Groups[1].Value } else { '' }
      $tags = [regex]::Matches($r, "<img title='([^']+)'") | ForEach-Object { $_.Groups[1].Value }
      [void]$list.Add([ordered]@{
          id = [int64]$m.Groups[1].Value; name = (Decode $m.Groups[2].Value); station = $station
          serving = $serving; tags = @($tags)
        })
    }
    Write-Host "   $($menu.meal): $($list.Count) items"

    # Select every item, then fetch one nutrition grid for all of them
    foreach ($it in $list) { $null = Post $sess 'Menu/SelectItem' @{ detailOid = $it.id } }
    $grid = Post $sess 'NutritionDetail/ShowMenuDetailNutritionGrid' @{}

    $headers = [regex]::Matches($grid, "cbo_nn_NutritionGridHeaderText'>([^<]+)") | ForEach-Object { Decode $_.Groups[1].Value }
    # Columns we keep -> header text in the grid
    $want = [ordered]@{
      calories = 'Calories Cal'; fat_g = 'Fat g'; sat_fat_g = 'Sat Fat g'; carbs_g = 'Carbs g'
      fiber_g = 'Dietary Fiber g'; sugar_g = 'Sugars g'; protein_g = 'Protein g'; sodium_mg = 'Sodium mg'
    }
    # Grid rows -> queue per item name (names can repeat across stations)
    $byName = @{}
    foreach ($row in [regex]::Matches($grid, "<tr class='cbo_nn_NutritionGridDetailRow'>([\s\S]*?)</tr>")) {
      $cells = [regex]::Matches($row.Groups[1].Value, "<td[^>]*>([\s\S]*?)</td>") | ForEach-Object { Decode $_.Groups[1].Value }
      $label = $cells[0]                                # "Name - 5 oz. portion (142g)"
      # Greedy match so names containing " - " (e.g. "Honey - Lemon Vinaigrette") stay whole
      $lm = [regex]::Match($label, '^(.*) - ')
      $nm = $(if ($lm.Success) { $lm.Groups[1].Value.Trim() } else { $label })
      $grams = [regex]::Match($label, '\((\d+(?:\.\d+)?)\s*g\)\s*$')
      $vals = [ordered]@{ grams = $(if ($grams.Success) { [double]$grams.Groups[1].Value } else { $null }) }
      foreach ($k in $want.Keys) {
        $idx = [array]::IndexOf($headers, $want[$k])
        $vals[$k] = $(if ($idx -ge 0 -and ($idx + 1) -lt $cells.Count) { Num $cells[$idx + 1] } else { $null })
      }
      if (-not $byName.ContainsKey($nm)) { $byName[$nm] = New-Object System.Collections.Queue }
      $byName[$nm].Enqueue($vals)
    }

    $matched = 0
    foreach ($it in $list) {
      if ($byName.ContainsKey($it.name) -and $byName[$it.name].Count -gt 0) {
        $v = $byName[$it.name].Dequeue()
        foreach ($k in $v.Keys) { $it[$k] = $v[$k] }
        $matched++
      }
    }
    if ($matched -lt $list.Count) { Write-Host "   warning: nutrition found for $matched of $($list.Count)" }

    $hall.meals += [ordered]@{ meal = $menu.meal; items = @($list) }
  }
  $result.halls += $hall
}

$result | ConvertTo-Json -Depth 8 -Compress | Out-File -Encoding utf8 $Out
Write-Host "Saved $Out"
