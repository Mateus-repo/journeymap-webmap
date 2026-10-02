# Builds an override copy of the JourneyMap webmap frontend with:
#   1. a "Chunk grid" toggle wired to the new server-side ?grid=0/1 param
#   2. settings persistence in localStorage (upstream loses them on every reload)
#   3. an always-visible status bar (coords / biome / world / zoom)
#   4. a "recentre on player" button
#
# The upstream frontend is a webpack bundle, but bundle.js ships with a source map,
# so the readable originals live in webmap-frontend/ for reference.
#
# NOTE: do not add custom zoom buttons. Leaflet already renders its own zoom
# control (.leaflet-control-zoom) unless zoomControl is disabled, so a second
# pair just duplicates it in the corner.

$ErrorActionPreference = 'Stop'

$root    = Split-Path -Parent $MyInvocation.MyCommand.Path
$src     = Join-Path $root '_official\webextract\assets\journeymap\web'
$out     = Join-Path $root 'webmap-assets'

if (-not (Test-Path -LiteralPath $src)) { throw "Source web dir not found: $src" }

# ---- fresh copy of the upstream webroot (server serves this dir verbatim) -------
if (Test-Path -LiteralPath $out) { Remove-Item -LiteralPath $out -Recurse -Force }
Copy-Item -LiteralPath $src -Destination $out -Recurse -Force

# source maps are devtools-only, ~4MB, not needed at runtime
Get-ChildItem -LiteralPath $out -Recurse -Filter '*.map' -File -ErrorAction SilentlyContinue |
    Remove-Item -Force

$bundlePath = Join-Path $out 'bundled\bundle.js'
$indexPath  = Join-Path $out 'index.html'
$utf8NoBom  = New-Object System.Text.UTF8Encoding($false)

$bundle = [System.IO.File]::ReadAllText($bundlePath)

function Replace-ExactlyOnce {
    param([string]$Text, [string]$Find, [string]$Replace, [string]$Label)

    $count = ([regex]::Matches($Text, [regex]::Escape($Find))).Count
    if ($count -ne 1) {
        throw "[$Label] expected exactly 1 match for anchor, found $count"
    }
    Write-Host ("  ok  {0,-14} (1 occurrence replaced)" -f $Label)
    return $Text.Replace($Find, $Replace)
}

Write-Host 'Patching bundle.js...'

# 1. datastore defaults: grid OFF, plus mapZoom for the status bar
$bundle = Replace-ExactlyOnce $bundle `
    'visiblePolygons:!0,visibleWaypoints:!0,JMTileLayer:dm' `
    'visiblePolygons:!0,visibleWaypoints:!0,visibleGrid:!1,mapZoom:0,JMTileLayer:dm' `
    'datastore'

# 2. append ?grid= to every tile request
$bundle = Replace-ExactlyOnce $bundle `
    '({x:t,z:e,dimension:r,mapTypeString:i,y:n,zoom:0})' `
    '({x:t,z:e,dimension:r,mapTypeString:i,y:n,zoom:0,grid:window.datastore.state.visibleGrid?1:0})' `
    'tileUrl'

# 3. method that flips the flag and invalidates the cached tile urls
#    (JM caches tile urls by slug, so without resetTiles the switch does nothing)
$bundle = Replace-ExactlyOnce $bundle `
    'toggleFollowMode:function(){Zp.toggleFollowMode()},' `
    'toggleFollowMode:function(){Zp.toggleFollowMode()},setGridVisible:function(t){window.datastore.state.visibleGrid=t,Zp.resetTiles()},' `
    'method'

[System.IO.File]::WriteAllText($bundlePath, $bundle, $utf8NoBom)

# ---------------------------------------------------------------- index.html ----
$index = [System.IO.File]::ReadAllText($indexPath)

function Replace-Html {
    param([string]$Text, [string]$Find, [string]$Replace, [string]$Label)

    $count = ([regex]::Matches($Text, [regex]::Escape($Find))).Count
    if ($count -ne 1) { throw "index.html: anchor for '$Label' found $count times, expected 1" }
    Write-Host ("  ok  {0,-14} (1 occurrence replaced)" -f $Label)
    return $Text.Replace($Find, $Replace)
}

Write-Host 'Patching index.html...'

# --- Chunk grid switch, in its own group after Visibility -----------------------
$gridSwitch = @'
            <div class="settings-group">
                <div class="field">
                    <b-switch v-model="visibleGrid">
                        Chunk grid
                    </b-switch>
                </div>
            </div>
'@

$visibilityAnchor = @'
            <div class="settings-group">
                <div class="field">
                    <b-switch v-model="visiblePolygons">
                        Polygons
                    </b-switch>
                </div>
                <div class="field">
                    <b-switch v-model="visibleWaypoints">
                        Waypoints
                    </b-switch>
                </div>
            </div>
'@

$index = Replace-Html $index $visibilityAnchor ($visibilityAnchor + "`r`n" + $gridSwitch) 'grid switch'

# --- recentre button, added to the follow-mode control --------------------------
# Inline SVG on purpose: only Settings/Box/Expand/Navigation/Earth/File/CircleX are
# registered in index.js, and webpack tree-shook the other lucide icons out of the
# bundle, so a <lucide-icon-*> tag would render as an unknown empty element.
$svgAttrs = 'xmlns="http://www.w3.org/2000/svg" width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" style="display:block"'
$targetSvg = "<svg $svgAttrs><circle cx=`"12`" cy=`"12`" r=`"7`"></circle><path d=`"M12 1v4`"></path><path d=`"M12 19v4`"></path><path d=`"M1 12h4`"></path><path d=`"M19 12h4`"></path></svg>"

$recenterAnchor = @'
        <l-control :position="'topleft'"
                   class="leaflet-bar leaflet-control">
            <a @click="toggleFollowMode()" id="center">
                <img :src="followIcon"/>
            </a>
        </l-control>
'@

$recenterBlock = @"
        <l-control :position="'topleft'"
                   class="leaflet-bar leaflet-control">
            <b-tooltip :animated="true" class="is-flex" label="Recentre on player" position="is-right">
                <a @click="recenter()" id="recenter">$targetSvg</a>
            </b-tooltip>
            <a @click="toggleFollowMode()" id="center">
                <img :src="followIcon"/>
            </a>
        </l-control>
"@

$index = Replace-Html $index $recenterAnchor $recenterBlock 'recenter btn'

# --- status bar ----------------------------------------------------------------
$statusBar = @'
    <div class="jm-hud">
        <span class="jm-hud-item"><b>x</b><span v-text="playerX"></span></span>
        <span class="jm-hud-item"><b>y</b><span v-text="playerY"></span></span>
        <span class="jm-hud-item"><b>z</b><span v-text="playerZ"></span></span>
        <span class="jm-hud-sep"></span>
        <span class="jm-hud-item" v-text="playerBiome"></span>
        <span class="jm-hud-item" v-text="playerWorld"></span>
        <span class="jm-hud-sep"></span>
        <span class="jm-hud-item">zoom <b v-text="mapZoom"></b></span>
    </div>
'@

$mapEndAnchor = @'
    </l-map>

    <b-collapse :open.sync="settingsVisible"
'@

$index = Replace-Html $index $mapEndAnchor ("    </l-map>`r`n`r`n" + $statusBar + @'
    <b-collapse :open.sync="settingsVisible"
'@) 'status bar'

# --- HUD styling, which has to live in <head> ---------------------------------
# Vue 2's runtime compiler strips <style> tags found inside the template, so
# putting this under #main silently loses every rule and the HUD renders as an
# unstyled full-width strip.
$styles = @'
    <style>
        .jm-hud {
            position: fixed;
            left: 50%;
            bottom: 12px;
            transform: translateX(-50%);
            z-index: 1000;
            display: flex;
            align-items: center;
            gap: 10px;
            padding: 7px 14px;
            background: rgba(18, 20, 26, 0.85);
            color: #e6e6e6;
            border-radius: 8px;
            box-shadow: 0 2px 10px rgba(0, 0, 0, 0.45);
            font: 13px/1.1 ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
            pointer-events: none;
            white-space: nowrap;
            user-select: none;
        }
        .jm-hud b { color: #7fd4ff; font-weight: 600; margin: 0 1px 0 3px; }
        .jm-hud-item:first-child b { margin-left: 0; }
        .jm-hud-sep { width: 1px; height: 15px; background: rgba(255, 255, 255, 0.22); }
        #recenter { display: flex; }
        @media (max-width: 700px) {
            .jm-hud { font-size: 11px; gap: 7px; padding: 6px 10px; bottom: 8px; }
        }
    </style>
'@

$index = Replace-Html $index '</head>' ("`r`n" + $styles.Trim() + "`r`n</head>") 'hud css'

# --- behaviour injected after bundle.js ----------------------------------------
$extra = @'

<script>
(function () {
    var KEYS = [
        "visiblePlayer", "visiblePlayers", "visibleAnimals", "visibleAmbient",
        "visibleMobs", "visibleVillagers", "visiblePolygons", "visibleWaypoints",
        "visibleGrid", "followMapType"
    ];
    var STORE = "jm-webmap-settings";

    function boot() {
        if (! window.app) { setTimeout(boot, 50); return; }

        var app = window.app;

        // Leaflet's map object is created asynchronously, so retry until it is there
        function whenMapReady(cb) {
            var tries = 0;
            (function attempt() {
                var m = app.$refs.map && app.$refs.map.mapObject;
                if (m) { cb(m); return; }
                if (tries++ < 100) { setTimeout(attempt, 100); }
            }());
        }

        // translateCoords(x, z) in the bundle is [z * -1, x]
        app.recenter = function () {
            whenMapReady(function (m) {
                var x = Number(app.playerX), z = Number(app.playerZ);
                if (isFinite(x) && isFinite(z)) { m.setView([z * -1, x]); }
            });
        };

        // keep the zoom readout in the status bar in sync
        whenMapReady(function (m) {
            app.mapZoom = m.getZoom();
            m.on("zoomend", function () { app.mapZoom = m.getZoom(); });
        });

        try {
            var saved = JSON.parse(localStorage.getItem(STORE) || "{}");
            KEYS.forEach(function (k) {
                if (k in saved) { app[k] = saved[k]; }
            });
        } catch (e) { /* corrupt or unavailable storage: keep defaults */ }

        if (typeof app.setGridVisible === "function") {
            app.setGridVisible(!! app.visibleGrid);
        }

        // Watcher, not @change on the switch: Buefy's Switch component only emits
        // "input" (that is what v-model listens to) and never re-emits the native
        // change event, so an @change listener would silently never fire.
        app.$watch("visibleGrid", function (value) {
            if (typeof app.setGridVisible === "function") {
                app.setGridVisible(!! value);
            }
        });

        // the getter must actually touch the reactive props for $watch to subscribe
        app.$watch(
            function () { return KEYS.map(function (k) { return app[k]; }).join(","); },
            function () {
                var out = {};
                KEYS.forEach(function (k) { out[k] = app[k]; });
                try { localStorage.setItem(STORE, JSON.stringify(out)); } catch (e) {}
            }
        );
    }

    boot();
}());
</script>
'@

$index = Replace-Html $index '<script src="bundled/bundle.js"></script>' `
    ('<script src="bundled/bundle.js"></script>' + $extra) 'inline script'

[System.IO.File]::WriteAllText($indexPath, $index, $utf8NoBom)

Write-Host ''
Write-Host 'Done. Override webroot:'
Write-Host "  $out"
(Get-ChildItem -LiteralPath $out -Recurse -File | Measure-Object -Property Length -Sum) |
    ForEach-Object { "  {0} files, {1:N1} MB" -f $_.Count, ($_.Sum / 1MB) }