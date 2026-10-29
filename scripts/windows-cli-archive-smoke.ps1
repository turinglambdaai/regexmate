param(
    [Parameter(Mandatory = $true)][string]$Archive,
    [switch]$RequireGui
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$archivePath = (Resolve-Path -LiteralPath $Archive).Path
$install = Join-Path ([System.IO.Path]::GetTempPath()) ("regexmate-archive-smoke-" + [guid]::NewGuid().ToString('N'))

try {
    # Do not accept a CLI that runs only because build/racket is installed
    # next to the source tree: exercise the release ZIP in a fresh directory.
    Expand-Archive -LiteralPath $archivePath -DestinationPath $install -Force
    $exe = Join-Path $install 'bin/regexmate.exe'
    if (-not (Test-Path -LiteralPath $exe -PathType Leaf)) {
        throw "ZIP must contain bin/regexmate.exe"
    }
    if (Test-Path -LiteralPath (Join-Path $install 'regexmate.exe')) {
        throw "ZIP still contains an unexpected root-level regexmate.exe"
    }
    if (-not (Test-Path -LiteralPath (Join-Path $install 'bin/lib') -PathType Container)) {
        throw "Windows Racket runtime libraries must accompany the bin/ executable"
    }

    if ($RequireGui) {
        $gui = Join-Path $install 'gui'
        if (-not (Test-Path -LiteralPath (Join-Path $gui 'regexmate-gui.exe') -PathType Leaf)) {
            throw "The signed-feed ZIP lost its native GUI executable"
        }
        if (-not (Test-Path -LiteralPath (Join-Path $gui 'runtime/racket.boot') -PathType Leaf)) {
            throw "The signed-feed ZIP lost its embedded GUI Racket runtime"
        }
    }

    Push-Location ([System.IO.Path]::GetTempPath())
    try {
        & $exe --version
        if ($LASTEXITCODE -ne 0) { throw "--version returned $LASTEXITCODE" }
        & $exe validate '^\d{3}-\d{4}$'
        if ($LASTEXITCODE -ne 0) { throw "validate returned $LASTEXITCODE" }
        & $exe match '\d+' 'abc 123' --json
        if ($LASTEXITCODE -ne 0) { throw "JSON match returned $LASTEXITCODE" }
        $graph = Join-Path $install 'graph.svg'
        & $exe graph 'ab(c|d)*[0-9]+' -o $graph
        if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $graph -PathType Leaf)) {
            throw "graph failed to create an SVG in the extracted install"
        }
        # A no-match exit is the expected CLI contract, not a PowerShell
        # pipeline failure; inspect the native code explicitly.
        $PSNativeCommandUseErrorActionPreference = $false
        & $exe match 'nomatchpattern' 'text' >$null
        if ($LASTEXITCODE -ne 3) {
            throw "No-match exit status must remain 3, got $LASTEXITCODE"
        }

        # Simulate upgrading a v0.8.0 flat Windows ZIP: its existing EXE stays
        # at the install root and its runtime stays in root/lib. The updater's
        # layout-preserving swap must leave the new binary runnable there.
        $legacy = Join-Path $install 'legacy-flat'
        New-Item -ItemType Directory -Force -Path $legacy | Out-Null
        Copy-Item -LiteralPath $exe -Destination (Join-Path $legacy 'regexmate.exe')
        Copy-Item -LiteralPath (Join-Path $install 'bin/lib') -Destination (Join-Path $legacy 'lib') -Recurse
        & (Join-Path $legacy 'regexmate.exe') --version
        if ($LASTEXITCODE -ne 0) {
            throw "Legacy-root update compatibility smoke failed: $LASTEXITCODE"
        }
    } finally {
        Pop-Location
    }
    # The native negative-case command intentionally returned a nonzero code.
    # Do not allow the GitHub PowerShell wrapper to mistake that verified
    # expected result for the script's own exit status.
    $global:LASTEXITCODE = 0
} finally {
    if (Test-Path -LiteralPath $install) {
        Remove-Item -LiteralPath $install -Recurse -Force
    }
}
