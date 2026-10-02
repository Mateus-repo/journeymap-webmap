# Injects the patched webmap frontend into the built mod jar.
#
# The mod ships the web frontend as a jar-in-jar at META-INF/jars/webmap-client-*.jar.
# WebMap.java only falls back to that classpath copy when no external assets_root is
# set, and the local-copy path it uses otherwise gets wiped on every launch. Putting
# the patched assets inside the jar is what makes the change stick with zero setup.
#
# Both archives are rebuilt from scratch rather than opened in ZipArchiveMode::Update.
# Update mode rewrites local headers and can emit an EXT data descriptor on a STORED
# entry, which java.util.zip.ZipInputStream rejects with
# "only DEFLATED entries can have EXT descriptor" - and that is exactly the parser
# Fabric Loader uses to scan nested jars, so the mod then fails discovery and the
# game refuses to launch. Everything below is written with Optimal compression.
#
# Usage:  powershell -File inject-frontend.ps1 -BuiltJar <path to fabric jar>

param(
    [Parameter(Mandatory = $true)][string]$BuiltJar
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression.FileSystem
Add-Type -AssemblyName System.IO.Compression

$root     = Split-Path -Parent $MyInvocation.MyCommand.Path
$assets   = Join-Path $root 'webmap-assets'
$official = Join-Path $root '_official\journeymap-webmap-fabric-26.3-1.0.13.jar'
$dist     = Join-Path $root 'dist'
$tmp      = Join-Path $root '.inject-tmp'

$WANTED = 'assets/journeymap/web/'
$OPT    = [System.IO.Compression.CompressionLevel]::Optimal

if (-not (Test-Path -LiteralPath $assets))   { throw "webmap-assets not found: $assets" }
if (-not (Test-Path -LiteralPath $BuiltJar)) { throw "built jar not found: $BuiltJar" }
if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Recurse -Force }
New-Item -ItemType Directory -Force -Path $tmp | Out-Null

# --- 1. locate the nested jar ---------------------------------------------------
$baseJar = $official
if (-not (Test-Path -LiteralPath $baseJar)) { $baseJar = $BuiltJar }

$z = [System.IO.Compression.ZipFile]::OpenRead($baseJar)
try {
    $nested = $z.Entries |
        Where-Object { $_.FullName -match '^META-INF/jars/webmap-client.*\.jar$' } |
        Select-Object -First 1
    if (-not $nested) { throw 'no META-INF/jars/webmap-client*.jar in ' + $baseJar }
    $nestedName = $nested.FullName
    $origNested = Join-Path $tmp 'orig-webmap-client.jar'
    [System.IO.Compression.ZipFileExtensions]::ExtractToFile($nested, $origNested, $true)
}
finally { $z.Dispose() }

Write-Host "nested jar : $nestedName"
Write-Host "base jar   : $(Split-Path $baseJar -Leaf)"

# --- 2. rebuild the nested jar fresh -------------------------------------------
$newNested = Join-Path $tmp 'new-webmap-client.jar'

$src = [System.IO.Compression.ZipFile]::OpenRead($origNested)
$dst = [System.IO.Compression.ZipFile]::Open($newNested, [System.IO.Compression.ZipArchiveMode]::Create)
try {
    $kept = 0
    $keptDirs = 0
    $dropped = 0

    # Directory entries must be preserved. Javalin's CLASSPATH static-file lookup
    # resolves the web root as a classpath *directory*, which only works if the
    # archive actually contains directory entries such as assets/journeymap/web/.
    # Dropping them makes the server abort with "Static resource directory ... does
    # not exist" and every request 404s, even though every file is present.
    foreach ($e in $src.Entries) {
        if ($e.FullName.EndsWith('/')) {
            $dst.CreateEntry($e.FullName, $OPT) | Out-Null
            $keptDirs++
            continue
        }

        if ($e.FullName.StartsWith($WANTED)) { $dropped++; continue }

        $ne = $dst.CreateEntry($e.FullName, $OPT)
        $ne.LastWriteTime = $e.LastWriteTime
        $ins = $e.Open()
        $outs = $ne.Open()
        $ins.CopyTo($outs)
        $outs.Dispose(); $ins.Dispose()
        $kept++
    }
    Write-Host ("nested     : kept {0} files + {1} dir entries, replaced {2}" -f $kept, $keptDirs, $dropped)

    $added = 0
    foreach ($f in Get-ChildItem -LiteralPath $assets -Recurse -File) {
        $rel = $f.FullName.Substring($assets.Length + 1).Replace('\', '/')
        $ne = $dst.CreateEntry($WANTED + $rel, $OPT)
        $ne.LastWriteTime = $f.LastWriteTime
        $ins = [System.IO.File]::OpenRead($f.FullName)
        $outs = $ne.Open()
        $ins.CopyTo($outs)
        $outs.Dispose(); $ins.Dispose()
        $added++
    }
    Write-Host ("nested     : added {0} patched frontend files" -f $added)
}
finally { $dst.Dispose(); $src.Dispose() }

# --- 3. rebuild the mod jar fresh ----------------------------------------------
if (Test-Path -LiteralPath $dist) { Remove-Item -LiteralPath $dist -Recurse -Force }
New-Item -ItemType Directory -Force -Path $dist | Out-Null
$outJar = Join-Path $dist ([System.IO.Path]::GetFileName($BuiltJar))

$msrc = [System.IO.Compression.ZipFile]::OpenRead($BuiltJar)
$mdst = [System.IO.Compression.ZipFile]::Open($outJar, [System.IO.Compression.ZipArchiveMode]::Create)
try {
    $n = 0
    foreach ($e in $msrc.Entries) {
        if ($e.FullName.EndsWith('/')) {
            $mdst.CreateEntry($e.FullName, $OPT) | Out-Null
            $n++
            continue
        }

        $ne = $mdst.CreateEntry($e.FullName, $OPT)
        $ne.LastWriteTime = $e.LastWriteTime

        if ($e.FullName -eq $nestedName) {
            $ins = [System.IO.File]::OpenRead($newNested)
        } else {
            $ins = $e.Open()
        }
        $outs = $ne.Open()
        $ins.CopyTo($outs)
        $outs.Dispose(); $ins.Dispose()
        $n++
    }
    Write-Host ("mod jar    : wrote {0} entries" -f $n)
}
finally { $mdst.Dispose(); $msrc.Dispose() }

Write-Host ''
Write-Host 'Patched mod jar:'
Write-Host "  $outJar"
Write-Host ("  {0:N2} MB" -f ((Get-Item -LiteralPath $outJar).Length / 1MB))

Remove-Item -LiteralPath $tmp -Recurse -Force