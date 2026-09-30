<#
    Pester 6.x regression tests for SWD/tools/phase2/swd_diff.py.
    Runs with SWD CLOSED; only exercises the offline image-diff CLI.
#>

BeforeAll {
    # Local 'Continue' for every test in this file (SQA W5): run_pester.ps1 sets 'Stop', under
    # which Windows PowerShell 5.1 turns the 'error:' line swd_diff.py writes to stderr into a
    # terminating error, so the exit-code and message assertions below were never reached.
    $ErrorActionPreference = 'Continue'
    $repo = (Resolve-Path (Join-Path $PSScriptRoot '\..\..\..\..')).Path
    $script:SwdDiff = Join-Path $repo 'SWD\tools\phase2\swd_diff.py'
    $script:MakePng = {
        param([string]$Path, [int]$Width, [int]$Height)
        # Path and size go in through argv, never into the source text: a quote in the path
        # broke the r'...' literal this used to build (SQA S7).
        $py = @'
import sys
from PIL import Image
import numpy as np
img = np.zeros((int(sys.argv[2]), int(sys.argv[1])), dtype=np.uint8)
Image.fromarray(img, mode='L').save(sys.argv[3])
'@
        & py -3.14 -c $py $Width $Height $Path
    }
}

Describe 'swd_diff.py pair validation' {
    It 'reports a clean error instead of a traceback when image sizes differ' {
        $d = Join-Path $TestDrive 'pair-mismatch'
        New-Item -ItemType Directory -Path $d | Out-Null
        & $script:MakePng -Path (Join-Path $d 'before.png') -Width 100 -Height 100
        & $script:MakePng -Path (Join-Path $d 'after.png') -Width 200 -Height 200
        $out = & py -3.14 $script:SwdDiff 'pair' (Join-Path $d 'before.png') (Join-Path $d 'after.png') 2>&1 | Out-String
        $LASTEXITCODE | Should -Not -Be 0
        $out | Should -Not -Match 'Traceback'
        $out | Should -Match 'shape mismatch'
    }

    It 'still classifies identical same-size images as unchanged' {
        $d = Join-Path $TestDrive 'pair-ok'
        New-Item -ItemType Directory -Path $d | Out-Null
        & $script:MakePng -Path (Join-Path $d 'a.png') -Width 120 -Height 80
        Copy-Item (Join-Path $d 'a.png') (Join-Path $d 'b.png')
        $out = & py -3.14 $script:SwdDiff 'pair' (Join-Path $d 'a.png') (Join-Path $d 'b.png') 2>&1 | Out-String
        $LASTEXITCODE | Should -Be 0
        $json = $out | ConvertFrom-Json
        $json.changed_tiles | Should -Be 0
    }
}

Describe 'swd_diff.py idle validation' {
    It 'reports a clean error instead of a traceback for an empty frames directory' {
        $d = Join-Path $TestDrive 'idle-empty'
        New-Item -ItemType Directory -Path $d | Out-Null
        $out = & py -3.14 $script:SwdDiff 'idle' $d 2>&1 | Out-String
        $LASTEXITCODE | Should -Not -Be 0
        $out | Should -Not -Match 'Traceback'
        $out | Should -Match 'no PNG frames'
    }

    It 'reports a clean error instead of a traceback when frames differ in size' {
        $d = Join-Path $TestDrive 'idle-mismatch'
        New-Item -ItemType Directory -Path $d | Out-Null
        & $script:MakePng -Path (Join-Path $d 'f1.png') -Width 100 -Height 100
        & $script:MakePng -Path (Join-Path $d 'f2.png') -Width 200 -Height 200
        $out = & py -3.14 $script:SwdDiff 'idle' $d 2>&1 | Out-String
        $LASTEXITCODE | Should -Not -Be 0
        $out | Should -Not -Match 'Traceback'
        $out | Should -Match 'shape mismatch'
    }
}

Describe 'test fixtures survive awkward paths (SQA S7)' {
    It 'MakePng writes into, and swd_diff.py reads from, a folder named with <label>' -ForEach @(
        @{ label = 'an ASCII apostrophe'; name = "it's here" }
        @{ label = 'a curly apostrophe, a space and an e-acute'; name = ('Anna' + [char]0x2019 + 's caf' + [char]0x00E9) }
    ) {
        $d = Join-Path $TestDrive $name
        New-Item -ItemType Directory -Path $d -Force | Out-Null
        $a = Join-Path $d 'a.png'
        & $script:MakePng -Path $a -Width 40 -Height 30
        Test-Path -LiteralPath $a | Should -BeTrue
        $out = & py -3.14 $script:SwdDiff 'pair' $a $a 2>&1 | Out-String
        $LASTEXITCODE | Should -Be 0
        ($out | ConvertFrom-Json).changed_tiles | Should -Be 0
    }
}

Describe 'swd_diff.py idle reports the true pair count (SQA S23)' {
    It '<count> frame(s) make <pairs> pair(s)' -ForEach @(
        @{ count = 1; pairs = 0 }
        @{ count = 3; pairs = 2 }
    ) {
        $d = Join-Path $TestDrive "idle-count-$count"
        New-Item -ItemType Directory -Path $d | Out-Null
        foreach ($i in 1..$count) { & $script:MakePng -Path (Join-Path $d "f$i.png") -Width 64 -Height 48 }
        $out = & py -3.14 $script:SwdDiff 'idle' $d 2>&1 | Out-String
        $LASTEXITCODE | Should -Be 0
        $j = $out | ConvertFrom-Json
        $j.frames | Should -Be $count
        $j.pairs | Should -Be $pairs
        if ($pairs -eq 0) {
            # Nothing was timed, so no per-pair figure is reported (never 0 ms).
            $null -eq $j.ms_per_pair_tile | Should -BeTrue
            $null -eq $j.ms_per_pair_ssim | Should -BeTrue
        } else {
            $j.ms_per_pair_tile | Should -BeGreaterOrEqual 0
        }
        Test-Path -LiteralPath (Join-Path $d 'noise_mask.npy') | Should -BeTrue
    }
}

Describe 'swd_diff.py idle streams its frames (SQA E-W1)' {
    It 'compares each frame with the one before it, not with the first' {
        # f0 plain, f1 with one changed tile, f2 = f1: two pairs, and only the first differs.
        $d = Join-Path $TestDrive 'idle-pairing'
        New-Item -ItemType Directory -Path $d | Out-Null
        $gen = @'
import os, sys
import numpy as np
from PIL import Image
a = np.full((64, 96), 100, np.uint8)
b = a.copy(); b[5:10, 5:10] = 200
for i, f in enumerate((a, b, b.copy())):
    Image.fromarray(f).save(os.path.join(sys.argv[1], 'f%d.png' % i))
'@
        & py -3.14 -c $gen $d
        $j = (& py -3.14 $script:SwdDiff 'idle' $d 2>&1 | Out-String) | ConvertFrom-Json
        $j.pairs | Should -Be 2
        $j.pairs_flagged_tile | Should -Be 1
        $j.noise_tiles | Should -Be 1
    }
    It 'holds two frames at a time: peak memory does not grow with the frame count' {
        $probe = @'
import json, os, sys, tracemalloc
sys.dont_write_bytecode = True   # import the script under test without writing into its folder
sys.path.insert(0, sys.argv[1])
import numpy as np
from PIL import Image
import swd_diff
def peak(n, d):
    os.makedirs(d)
    for i in range(n):
        a = np.full((400, 600), 100, np.uint8); a[:32, :32] = i % 251
        Image.fromarray(a).save(os.path.join(d, 'f%03d.png' % i))
    tracemalloc.start(); swd_diff.idle(d); p = tracemalloc.get_traced_memory()[1]; tracemalloc.stop()
    return p
root = sys.argv[2]
print(json.dumps({'growth': peak(12, os.path.join(root, 'n12')) - peak(3, os.path.join(root, 'n3')), 'frame': 400 * 600 * 4}))
'@
        $root = Join-Path $TestDrive 'idle-memory'
        New-Item -ItemType Directory -Path $root | Out-Null
        $j = (& py -3.14 -c $probe (Split-Path -Parent $script:SwdDiff) $root 2>&1 | Out-String) | ConvertFrom-Json
        # Loading every frame first grew the peak by one float32 frame per extra frame (9 here).
        $j.growth | Should -BeLessThan (2 * $j.frame)
    }
}
