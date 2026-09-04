# heaphjobs installer and updater for HorizonXI (Ashita v4).
# Finds the game, fetches the latest release from GitHub, installs or replaces
# the addon, and sets it to load with the game. Safe to run again to update.
# Creation assisted by ADA. X-32 keeps the ledger.

$ErrorActionPreference = 'Stop'
$repo = 'lost-rabbit/heaphjobs'
$name = 'heaphjobs'

function Say($t) { Write-Host $t }
function Good($t) { Write-Host $t -ForegroundColor Green }
function Warn($t) { Write-Host $t -ForegroundColor Yellow }

Say ''
Say '  Heaph Point Board, in game'
Say '  ---------------------------'
Say ''

# 1. find the game folder
$candidates = @(
    (Join-Path $env:APPDATA 'HorizonXI-Launcher\HorizonXI\Game'),
    (Join-Path $env:LOCALAPPDATA 'HorizonXI-Launcher\HorizonXI\Game')
)
$game = $null
foreach ($c in $candidates) { if (Test-Path (Join-Path $c 'addons')) { $game = $c; break } }
if (-not $game) {
    Warn 'Could not find the HorizonXI Game folder on its own.'
    $typed = Read-Host 'Paste the full path to your HorizonXI "Game" folder (the one that holds "addons")'
    if ($typed -and (Test-Path (Join-Path $typed 'addons'))) { $game = $typed }
    else { Warn 'That folder has no "addons" inside it. Nothing installed.'; exit 1 }
}
$addons = Join-Path $game 'addons'
Say "Game folder: $game"

# 2. latest release
Say 'Looking up the latest release...'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$rel = Invoke-RestMethod -UseBasicParsing -Headers @{ 'User-Agent' = 'heaphjobs-installer' } "https://api.github.com/repos/$repo/releases/latest"
$asset = $rel.assets | Where-Object { $_.name -eq "$name.zip" } | Select-Object -First 1
if (-not $asset) { Warn "The latest release has no $name.zip attached. Tell Heaph."; exit 1 }
Say "Latest: $($rel.tag_name)"

# 3. download and unpack
$tmp = Join-Path $env:TEMP "heaphjobs-$([guid]::NewGuid().ToString('N').Substring(0,8))"
New-Item -ItemType Directory -Path $tmp | Out-Null
$zip = Join-Path $tmp "$name.zip"
Invoke-WebRequest -UseBasicParsing -Headers @{ 'User-Agent' = 'heaphjobs-installer' } $asset.browser_download_url -OutFile $zip
Expand-Archive -Path $zip -DestinationPath $tmp -Force
$src = Join-Path $tmp $name
if (-not (Test-Path (Join-Path $src "$name.lua"))) { Warn 'The zip did not contain the addon folder. Nothing installed.'; exit 1 }

# 4. install, replacing any older copy (settings live elsewhere and are kept)
$dest = Join-Path $addons $name
$had = Test-Path $dest
if ($had) { Remove-Item -Recurse -Force $dest }
Copy-Item -Recurse -Force $src $dest
Remove-Item -Recurse -Force $tmp
$ver = (Select-String -Path (Join-Path $dest "$name.lua") -Pattern "addon.version\s*=\s*'([^']+)'" | Select-Object -First 1).Matches[0].Groups[1].Value
if ($had) { Good "Updated $name to $ver in $dest" } else { Good "Installed $name $ver to $dest" }

# 5. load with the game
$script = Join-Path $game 'scripts\default.txt'
if (Test-Path $script) {
    $lines = Get-Content $script
    if (-not ($lines | Where-Object { $_ -match "^\s*/addon\s+load\s+$name\s*$" })) {
        Add-Content -Path $script -Value "`r`n/addon load $name"
        Good 'Added "/addon load heaphjobs" to scripts\default.txt, so it loads with the game.'
    } else {
        Say 'Already set to load with the game.'
    }
} else {
    Warn 'No scripts\default.txt found. Type /addon load heaphjobs in game to load it.'
}

# 6. is the game running right now?
$running = Get-Process -Name 'pol', 'xiloader', 'horizon-loader', 'ashita-cli' -ErrorAction SilentlyContinue
Say ''
if ($running) {
    Warn 'The game is running. In game, type:   /addon reload heaphjobs   (or /addon load heaphjobs if it was not loaded)'
} else {
    Good 'Done. Start the game and the board comes up on its own.'
}
Say ''
Say 'To claim, post and ask from in game: make your in-game key on https://heaphpoints.com (Account tab),'
Say 'then in game:   /heaphjobs key <paste the key>'
Say ''
