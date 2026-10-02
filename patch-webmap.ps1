# Builds an override copy of the JourneyMap webmap frontend with:
#   1. a "Chunk grid" toggle wired to the new server-side ?grid=0/1 param
#   2. settings persistence in localStorage (upstream loses them on every reload)
#   3. zoom +/- buttons (upstream only has the scroll wheel, useless on a phone)
#
# The upstream frontend is a webpack bundle, but bundle.js ships with a source map,
# so the readable originals live in webmap-frontend/ for reference.

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

$bundle = [System.IO.File]::ReadAllText($bundlePath)

function Replace-ExactlyOnce {
    param([string]$Text, [string]$Find, [string]$Replace, [string]$Label)

    $count = ([regex]::Matches($Text, [regex]::Escape($Find))).Count
    if ($count -ne 1) {
        throw "[$Label] expected exactly 1 match for anchor, found $count"
    }
    $new = $Text.Replace($Find, $Replace)
    Write-Host ("  ok  {0,-14} (1 occurrence replaced)" -f $Label)
    return $new
}

Write-Host 'Patching bundle.js...'

# 1. datastore default: grid OFF (the whole point of the toggle)
$bundle = Replace-ExactlyOnce $bundle `
    'visiblePolygons:!0,visibleWaypoints:!0,JMTileLayer:dm' `
    'visiblePolygons:!0,visibleWaypoints:!0,visibleGrid:!1,JMTileLayer:dm' `
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

[System.IO.File]::WriteAllText($bundlePath, $bundle, (New-Object System.Text.UTF8Encoding($false)))

# ---------------------------------------------------------------- index.html ----
$index = [System.IO.File]::ReadAllText($indexPath)

Write-Host 'Patching index.html...'

# Chunk grid switch, in its own group after Visibility
$gridSwitch = @'
            <div class="settings-group">
                <div class="field">
                    <b-switch v-model="visibleGrid">
                        Chunk grid
                    </b-switch>
                </div>
            </div>
'@

$anchor = @'
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

if (([regex]::Matches($index, [regex]::Escape($anchor))).Count -ne 1) {
    throw 'index.html: Visibility group anchor not found exactly once'
}
$index = $index.Replace($anchor, $anchor + "`r`n" + $gridSwitch)

# Zoom buttons, top-left above the follow button.
# Inline SVG on purpose: only Settings/Box/Expand/Navigation/Earth/File/CircleX are
# registered in index.js, and webpack tree-shook the other lucide icons out of the
# bundle, so <lucide-icon-plus> would render as an unknown empty element.
$svgAttrs = 'xmlns="http://www.w3.org/2000/svg" width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" style="display:block"'
$plusSvg  = "<svg $svgAttrs><path d=`"M5 12h14`"></path><path d=`"M12 5v14`"></path></svg>"
$minusSvg = "<svg $svgAttrs><path d=`"M5 12h14`"></path></svg>"

$zoomButtons = @"
        <l-control :position="'topleft'"
                   class="leaflet-bar leaflet-control">
            <a @click="zoomBy(1)" id="zoomIn">$plusSvg</a>
            <a @click="zoomBy(-1)" id="zoomOut">$minusSvg</a>
        </l-control>
"@

$zoomAnchor = @'
        <l-control :position="'topleft'"
                   class="leaflet-bar leaflet-control">
            <a @click="toggleFollowMode()" id="center">
'@

if (([regex]::Matches($index, [regex]::Escape($zoomAnchor))).Count -ne 1) {
    throw 'index.html: follow-mode anchor not found exactly once'
}
$index = $index.Replace($zoomAnchor, $zoomButtons + "`r`n" + $zoomAnchor)

# persistence + zoom helper, injected after bundle.js
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

        // zoom buttons need a method; instance props are reachable from templates
        app.zoomBy = function (delta) {
            var map = app.$refs.map && app.$refs.map.mapObject;
            if (map) { map.setZoom(map.getZoom() + delta); }
        };

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

$scriptAnchor = '<script src="bundled/bundle.js"></script>'
if (([regex]::Matches($index, [regex]::Escape($scriptAnchor))).Count -ne 1) {
    throw 'index.html: bundle script tag not found exactly once'
}
$index = $index.Replace($scriptAnchor, $scriptAnchor + $extra)

[System.IO.File]::WriteAllText($indexPath, $index, (New-Object System.Text.UTF8Encoding($false)))

Write-Host ''
Write-Host 'Done. Override webroot:'
Write-Host "  $out"
(Get-ChildItem -LiteralPath $out -Recurse -File | Measure-Object -Property Length -Sum) |
    ForEach-Object { "  {0} files, {1:N1} MB" -f $_.Count, ($_.Sum / 1MB) }