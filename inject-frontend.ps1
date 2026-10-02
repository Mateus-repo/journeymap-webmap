# Injects the patched webmap frontend into the built mod jar.
#
# The mod ships the web frontend as a jar-in-jar at META-INF/jars/webmap-client-*.jar.
# WebMap.java only falls back to that classpath copy when no external assets_root is
# set, and the local-copy path it uses otherwise gets wiped on every launch. Putting
# the patched assets inside the jar is what makes the change stick with zero setup.
#
# Usage:  powershell -File inject-frontend.ps1 -BuiltJar <path to fabric jar>

param(
    [Parameter(Mandatory = $true)][string]$BuiltJar
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression.FileSystem
Add-Type -AssemblyName System.IO.Compression

$root    = Split-Path -Parent $MyInvocation.MyCommand.Path
$assets  = Join-Path $root 'webmap-assets'
$official= Join-Path $root '_official\journeymap-webmap-fabric-26.3-1.0.13.jar'
$dist    = Join-Path $root 'dist'

if (-not (Test-Path -LiteralPath $assets))  { throw "webmap-assets not found: $assets" }
if (-not (Test-Path -LiteralPath $BuiltJar)) { throw "built jar not found: $BuiltJar" }

# --- 1. work out the nested jar's name from the built jar ----------------------
$zip = [System.IO.Compression.ZipFile]::OpenRead($BuiltJar)
try {
    $nested = $zip.Entries |
        Where-Object { $_.FullName -match '^META-INF/jars/webmap-client.*\.jar$' } |
        Select-Object -First 1
    if (-not $nested) { throw 'no META-INF/jars/webmap-client*.jar inside the built jar' }
    $nestedName = $nested.FullName
}
finally { $zip.Dispose() }

Write-Host "nested jar : $nestedName"

# --- 2. rebuild that nested jar with our assets swapped in ---------------------
if (Test-Path -LiteralPath $dist) { Remove-Item -LiteralPath $dist -Recurse -Force }
New-Item -ItemType Directory -Force -Path $dist | Out-Null

$tmpNested = Join-Path $dist ([System.IO.Path]::GetFileName($nestedName))

if (Test-Path -LiteralPath $official) {
    # start from the official nested jar so fabric.mod.json and anything else survive
    $oz   = [System.IO.Compression.ZipFile]::OpenRead($official)
    $oent = $oz.Entries | Where-Object { $_.FullName -eq $nestedName } | Select-Object -First 1
    [System.IO.Compression.ZipFileExtensions]::ExtractToFile($oent, $tmpNested, $true)
    $oz.Dispose()
    Write-Host 'base       : taken from the official mod jar'
}
else {
    Copy-Item -LiteralPath $BuiltJar -Destination $tmpNested
    Write-Host 'base       : WARNING fell back to copying the mod jar (should not happen)'
}

$WANTED_PREFIX = 'assets/journeymap/web/'

$nz = [System.IO.Compression.ZipFile]::Open($tmpNested, [System.IO.Compression.ZipArchiveMode]::Update)
try {
    $stale = @($nz.Entries | Where-Object { $_.FullName.StartsWith($WANTED_PREFIX) })
    foreach ($e in $stale) { $e.Delete() }
    Write-Host ("removed    : {0} upstream frontend entries" -f $stale.Count)

    $added = 0
    foreach ($f in Get-ChildItem -LiteralPath $assets -Recurse -File) {
        $rel = $f.FullName.Substring($assets.Length + 1).Replace('\', '/')
        $entryName = $WANTED_PREFIX + $rel

        [System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile(
            $nz, $f.FullName, $entryName, [System.IO.Compression.CompressionLevel]::Optimal) | Out-Null
        $added++
    }
    Write-Host ("added      : {0} patched frontend files" -f $added)
}
finally { $nz.Dispose() }

# --- 3. swap the nested jar inside the mod jar ---------------------------------
$outJar = Join-Path $dist ([System.IO.Path]::GetFileName($BuiltJar))
Copy-Item -LiteralPath $BuiltJar -Destination $outJar -Force

$mz = [System.IO.Compression.ZipFile]::Open($outJar, [System.IO.Compression.ZipArchiveMode]::Update)
try {
    $old = $mz.Entries | Where-Object { $_.FullName -eq $nestedName } | Select-Object -First 1
    $old.Delete()

    [System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile(
        $mz, $tmpNested, $nestedName, [System.IO.Compression.CompressionLevel]::NoCompression) | Out-Null
}
finally { $mz.Dispose() }

Write-Host ''
Write-Host 'Patched mod jar:'
Write-Host "  $outJar"
Write-Host ("  {0:N2} MB" -f ((Get-Item -LiteralPath $outJar).Length / 1MB))

# --- 4. verify the swap actually landed ---------------------------------------
$vz = [System.IO.Compression.ZipFile]::OpenRead($outJar)
try {
    $check = $vz.Entries | Where-Object { $_.FullName -eq $nestedName } | Select-Object -First 1
    if (-not $check) { throw 'verification failed: nested jar missing from output' }
    $ms = New-Object System.IO.MemoryStream
    $s  = $check.Open(); $s.CopyTo($ms); $s.Dispose()
    $ms.Position = 0

    $inner = New-Object System.IO.Compression.ZipArchive($ms, [System.IO.Compression.ZipArchiveMode]::Read)
    $html  = $inner.GetEntry('assets/journeymap/web/index.html')
    if (-not $html) { throw 'verification failed: index.html missing from nested jar' }
    $sr = New-Object System.IO.StreamReader($html.Open())
    $text = $sr.ReadToEnd(); $sr.Dispose()
    $inner.Dispose()

    foreach ($probe in 'visibleGrid', 'zoomIn', 'jm-webmap-settings') {
        if ($text -notmatch $probe) { throw "verification failed: '$probe' not found in patched index.html" }
        Write-Host ("verified   : {0}" -f $probe)
    }
}
finally { $vz.Dispose() }

Write-Host ''
Write-Host 'OK'