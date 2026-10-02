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

# 1. datastore defaults: grid OFF, plus state for the status bar and the UI toggle
$bundle = Replace-ExactlyOnce $bundle `
    'visiblePolygons:!0,visibleWaypoints:!0,JMTileLayer:dm' `
    'visiblePolygons:!0,visibleWaypoints:!0,visibleGrid:!1,mapZoom:0,currentMapType:"day",uiHidden:!1,JMTileLayer:dm' `
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
# The eye button lives inside the HUD on purpose: it is the one thing that stays
# visible when the rest of the UI is hidden, so there is always a way back. On a
# phone there is no keyboard for the h shortcut, so this has to stay clickable.
$eyeOn  = "<svg viewBox=`"0 0 24 24`"><path d=`"M1 12s4-7 11-7 11 7 11 7-4 7-11 7-11-7-11-7z`"></path><circle cx=`"12`" cy=`"12`" r=`"3`"></circle></svg>"
$eyeOff = "<svg viewBox=`"0 0 24 24`"><path d=`"M17.94 17.94A10.1 10.1 0 0 1 12 19c-7 0-11-7-11-7a18.5 18.5 0 0 1 5.06-5.94`"></path><path d=`"M1 1l22 22`"></path><path d=`"M9.9 4.24A9.1 9.1 0 0 1 12 4c7 0 11 7 11 7a18.5 18.5 0 0 1-2.16 3.19`"></path></svg>"

$statusBar = @"
    <div class="jm-hud">
        <button class="jm-hud-btn" @click="toggleUi()" :title="uiHidden ? 'Show controls' : 'Hide controls'">
            <svg v-if="! uiHidden" viewBox="0 0 24 24">$eyeOn</svg>
            <svg v-else viewBox="0 0 24 24">$eyeOff</svg>
        </button>
        <span class="jm-hud-item"><b>x</b><span v-text="playerX"></span></span>
        <span class="jm-hud-item"><b>y</b><span v-text="playerY"></span></span>
        <span class="jm-hud-item"><b>z</b><span v-text="playerZ"></span></span>
        <span class="jm-hud-sep"></span>
        <span class="jm-hud-item" v-text="playerBiome"></span>
        <span class="jm-hud-item" v-text="playerWorld"></span>
        <span class="jm-hud-sep"></span>
        <span class="jm-hud-item">zoom <b v-text="mapZoom"></b></span>
    </div>
"@

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

        .jm-hud-btn {
            pointer-events: auto;
            display: flex;
            align-items: center;
            padding: 2px;
            margin: 0 2px 0 0;
            background: none;
            border: 0;
            cursor: pointer;
            color: #cfd6e4;
        }
        .jm-hud-btn:hover { color: #7fd4ff; }
        .jm-hud-btn svg { width: 16px; height: 16px; fill: none; stroke: currentColor;
            stroke-width: 2; stroke-linecap: round; stroke-linejoin: round; display: block; }

        /* hiding the chrome: the status bar stays, it holds the button that brings it back */
        body.jm-ui-hidden .leaflet-control-container { display: none; }

        /* mark which map type is active; upstream gives every button the same look */
        #mapTypeDay, #mapTypeNight, #mapTypeTopo, #mapTypeUnderground { opacity: 0.4; }
        #mapTypeDay.jm-active, #mapTypeNight.jm-active,
        #mapTypeTopo.jm-active, #mapTypeUnderground.jm-active {
            opacity: 1;
            border-radius: 3px;
            box-shadow: inset 0 0 0 2px #7fd4ff;
        }

        .jm-keys { font-size: 12px; line-height: 1.9; }
        .jm-keys kbd {
            display: inline-block;
            min-width: 1.4em;
            padding: 0 5px;
            border: 1px solid #555f70;
            border-bottom-width: 2px;
            border-radius: 4px;
            background: #2a3040;
            color: #dfe6f2;
            font: 11px/1.6 ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
            text-align: center;
        }
        .jm-keys div { display: flex; justify-content: space-between; gap: 12px; }
        .jm-keys span { color: #b6c0d0; }

        @media (max-width: 700px) {
            .jm-hud { font-size: 11px; gap: 7px; padding: 6px 10px; bottom: 8px; }
        }
    </style>
'@

$index = Replace-Html $index '</head>' ("`r`n" + $styles.Trim() + "`r`n</head>") 'hud css'

# --- keyboard legend in the settings pane --------------------------------------
$keysPanel = @'
        <div class="settings-pane-header">
            Keyboard
        </div>
        <div class="content">
            <div class="jm-keys">
                <div><span>Chunk grid</span><kbd>g</kbd></div>
                <div><span>Follow player</span><kbd>f</kbd></div>
                <div><span>Recentre</span><kbd>r</kbd></div>
                <div><span>Hide controls</span><kbd>h</kbd></div>
                <div><span>Reset zoom</span><kbd>0</kbd></div>
                <div><span>Zoom in / out</span><kbd>+ / -</kbd></div>
            </div>
        </div>
    </b-collapse>
'@

$keysAnchor = @'
                <div class="field">
                    <b-switch v-model="followMapType">
                        Match Minimap Type
                    </b-switch>
                </div>
            </div>
        </div>
    </b-collapse>
'@

$index = Replace-Html $index $keysAnchor ($keysAnchor.TrimEnd("`r`n") + "`r`n`r`n" + $keysPanel) 'keyboard legend'

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

        function save() {
            var out = {};
            KEYS.forEach(function (k) { out[k] = app[k]; });
            try { localStorage.setItem(STORE, JSON.stringify(out)); } catch (e) {}
        }

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

        // ---- hide / show the controls ---------------------------------------
        function applyUi() {
            document.body.classList.toggle("jm-ui-hidden", !! app.uiHidden);
        }
        app.toggleUi = function () {
            app.uiHidden = ! app.uiHidden;
            applyUi();
            save();
        };
        app.$watch("uiHidden", applyUi);
        applyUi();

        // ---- mark the active map type ---------------------------------------
        var MODE_BY_ID = {
            mapTypeDay: "day",
            mapTypeNight: "night",
            mapTypeTopo: "topo",
            mapTypeUnderground: "underground",
        };
        function paintMapType() {
            Object.keys(MODE_BY_ID).forEach(function (id) {
                var el = document.getElementById(id);
                if (el) { el.classList.toggle("jm-active", MODE_BY_ID[id] === app.currentMapType); }
            });
        }
        Object.keys(MODE_BY_ID).forEach(function (id) {
            var el = document.getElementById(id);
            if (el) {
                el.addEventListener("click", function () {
                    app.currentMapType = MODE_BY_ID[id];
                    paintMapType();
                    save();
                });
            }
        });
        app.$watch("currentMapType", paintMapType);

        // ---- persist the view, the map type and the ui state -----------------
        // The saved view is only applied once status flips to "ready": journeymap.js
        // calls setView() on the player only during that transition, so applying
        // earlier would just be overwritten.
        function saveView(m) {
            var c = m.getCenter();
            try {
                localStorage.setItem("jm-webmap-view", JSON.stringify({
                    lat: c.lat, lng: c.lng, zoom: m.getZoom(),
                    mapType: app.currentMapType, uiHidden: !! app.uiHidden,
                }));
            } catch (e) { /* storage full or unavailable */ }
        }

        var savedView = null;
        try { savedView = JSON.parse(localStorage.getItem("jm-webmap-view") || "null"); } catch (e) {}
        if (savedView) {
            if (typeof savedView.mapType === "string") { app.currentMapType = savedView.mapType; }
            if (typeof savedView.uiHidden === "boolean") { app.uiHidden = savedView.uiHidden; }
        }
        paintMapType();

        function restoreView(m) {
            if (! savedView) return;
            var z = (typeof savedView.zoom === "number") ? savedView.zoom : m.getZoom();
            // One atomic, un-animated setView. Calling setZoom and setView separately
            // lets Leaflet animate both, and moveend/zoomend then fire while the view is
            // still in flight, so the wrong centre and zoom end up saved again.
            if (typeof savedView.lat === "number" && typeof savedView.lng === "number") {
                m.setView([savedView.lat, savedView.lng], z, { animate: false });
            } else {
                m.setZoom(z, { animate: false });
            }
        }

        var viewRestored = false;
        app.$watch("status", function (s) {
            if (s !== "ready" || viewRestored) { return; }
            viewRestored = true;
            whenMapReady(function (m) {
                restoreView(m);
                m.on("moveend zoomend", function () { saveView(m); });
                saveView(m);
            });
        });

        // ---- keyboard shortcuts ---------------------------------------------
        // + / - are left to Leaflet, which already binds them on the focused map.
        // Arrows are left alone for the same reason.
        document.addEventListener("keydown", function (ev) {
            if (ev.ctrlKey || ev.altKey || ev.metaKey) { return; }
            var tag = (ev.target && ev.target.tagName || "").toLowerCase();
            if (tag === "input" || tag === "textarea" || ev.target.isContentEditable) { return; }
            if (document.querySelector(".log-modal.is-active")) { return; }

            var k = ev.key;
            var hit = true;

            switch (k) {
                case "g": case "G": app.visibleGrid = ! app.visibleGrid; break;
                case "f": case "F": app.toggleFollowMode(); break;
                case "r": case "R": app.recenter(); break;
                case "h": case "H": app.toggleUi(); break;
                case "0": whenMapReady(function (m) { m.setZoom(0); }); break;
                default: hit = false;
            }

            if (hit) { ev.preventDefault(); save(); }
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
            save
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