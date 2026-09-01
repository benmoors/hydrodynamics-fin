<#
    Pester 6.x tests for swd_msg.ps1.  SQA finding S24.

    RUN WITH SWD CLOSED. Nothing here launches, contacts or requires
    SurfHydrodynamics: every test covers either a pure function or a window this
    test process created itself. If a test in here ever needs SWD, it is in the
    wrong file.

        powershell.exe -NoProfile -ExecutionPolicy Bypass -Command ^
          "Import-Module Pester -MinimumVersion 6.0; Invoke-Pester '<this file>' -Output Detailed"

    Pester 6.x syntax. The bundled Pester 3.4.0 on this machine CANNOT run it -
    check with (Get-Module Pester -ListAvailable).Version before blaming a test.

    Two things deliberately NOT tested here, because they cannot be tested
    honestly without the application:
      - whether BM_CLICK and WM_SETTEXT cross the UIPI boundary into SWD;
      - whether SWD renders numerics in French. The fr-FR test below proves the
        PARSER copes either way, which is the part this file owns.
#>

BeforeAll {
    $script:Lib = Join-Path (Split-Path -Parent $PSScriptRoot) 'swd_msg.ps1'
    if (-not (Test-Path -LiteralPath $script:Lib)) { throw "Cannot find swd_msg.ps1 at $script:Lib" }
    . $script:Lib

    # Format-Record, not New-Record: PSUseShouldProcessForStateChangingFunctions
    # fires on the New- verb and this helper only builds a string.
    function Format-Record {
        param([string]$Handle = '4242', [string]$Class = 'WindowsForms10.BUTTON.app.0.x',
              [string]$CtrlId = '7', [string]$Visible = 'True', [string]$Enabled = 'True',
              [string]$Rect = '10,20,110,140', [string]$Parent = '99')
        ($Handle, $Class, $CtrlId, $Visible, $Enabled, $Rect, $Parent) -join ([SwdWin]::SEP)
    }

    # A real HWND owned by THIS process, so the handle predicate can be tested
    # without SWD and without touching any window that is not ours.
    Add-Type -AssemblyName System.Windows.Forms
    $script:Form = New-Object System.Windows.Forms.Form
    $script:Form.Text = 'swd_msg.Tests harness'
    $script:Btn = New-Object System.Windows.Forms.Button
    $script:Btn.Text = 'probe'
    $script:Form.Controls.Add($script:Btn)
    $script:OwnHwnd = [int64]$script:Form.Handle          # forces handle creation; never shown
    $script:BtnHwnd = [int64]$script:Btn.Handle

    # A handle that WAS a window and is not one now. Several tests need the
    # difference between "not a window" and "a window of another process", and
    # fabricating an integer would not give it: an arbitrary number is usually
    # not a window either, but it was never ours, so it cannot show that the
    # predicate distinguishes destruction from foreignness.
    $dead = New-Object System.Windows.Forms.Form
    $script:DeadHwnd = [int64]$dead.Handle
    $dead.Dispose()
}

AfterAll {
    if ($script:Form) { $script:Form.Dispose() }
}

Describe 'ConvertTo-Kmh' {
    It 'converts <ms> m/s to <kmh> km/h' -ForEach @(
        @{ ms = 20;    kmh = 72 }        # every one of the 132 existing scans
        @{ ms = 10;    kmh = 36 }        # the verification target
        @{ ms = 0;     kmh = 0 }
        @{ ms = 1;     kmh = 3.6 }
        @{ ms = -5;    kmh = -18 }
        @{ ms = 2.5;   kmh = 9 }
        @{ ms = 0.001; kmh = 0.0036 }
    ) { ConvertTo-Kmh -Ms $ms | Should -Be $kmh }

    It 'rounds to 4 decimal places rather than carrying binary noise' {
        # 1/3 m/s = 1.2 km/h exactly is NOT the point; the point is a stable,
        # short decimal that can be typed into a km/h spin box.
        ConvertTo-Kmh -Ms (1/3) | Should -Be 1.2
        ConvertTo-Kmh -Ms 0.00001 | Should -Be 0
    }

    It 'refuses a non-numeric argument instead of coercing it' {
        { ConvertTo-Kmh -Ms 'twenty' } | Should -Throw
    }

    It 'is the unit trap it exists for: 10 typed raw is NOT 10 m/s' {
        # Typing 10 into a km/h box asks for 2.78 m/s. The guard is that the
        # conversion exists and is used, so 10 m/s must not map to 10.
        ConvertTo-Kmh -Ms 10 | Should -Not -Be 10
    }
}

Describe 'ConvertFrom-SwdControlRecord' {
    It 'parses a well-formed 7-field record into typed fields' {
        $r = ConvertFrom-SwdControlRecord -Line (Format-Record)
        $r.Handle  | Should -Be 4242
        $r.Handle  | Should -BeOfType [int64]
        $r.Class   | Should -Be 'WindowsForms10.BUTTON.app.0.x'
        $r.CtrlId  | Should -Be 7
        $r.Visible | Should -BeTrue
        $r.Enabled | Should -BeTrue
        $r.Rect    | Should -Be '10,20,110,140'
        $r.Parent  | Should -Be 99
    }

    It 'rejects a record with <n> fields' -ForEach @(
        @{ n = 1 }, @{ n = 2 }, @{ n = 6 }, @{ n = 8 }, @{ n = 14 }
    ) {
        $line = ((1..$n | ForEach-Object { "f$_" }) -join [SwdWin]::SEP)
        { ConvertFrom-SwdControlRecord -Line $line } | Should -Throw '*expected 7*'
    }

    It 'rejects an empty line rather than returning a half-built row' {
        { ConvertFrom-SwdControlRecord -Line '' } | Should -Throw '*expected 7*'
    }

    It 'survives a pipe in the class name - the whole reason the separator is US' {
        # The first draft joined on '|'. A '|' in a class name would have split
        # into 8 fields and corrupted the map silently.
        $r = ConvertFrom-SwdControlRecord -Line (Format-Record -Class 'Weird|Class|Name')
        $r.Class | Should -Be 'Weird|Class|Name'
    }

    It 'passes through the markers the C# layer sets for a failed read' {
        $r = ConvertFrom-SwdControlRecord -Line (Format-Record -Class 'Long.Class<TRUNCATED>' -Rect 'UNKNOWN')
        $r.Class | Should -Be 'Long.Class<TRUNCATED>'   # GetClassName ran out of buffer
        $r.Rect  | Should -Be 'UNKNOWN'                 # GetWindowRect returned false
    }

    It 'handles extreme but legal numeric fields' {
        $r = ConvertFrom-SwdControlRecord -Line (Format-Record -Handle '9223372036854775807' -CtrlId '-1' -Parent '0')
        $r.Handle | Should -Be 9223372036854775807
        $r.CtrlId | Should -Be -1
        $r.Parent | Should -Be 0
    }

    # [char]0x1F, not [SwdWin]::SEP: -ForEach data is evaluated in Pester's
    # DISCOVERY phase, before BeforeAll has dot-sourced the library, so the type
    # does not exist yet. The 'SwdWin native layer' block asserts the literal and
    # the constant are the same value, so this cannot drift silently.
    It 'throws rather than guessing on a malformed <field> field' -ForEach @(
        @{ field = 'Handle';  fields = @('nope', 'C', '7', 'True', 'True', 'r', '9') }
        @{ field = 'CtrlId';  fields = @('1', 'C', 'x', 'True', 'True', 'r', '9') }
        @{ field = 'Visible'; fields = @('1', 'C', '7', 'yes', 'True', 'r', '9') }
        @{ field = 'Enabled'; fields = @('1', 'C', '7', 'True', '1', 'r', '9') }
    ) {
        $line = $fields -join ([char]0x1F)
        { ConvertFrom-SwdControlRecord -Line $line } | Should -Throw
    }
}

Describe 'ConvertTo-SwdNumber' {
    It 'parses invariant decimal point and says which culture answered' {
        $r = ConvertTo-SwdNumber -Text '10.5'
        $r.Ok | Should -BeTrue
        $r.Value | Should -Be 10.5
        $r.Culture | Should -Be 'Invariant'
    }

    It 'accepts <text> as <value>' -ForEach @(
        @{ text = '0';        value = 0 }
        @{ text = '-3.25';    value = -3.25 }
        @{ text = '  7.5  ';  value = 7.5 }      # NumberStyles::Float allows surrounding white
        @{ text = '1e3';      value = 1000 }
        @{ text = '30.00';    value = 30 }       # what a NumericUpDown reads back
        @{ text = '+4';       value = 4 }
    ) {
        $r = ConvertTo-SwdNumber -Text $text
        $r.Ok | Should -BeTrue
        $r.Value | Should -Be $value
    }

    It 'reports Ok=$false for <label> rather than throwing or guessing' -ForEach @(
        @{ label = 'letters';     text = 'abc' }
        @{ label = 'empty';       text = '' }
        @{ label = 'null';        text = $null }
        @{ label = 'units';       text = '10 km/h' }
        @{ label = 'two numbers'; text = '1 2' }
        @{ label = 'thousands';   text = '1,000' }   # Float excludes AllowThousands, by design
        @{ label = 'hex';         text = '0x1F' }
    ) {
        $r = ConvertTo-SwdNumber -Text $text
        $r.Ok | Should -BeFalse
        $r.Value | Should -BeNullOrEmpty
        $r.Culture | Should -BeNullOrEmpty
    }

    Context 'under a French UI culture - the W10 regression' {
        # SQA W10 measured the FIRST DRAFT under fr-FR: TryParse('10.5') was
        # False while [double]'10.5' was 10.5, and TryParse('10,5') was 10.5
        # while [double]'10,5' was *105*. Two cultures on the two sides of one
        # equality. SWD is French in origin, so this is not hypothetical.
        It 'reads both 10.5 and 10,5 as ten-and-a-half, and never as 105' {
            $prev = [Threading.Thread]::CurrentThread.CurrentCulture
            try {
                [Threading.Thread]::CurrentThread.CurrentCulture = [Globalization.CultureInfo]::GetCultureInfo('fr-FR')

                $dot = ConvertTo-SwdNumber -Text '10.5'
                $dot.Ok | Should -BeTrue
                $dot.Value | Should -Be 10.5
                $dot.Culture | Should -Be 'Invariant'

                $comma = ConvertTo-SwdNumber -Text '10,5'
                $comma.Ok | Should -BeTrue
                $comma.Value | Should -Be 10.5
                $comma.Value | Should -Not -Be 105
                $comma.Culture | Should -Be 'fr-FR'
            } finally {
                [Threading.Thread]::CurrentThread.CurrentCulture = $prev
            }
        }
    }
}

Describe 'Format-Integrity' {
    It 'renders an unreadable token as the finding it is, not as a blank' {
        # $null means OpenProcessToken failed, which from a Medium caller IS the
        # answer. It must never render as empty or as a level.
        Format-Integrity $null | Should -Be 'UNREADABLE (token access denied)'
    }

    It 'names <sid> as <levelName>' -ForEach @(
        @{ sid = 'S-1-16-4096';  levelName = 'Low' }
        @{ sid = 'S-1-16-8192';  levelName = 'Medium' }
        @{ sid = 'S-1-16-8448';  levelName = 'Medium Plus' }
        @{ sid = 'S-1-16-12288'; levelName = 'High' }
        @{ sid = 'S-1-16-16384'; levelName = 'System' }
    ) {
        $out = Format-Integrity $sid
        $out | Should -BeLike "$levelName*"
        # .Contains, NOT -BeLike "*[$sid]*": in a wildcard pattern '[' and ']'
        # open a CHARACTER CLASS, so that reads as "any one of S - 1 6 8 9 2"
        # rather than as the literal bracketed SID. It is not the test it looks
        # like, and it failed for a reason that had nothing to do with the code.
        $out.Contains("[$sid]") | Should -BeTrue
    }

    It 'passes an unknown SID through verbatim instead of inventing a level' {
        Format-Integrity 'S-1-16-99999' | Should -Be 'S-1-16-99999'
    }

    It 'agrees with the live token query for this process' {
        $sid = [SwdWin]::IntegritySid($PID)
        $sid | Should -Not -BeNullOrEmpty     # a process can always open its own token
        (Format-Integrity $sid).Contains("[$sid]") | Should -BeTrue
    }
}

Describe 'ConvertTo-SwdSafeText' {
    # NB: the -ForEach key is 'text', never 'input'. $input is an AUTOMATIC
    # variable (the pipeline enumerator), so a -ForEach key of that name is
    # overwritten before the body runs and every case in the block fails for a
    # reason that looks nothing like the real one.
    It 'escapes <label> so it cannot forge a log line' -ForEach @(
        @{ label = 'CRLF';      text = "cap`r`n=== FAKE ===";  expect = 'cap\r\n=== FAKE ===' }
        @{ label = 'bare LF';   text = "a`nb";                 expect = 'a\nb' }
        @{ label = 'bare CR';   text = "a`rb";                 expect = 'a\rb' }
        @{ label = 'TAB';       text = "a`tb";                 expect = 'a\tb' }
    ) { ConvertTo-SwdSafeText $text | Should -BeExactly $expect }

    It 'escapes control character U+<hex>' -ForEach @(
        @{ hex = '0000'; code = 0x00 }, @{ hex = '0007'; code = 0x07 }
        @{ hex = '001B'; code = 0x1B }, @{ hex = '007F'; code = 0x7F }
        @{ hex = '0085'; code = 0x85 }, @{ hex = '009F'; code = 0x9F }
        @{ hex = '2028'; code = 0x2028 }, @{ hex = '2029'; code = 0x2029 }
    ) {
        # Parenthesised: without them PowerShell binds the '+' and the 'b' as
        # further arguments to Should, and the whole block fails on parameter
        # binding rather than on the assertion.
        ConvertTo-SwdSafeText ('a' + [char]$code + 'b') | Should -BeExactly ('a\u' + $hex + 'b')
    }

    # Fixture diversity: every script and dash/quote/space form this log could
    # plausibly carry. SWD is French in origin and the field names in the data
    # layer already contain accents, so "ASCII only" is not a safe assumption.
    It 'leaves printable <label> completely untouched' -ForEach @(
        @{ label = 'ASCII';          text = 'Reset outline' }
        @{ label = 'French accents'; text = "$([char]0xE9)l$([char]0xE9)ment hydrodynamique" }
        @{ label = 'c-cedilla';      text = "tra$([char]0xE7)age" }
        @{ label = 'ASCII hyphen';   text = 'a-b' }
        @{ label = 'en dash';        text = "a$([char]0x2013)b" }
        @{ label = 'em dash';        text = "a$([char]0x2014)b" }
        @{ label = 'curly quotes';   text = "$([char]0x201C)q$([char]0x201D)" }
        @{ label = 'apostrophe';     text = "$([char]0x2019)" }
        @{ label = 'NBSP';           text = "a$([char]0xA0)b" }
        @{ label = 'CJK';            text = "$([char]0x6D41)$([char]0x4F53)" }
        @{ label = 'Hebrew RTL';     text = "$([char]0x05D0)$([char]0x05D1)" }
        @{ label = 'surrogate pair'; text = "$([char]0xD83C)$([char]0xDF0A)" }
        @{ label = 'degree/micro';   text = "20$([char]0xB0) 5$([char]0xB5)m" }
    ) { ConvertTo-SwdSafeText $text | Should -BeExactly $text }

    It 'never cuts between the halves of a surrogate pair' {
        # ROUND 2 mutation study, survivor U1 - and a gap that predates this
        # round. The suite had a surrogate-pair fixture, but it ran at the
        # default MaxLength of 300, so no cut ever happened and the branch that
        # keeps a pair atomic was never reached. Deleting that branch passed the
        # whole suite. It only shows when the boundary lands BETWEEN the halves,
        # so the boundary is swept across it.
        $pair = "$([char]0xD83C)$([char]0xDF0A)"
        foreach ($len in 8, 9, 10, 11, 12) {
            $r = ConvertTo-SwdSafeText ('a' * 9 + $pair + 'zzz') $len
            $i = 0
            while ($i -lt $r.Length) {
                if ([char]::IsHighSurrogate($r[$i])) {
                    ($i + 1) | Should -BeLessThan $r.Length -Because "a high surrogate at MaxLength=$len must not end the string"
                    [char]::IsLowSurrogate($r[$i + 1]) | Should -BeTrue -Because "MaxLength=$len must not split the pair"
                    $i += 2
                } else {
                    [char]::IsLowSurrogate($r[$i]) | Should -BeFalse -Because "MaxLength=$len produced an orphan low surrogate"
                    $i++
                }
            }
        }
    }

    It 'renders $null as <null>, distinct from an empty caption' {
        # C6 in miniature: a timed-out WM_GETTEXT is $null and an empty caption
        # is ''. Rendering both as nothing is how a hung read became a fact.
        ConvertTo-SwdSafeText $null | Should -BeExactly '<null>'
        ConvertTo-SwdSafeText ''    | Should -BeExactly ''
        ConvertTo-SwdSafeText $null | Should -Not -Be (ConvertTo-SwdSafeText '')
    }

    # Angle brackets are Pester's -ForEach name-template syntax, so a title
    # containing <CUT> is expanded as the variable $CUT and the test dies
    # before it asserts anything.
    It 'marks a shortened line with the CUT marker, not the class-truncation one' {
        # <TRUNCATED> means GetClassName ran out of buffer. Two different facts
        # must not share one marker.
        $out = ConvertTo-SwdSafeText ('x' * 400) -MaxLength 20
        $out | Should -BeExactly (('x' * 20) + '<CUT>')
        $out | Should -Not -BeLike '*<TRUNCATED>*'
    }

    It 'treats MaxLength 0 as no limit' {
        $long = 'y' * 1000
        ConvertTo-SwdSafeText $long -MaxLength 0 | Should -BeExactly $long
    }

    It 'cuts on an escape boundary, never inside one' {
        # This test used to assert 'abc\<CUT>' - a DANGLING BACKSLASH - under a
        # title saying that must not happen. The title was right and the code was
        # wrong: '\n' is two characters, 3 + 2 exceeds 4, so the whole unit is
        # dropped rather than half-written.
        ConvertTo-SwdSafeText "abc`ndef" -MaxLength 4 | Should -BeExactly 'abc<CUT>'
        ConvertTo-SwdSafeText "abc`ndef" -MaxLength 5 | Should -BeExactly 'abc\n<CUT>'
    }

    It 'never ends a cut line with an incomplete escape, at any cut point' {
        # Exhaustive over every boundary of a string made entirely of multi-char
        # escapes. A survivor here is a forged log line waiting to happen.
        $src = "a`tb`nc" + [char]0x85 + 'd'
        foreach ($n in 1..24) {
            $out = ConvertTo-SwdSafeText $src -MaxLength $n
            # EndsWith/Substring rather than -replace: the pattern is a literal,
            # but InjectionHunter flags dynamic-looking escaping and a rule you
            # re-explain every pass costs more than one line of plain code.
            $body = if ($out.EndsWith('<CUT>')) { $out.Substring(0, $out.Length - 5) } else { $out }
            # every backslash in the body must open a COMPLETE unit
            $body | Should -Not -Match '\\$'
            $body | Should -Not -Match '\\u[0-9A-F]{0,3}$'
        }
    }

    It 'doubles a literal backslash so the encoding is reversible' {
        ConvertTo-SwdSafeText 'a\b'   | Should -BeExactly 'a\\b'
        ConvertTo-SwdSafeText 'C:\x'  | Should -BeExactly 'C:\\x'
        # and a real newline is still distinguishable from the two characters
        # backslash-n that a caption might legitimately contain
        ConvertTo-SwdSafeText "a`nb"  | Should -BeExactly 'a\nb'
        ConvertTo-SwdSafeText 'a\nb'  | Should -BeExactly 'a\\nb'
        (ConvertTo-SwdSafeText "a`nb") | Should -Not -BeExactly (ConvertTo-SwdSafeText 'a\nb')
    }
}

Describe 'ConvertTo-SwdCsvCell' {
    It 'neutralises a cell beginning with <label>' -ForEach @(
        @{ label = 'equals';   text = '=1+1' }
        @{ label = 'plus';     text = '+1' }
        @{ label = 'minus';    text = '-1+cmd' }
        @{ label = 'at';       text = '@SUM(A1)' }
        @{ label = 'tab';      text = "`tlead" }
        @{ label = 'CR';       text = "`rlead" }
        @{ label = 'LF';       text = "`nlead" }
        @{ label = 'DDE';      text = '=cmd|'' /C calc''!A0' }
    ) {
        $out = ConvertTo-SwdCsvCell $text
        $out | Should -BeExactly ("'" + $text)
    }

    It 'leaves <label> alone' -ForEach @(
        @{ label = 'plain word';   text = 'Reset outline' }
        @{ label = 'inner equals'; text = 'a=b' }
        @{ label = 'digits';       text = '12.50' }
        @{ label = 'empty';        text = '' }
        @{ label = 'accented';     text = "$([char]0xE9)tat" }
        @{ label = 'inner minus';  text = 'a-b' }
    ) { ConvertTo-SwdCsvCell $text | Should -BeExactly $text }

    It 'returns $null unchanged so a timed-out read is not turned into text' {
        ConvertTo-SwdCsvCell $null | Should -BeNullOrEmpty
    }

    It 'survives a caption that genuinely begins with an apostrophe' {
        # A reader is told to strip ONE leading apostrophe. Without doubling,
        # "'Reset" came back as "Reset" - escaping that is not reversible is data
        # loss dressed as safety.
        $out = ConvertTo-SwdCsvCell "'Reset outline"
        $out | Should -BeExactly "''Reset outline"
        $out.Substring(1) | Should -BeExactly "'Reset outline"   # strip one, get the original
    }

    It 'prefixes exactly one apostrophe, so a reader strips exactly one' {
        (ConvertTo-SwdCsvCell '=x').Substring(0, 2) | Should -BeExactly "'="
        (ConvertTo-SwdCsvCell '=x') | Should -BeExactly "'=x"
    }
}

Describe 'ConvertTo-SwdWin32Path' {
    # ROUND 2 mutation study, survivor U6. This pure function had NO direct test:
    # it was only ever exercised through Test-SwdWritableTarget, where the
    # canonical-resolution arm independently refuses the same paths - so
    # deleting the trailing-space strip changed no observable outcome anywhere in
    # the suite. A shared helper needs its own test, or its callers' redundancy
    # hides it.
    It 'strips what Win32 strips at create time - <label>' -ForEach @(
        # NOT named 'input': $input is a PowerShell automatic variable, so a
        # -ForEach key of that name arrives EMPTY and every case then fails
        # for a reason unrelated to the code under test.
        @{ label = 'trailing space on a directory'; src   = 'C:\a\sub \x';    expect = 'C:\a\sub\x' }
        @{ label = 'trailing dot on a directory';   src   = 'C:\a\sub.\x';    expect = 'C:\a\sub\x' }
        @{ label = 'mixed and repeated';            src   = 'C:\a\sub. . \x'; expect = 'C:\a\sub\x' }
        @{ label = 'trailing space on the leaf';    src   = 'C:\a\leaf ';     expect = 'C:\a\leaf' }
        @{ label = 'nothing to strip';              src   = 'C:\a\b';         expect = 'C:\a\b' }
        @{ label = 'forward slashes normalised';    src   = 'C:/a/sub /x';    expect = 'C:\a\sub\x' }
    ) {
        # Measured: New-Item for 'sub ' produces 'sub'. Without this, the string
        # the guard compares is not the string the filesystem will use, and
        # 'ShaperWaveDynamics \x' compares as a different folder from the real one.
        ConvertTo-SwdWin32Path $src | Should -BeExactly $expect
    }

    It 'leaves the drive component alone' {
        # The loop starts at index 1 deliberately - 'C:' must keep its colon.
        ConvertTo-SwdWin32Path 'C:\x' | Should -BeExactly 'C:\x'
    }
}

Describe 'Test-SwdWritableTarget' {
    BeforeAll {
        $script:Docs = [Environment]::GetFolderPath('MyDocuments')
        $script:PF   = $env:ProgramFiles
    }

    It 'permits an ordinary target: <label>' -ForEach @(
        @{ label = 'the repo logs dir'; make = { Join-Path (Split-Path -Parent $PSScriptRoot) 'logs' } }
        @{ label = 'a temp path';       make = { 'C:\Temp\swd\does\not\exist\yet' } }
        @{ label = 'prefix collision';  make = { Join-Path $env:ProgramFiles 'ShaperWaveDynamicsOther' } }
        @{ label = 'a relative path';   make = { 'logs' } }
    ) { Test-SwdWritableTarget -Path (& $make) -WarningAction SilentlyContinue | Should -BeTrue }

    It 'refuses the SWD install: <label>' -ForEach @(
        @{ label = 'exact';          suffix = '' }
        @{ label = 'child';          suffix = '\evil' }
        @{ label = 'deep child';     suffix = '\a\b\c' }
        @{ label = 'trailing slash'; suffix = '\' }
    ) {
        Test-SwdWritableTarget -Path ((Join-Path $env:ProgramFiles 'ShaperWaveDynamics') + $suffix) `
            -WarningAction SilentlyContinue | Should -BeFalse
    }

    It 'refuses the SWD library where Windows actually puts Documents' {
        # THE HOLE THAT WAS REAL. The previous guard hard-coded
        # $env:USERPROFILE\Documents; on a machine with redirected Documents
        # that path does not exist and the library sits somewhere else entirely,
        # so the guard returned $true for the one directory CLAUDE.md section 4
        # says never to write into.
        $lib = Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'ShaperWaveDynamics documents'
        Test-SwdWritableTarget -Path $lib -WarningAction SilentlyContinue | Should -BeFalse
        Test-SwdWritableTarget -Path (Join-Path $lib 'biblio') -WarningAction SilentlyContinue | Should -BeFalse
    }

    It 'protects the library through GetFolderPath even with every OneDrive variable unset' {
        # The test above passes on THIS machine even if GetFolderPath is removed
        # from the guard, because $env:OneDrive happens to name the same tree -
        # a mutant proved exactly that survived. Clearing the OneDrive variables
        # isolates the mechanism, so the known-folder lookup has to carry the
        # test on its own. Somewhere with Folder Redirection to a network share
        # and no OneDrive, it is the ONLY thing that would.
        $saved = @{}
        foreach ($v in 'OneDrive', 'OneDriveCommercial', 'OneDriveConsumer') {
            $saved[$v] = [Environment]::GetEnvironmentVariable($v)
            Set-Item -Path "env:$v" -Value '' -ErrorAction SilentlyContinue
        }
        try {
            $lib = Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'ShaperWaveDynamics documents\biblio'
            Test-SwdWritableTarget -Path $lib -WarningAction SilentlyContinue | Should -BeFalse
        } finally {
            foreach ($v in $saved.Keys) {
                if ($null -eq $saved[$v]) { Remove-Item -Path "env:$v" -ErrorAction SilentlyContinue }
                else { Set-Item -Path "env:$v" -Value $saved[$v] }
            }
        }
    }

    It 'refuses the SWD library under the OneDrive root spelling too' -Skip:(-not $env:OneDrive) {
        $lib = Join-Path $env:OneDrive 'Documents\ShaperWaveDynamics documents\biblio'
        Test-SwdWritableTarget -Path $lib -WarningAction SilentlyContinue | Should -BeFalse
    }

    It 'normalises <label> before deciding' -ForEach @(
        @{ label = 'dot-dot within';    make = { Join-Path $env:ProgramFiles 'ShaperWaveDynamics\deep\..\x' } }
        @{ label = 'dot-dot from afar'; make = {
              # Built by joining and then SELF-CHECKED below, never by counting
              # '..' by eye. Counting produced a wrong fixture twice during this
              # review - once convincingly enough that the miscount was almost
              # written up as a proven guard bypass. The assertion under the
              # -ForEach block is what makes this fixture trustworthy.
              $depth = ($env:ProgramFiles.TrimEnd('\') -split '\\').Length
              Join-Path $env:ProgramFiles (('..\' * $depth) + 'Program Files\ShaperWaveDynamics\x') } }
        @{ label = 'single dots';       make = { 'C:\Program Files\.\ShaperWaveDynamics\.\x' } }
        @{ label = 'forward slashes';   make = { 'C:/Program Files/ShaperWaveDynamics/x' } }
        @{ label = 'upper case';        make = { 'C:\PROGRAM FILES\SHAPERWAVEDYNAMICS\x' } }
        @{ label = 'mixed separators';  make = { 'C:\Program Files/ShaperWaveDynamics\x' } }
        @{ label = '8.3 short name';    make = { 'C:\PROGRA~1\ShaperWaveDynamics\x' } }
    ) {
        $p = & $make
        # Self-check: unless the fixture really resolves inside the install, a
        # $false verdict proves nothing about the guard.
        [IO.Path]::GetFullPath($p).TrimEnd('\') |
            Should -BeLike ((Join-Path $env:ProgramFiles 'ShaperWaveDynamics') + '*')
        Test-SwdWritableTarget -Path $p -WarningAction SilentlyContinue | Should -BeFalse
    }

    It 'refuses <label>, which resolves into a protected folder by another spelling' -ForEach @(
        @{ label = 'a tilde-spelled library path';  kind = 'tilde-lib' }
        @{ label = 'a tilde-spelled install path';  kind = 'tilde-inst' }
        @{ label = 'an extended-length prefix';     kind = 'extlen' }
        @{ label = 'a device-namespace prefix';     kind = 'device' }
        @{ label = 'a UNC admin share';             kind = 'unc' }
        @{ label = 'a forward-slash UNC share';     kind = 'unc-fwd' }
        @{ label = 'a UNC path behind an extended-length prefix'; kind = 'unc-extlen' }
        @{ label = 'a trailing-space component';    kind = 'space' }
        @{ label = 'a trailing-dot component';      kind = 'dot' }
    ) {
        # ROUND 2, W1. Every one of these passed the previous guard and still
        # landed inside a protected folder, because the guard normalised with
        # [IO.Path] while New-Item -Path resolves through the PowerShell PROVIDER
        # and Win32 strips trailing spaces and dots at create time. Measured:
        # asking for 'sub ' in a temp folder produced 'sub'.
        $inst = Join-Path $env:ProgramFiles 'ShaperWaveDynamics'
        $docs = [Environment]::GetFolderPath('MyDocuments')
        $p = switch ($kind) {
            'tilde-lib'  { '~\' + $docs.Substring($env:USERPROFILE.Length).TrimStart('\') + '\ShaperWaveDynamics documents\biblio' }
            'tilde-inst' { '~\..\..\Program Files\ShaperWaveDynamics\x' }
            'extlen'     { '\\?\' + $inst + '\x' }
            'device'     { '\\.\' + $inst + '\x' }
            'unc'        { '\\localhost\c$\Program Files\ShaperWaveDynamics\x' }
            # NOT redundant with the backslash form. Measured: with the leading
            # guard disabled, this is the ONE spelling the post-resolution check
            # misses, so it is the only case that proves that guard is
            # load-bearing. A mutation survivor stood until this line existed.
            'unc-fwd'    { '//localhost/c$/Program Files/ShaperWaveDynamics/x' }
            'unc-extlen' { '\\?\UNC\localhost\c$\Program Files\ShaperWaveDynamics\x' }
            'space'      { $inst + ' \x' }
            'dot'        { $inst + '.\x' }
        }
        Test-SwdWritableTarget -Path $p -WarningAction SilentlyContinue | Should -BeFalse
        Resolve-SwdWritableTarget -Path $p -WarningAction SilentlyContinue | Should -BeNullOrEmpty
    }

    It 'hands back THE path the writer must use, not merely a yes' {
        # The structural half of W1: a boolean cannot stop a caller resolving the
        # string a second, different way. Callers write to what this returns.
        $out = Resolve-SwdWritableTarget -Path 'logs' -WarningAction SilentlyContinue
        $out | Should -Not -BeNullOrEmpty
        [IO.Path]::IsPathRooted($out) | Should -BeTrue
        $out | Should -Be ([IO.Path]::GetFullPath($out))
        # and it agrees with the provider, which is what New-Item -Path uses
        $out | Should -Be ($ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($out))
    }

    It 'refuses an empty or whitespace path rather than resolving it to the CWD' -ForEach @(
        @{ p = '' }, @{ p = '   ' }
    ) { Test-SwdWritableTarget -Path $p -WarningAction SilentlyContinue | Should -BeFalse }

    Context 'canonical containment - 8.3, junctions and subst' {
        BeforeAll {
            # The REAL short names, asked of Windows rather than guessed. The
            # round-2 fixture spelled 8.3 in the FIRST component only
            # ('C:\PROGRA~1\ShaperWaveDynamics\x'), which its own self-check
            # tolerated because GetFullPath does expand that one - so it never
            # exercised the protected directory's OWN component and the Critical
            # sat under a green suite.
            Add-Type -Namespace SwdTest -Name Short -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("kernel32.dll", CharSet = System.Runtime.InteropServices.CharSet.Unicode)]
public static extern uint GetShortPathNameW(string lpszLongPath, System.Text.StringBuilder lpszShortPath, uint cchBuffer);
'@
            function Get-ShortName {
                param([string]$Path)
                $sb = New-Object System.Text.StringBuilder 512
                if ([SwdTest.Short]::GetShortPathNameW($Path, $sb, 512) -eq 0) { return $null }
                $sb.ToString()
            }
            $script:Install = Join-Path $env:ProgramFiles 'ShaperWaveDynamics'
            $script:Library = Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'ShaperWaveDynamics documents'
            $script:InstallShort = if (Test-Path -LiteralPath $script:Install) { Get-ShortName $script:Install } else { $null }
            $script:LibraryShort = if (Test-Path -LiteralPath $script:Library) { Get-ShortName $script:Library } else { $null }
        }

        It 'refuses the INSTALL spelled 8.3 in its own component' -Skip:(-not (Test-Path -LiteralPath (Join-Path $env:ProgramFiles 'ShaperWaveDynamics'))) {
            $script:InstallShort | Should -Not -BeNullOrEmpty
            # self-check: the fixture must really name the install, and must
            # differ from the long form in the PROTECTED component
            (Split-Path $script:InstallShort -Leaf) | Should -Not -Be (Split-Path $script:Install -Leaf)
            foreach ($p in @($script:InstallShort, (Join-Path $script:InstallShort 'logs'),
                             (Join-Path (Split-Path $script:Install -Parent) ((Split-Path $script:InstallShort -Leaf) + '\logs')))) {
                Resolve-SwdWritableTarget -Path $p -WarningAction SilentlyContinue | Should -BeNullOrEmpty
                Test-SwdWritableTarget -Path $p -WarningAction SilentlyContinue | Should -BeFalse
            }
        }

        It 'refuses the LIBRARY spelled 8.3 in its own component' -Skip:(-not (Test-Path -LiteralPath (Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'ShaperWaveDynamics documents'))) {
            $script:LibraryShort | Should -Not -BeNullOrEmpty
            (Split-Path $script:LibraryShort -Leaf) | Should -Not -Be (Split-Path $script:Library -Leaf)
            foreach ($p in @($script:LibraryShort, (Join-Path $script:LibraryShort 'biblio'))) {
                Resolve-SwdWritableTarget -Path $p -WarningAction SilentlyContinue | Should -BeNullOrEmpty
            }
        }

        It 'refuses a junction that points into the install' -Skip:(-not (Test-Path -LiteralPath (Join-Path $env:ProgramFiles 'ShaperWaveDynamics'))) {
            $j = Join-Path $TestDrive 'junc'
            & cmd.exe /c mklink /J "$j" "$script:Install" 2>&1 | Out-Null
            if (-not (Test-Path -LiteralPath $j)) { Set-ItResult -Skipped -Because 'mklink /J was refused'; return }
            try {
                Resolve-SwdWritableTarget -Path $j -WarningAction SilentlyContinue | Should -BeNullOrEmpty
                Resolve-SwdWritableTarget -Path (Join-Path $j 'logs') -WarningAction SilentlyContinue | Should -BeNullOrEmpty
            } finally { & cmd.exe /c rmdir "$j" 2>&1 | Out-Null }
        }

        It 'returns a CANONICAL path for a permitted target, so no caller re-resolves it' {
            $out = Resolve-SwdWritableTarget -Path $TestDrive -WarningAction SilentlyContinue
            $out | Should -Not -BeNullOrEmpty
            # canonical means: already fully expanded, so canonicalising again is a no-op
            Resolve-SwdCanonicalTarget -Path $out | Should -Be $out
            $out | Should -Not -Match '~\d'
        }

        It 'returns the LONG form when handed an allowed path spelled 8.3' {
            # This is what makes the returned string load-bearing rather than
            # decorative: a mutant that returned the LEXICAL path survived until
            # this fixture was right, and getting it right took two attempts.
            #
            # The trap: GetUnresolvedProviderPathFromPSPath expands 8.3
            # INCONSISTENTLY. Under Pester's own $TestDrive it expanded the whole
            # thing, so lexical and canonical agreed and the mutant looked
            # equivalent. Measured, the shape that reliably does NOT expand is a
            # short-named directory under %TEMP% with a tail that does not exist -
            # which is also the real-world shape, since a log directory is created
            # rather than found.
            $long = Join-Path $env:TEMP ('swd canonical fixture ' + [guid]::NewGuid().ToString('N').Substring(0, 8))
            [void][IO.Directory]::CreateDirectory($long)
            try {
                $short = Get-ShortName $long
                if (-not $short -or $short -eq $long) { Set-ItResult -Skipped -Because '8.3 generation is disabled on this volume'; return }
                $shortTail = Join-Path $short 'logs'
                $longTail  = Join-Path $long  'logs'

                # self-check: the fixture is only meaningful while the lexical
                # resolver leaves the 8.3 name in place
                $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($shortTail) |
                    Should -Not -Be $longTail -Because 'otherwise lexical and canonical agree and this proves nothing'

                $out = Resolve-SwdWritableTarget -Path $shortTail -WarningAction SilentlyContinue
                $out | Should -Be $longTail
                $out | Should -Not -BeLike '*~1*'   # -BeLike, not -Match: a literal pattern that InjectionHunter flags costs more to re-explain than to avoid
                Test-Path -LiteralPath $longTail | Should -BeFalse   # still created nothing
            } finally { Remove-Item -LiteralPath $long -Recurse -Force -ErrorAction SilentlyContinue }
        }

        It 'canonicalises a target whose leaf does not exist yet, WITHOUT creating it' {
            $missing = Join-Path $TestDrive 'not-made-yet\deeper'
            $out = Resolve-SwdWritableTarget -Path $missing -WarningAction SilentlyContinue
            $out | Should -Not -BeNullOrEmpty
            Test-Path -LiteralPath $missing | Should -BeFalse    # nothing was created
            Test-Path -LiteralPath (Join-Path $TestDrive 'not-made-yet') | Should -BeFalse
        }
    }
}

Describe 'Test-SwdHandle' {
    It 'refuses handle 0 without asking the process table' {
        # The title promises the process table is not consulted and the old body
        # only checked the return value, so the "without asking" half was never
        # tested. Get-SwdProcess is a whole-table scan (measured 17.17 ms), and
        # the early return is the reason it is skipped.
        Mock Get-SwdProcess { throw 'Get-SwdProcess must not be reached for handle 0' }
        Test-SwdHandle -Handle 0 | Should -BeFalse
        Should -Invoke Get-SwdProcess -Times 0 -Exactly
    }

    It 'refuses a handle that is not a window' {
        Test-SwdHandle -Handle 1 | Should -BeFalse
        Test-SwdHandle -Handle 123456789 | Should -BeFalse
    }

    It 'accepts a live window owned by the process Get-SwdProcess names' {
        Mock Get-SwdProcess { [pscustomobject]@{ Id = $PID; MainWindowHandle = $script:OwnHwnd } }
        Test-SwdHandle -Handle $script:BtnHwnd | Should -BeTrue
    }

    It 'refuses a live window owned by a DIFFERENT process' {
        # The map itself could contain a foreign window - that was C5. Ownership
        # is re-checked at the handle, not trusted from the map.
        Mock Get-SwdProcess { [pscustomobject]@{ Id = ($PID + 1); MainWindowHandle = $script:OwnHwnd } }
        Test-SwdHandle -Handle $script:BtnHwnd | Should -BeFalse
    }

    It 'refuses everything when SWD is not running, without throwing' {
        Mock Get-SwdProcess { throw 'SurfHydrodynamics is not running.' }
        Test-SwdHandle -Handle $script:BtnHwnd | Should -BeFalse
    }
}

Describe 'SwdWin native layer' {
    It 'refuses a NULL parent instead of enumerating the whole desktop' {
        # C5: measured, EnumChildWindows(NULL) returned 479 windows belonging to
        # other processes, which then became legitimate-looking BM_CLICK targets.
        { [SwdWin]::Children([intptr]::Zero) } | Should -Throw '*NULL parent*'
    }

    It 'enumerates the children of a real window into 7-field records' {
        $rows = [SwdWin]::Children([intptr]$script:OwnHwnd)
        $rows.Count | Should -BeGreaterThan 0
        foreach ($r in $rows) {
            ($r -split ([regex]::Escape([SwdWin]::SEP))).Count | Should -Be 7
            { ConvertFrom-SwdControlRecord -Line $r } | Should -Not -Throw
        }
    }

    It 'returns $null for a dead handle and a string for a live one' {
        # C6: $null (no answer) must never be silently equal to '' (empty text).
        [SwdWin]::GetText([intptr]1, 200) | Should -BeNullOrEmpty
        $null -eq [SwdWin]::GetText([intptr]1, 200) | Should -BeTrue

        $live = [SwdWin]::GetText([intptr]$script:BtnHwnd, 2000)
        $null -eq $live | Should -BeFalse
        $live | Should -Be 'probe'
    }

    It 'exposes the field count the parser asserts against' {
        [SwdWin]::FIELDS | Should -Be 7
        [SwdWin]::SEP | Should -Be ([string][char]0x1F)
    }

    It 'refuses an over-long caption and says WHY, distinct from a timeout' {
        # Found by mutation testing: removing the length bound changed nothing
        # any test could see. Worse, the bound returned the same (null,
        # LastError 0) as a window that never answered - two different facts
        # sharing one signal, which is C6 in miniature.
        $big = New-Object System.Windows.Forms.TextBox
        $big.Multiline = $true
        $script:Form.Controls.Add($big)
        try {
            $big.Text = 'x' * ([SwdWin]::MAX_TEXT + 100)
            $out = [SwdWin]::GetText([intptr][int64]$big.Handle, 2000)
            $null -eq $out | Should -BeTrue
            [SwdWin]::LastError | Should -Be ([SwdWin]::ERR_TEXT_TOO_LONG)
            [SwdWin]::ERR_TEXT_TOO_LONG | Should -BeLessThan 0    # never collides with a Win32 error

            # and a caption just under the bound still reads back in full
            $big.Text = 'y' * 1000
            $ok = [SwdWin]::GetText([intptr][int64]$big.Handle, 2000)
            $ok.Length | Should -Be 1000
            [SwdWin]::LastError | Should -Be 0
        } finally {
            $script:Form.Controls.Remove($big)
            $big.Dispose()
        }
    }
}

Describe 'Get-SwdControlSummary' {
    It 'is readable before any enumeration has run, and reports zero' {
        # Read under StrictMode by swd_diagnose.ps1's Summary. An uninitialised
        # $script: variable would throw there instead of reporting nothing.
        $s = Get-SwdControlSummary
        $s | Should -Not -BeNullOrEmpty
        foreach ($f in 'Scope', 'Total', 'WithText', 'TimedOut', 'Skipped', 'DeadlineHit', 'NoText', 'ElapsedMs') {
            $s.PSObject.Properties.Name | Should -Contain $f
        }
        # Scope names WHAT was counted. Get-SwdDialogControl writes into this same
        # aggregate, so a summary that cannot say which enumeration it describes
        # is the W3 defect one level up.
        $s.Scope | Should -BeLike 'none*'
    }
}

Describe 'Compare-SwdMap' {
    BeforeAll {
        function Format-Row {
            param([int64]$Handle, [string]$Text = 'cap', [int64]$Parent = 900,
                  [bool]$TimedOut = $false, [bool]$Enabled = $true, [string]$Rect = '1,2,3,4')
            [pscustomobject]@{ Handle = $Handle; Class = 'WindowsForms10.BUTTON.app.0.x'; CtrlId = 1
                               Visible = $true; Enabled = $Enabled; Rect = $Rect; Parent = $Parent
                               Text = $Text; TimedOut = $TimedOut; Skipped = $false; LastError = 0 }
        }
    }

    # THE CARDINALITY TRAP. A returned collection that PowerShell unrolls gives a
    # bare object at n=1 (.Count throws) and a comma-wrapped one gives Count=1 at
    # n=3 - a SILENT UNDERCOUNT of the number the central experiment reports.
    # Both spellings were live during round 1.
    It 'reports <n> change(s) as <n>, at n=0, 1 and many' -ForEach @(
        @{ n = 0 }, @{ n = 1 }, @{ n = 3 }, @{ n = 7 }
    ) {
        $before = 1..10 | ForEach-Object { Format-Row -Handle $_ -Text "cap$_" }
        $after  = 1..10 | ForEach-Object {
            if ($_ -le $n) { Format-Row -Handle $_ -Text "CHANGED$_" } else { Format-Row -Handle $_ -Text "cap$_" } }
        $diff = @(Compare-SwdMap -Before $before -After $after)
        $diff.Count | Should -Be $n
        @($diff | Where-Object { $_.Kind -eq 'CHANGED' }).Count | Should -Be $n
    }

    It 'reports UNCOMPARABLE, never CHANGED, when either side timed out' {
        # $null (no answer) versus '' (empty caption) is a real difference to
        # PowerShell and no difference at all as evidence.
        $before = @(Format-Row -Handle 1 -Text 'cap')
        $after  = @(Format-Row -Handle 1 -Text $null -TimedOut $true)
        $diff = @(Compare-SwdMap -Before $before -After $after)
        @($diff | Where-Object { $_.Field -eq 'Text' }).Kind | Should -Be 'UNCOMPARABLE'
        @($diff | Where-Object { $_.Kind -eq 'CHANGED' -and $_.Field -eq 'Text' }).Count | Should -Be 0

        # and the same in the other direction
        $diff2 = @(Compare-SwdMap -Before $after -After $before)
        @($diff2 | Where-Object { $_.Field -eq 'Text' }).Kind | Should -Be 'UNCOMPARABLE'
    }

    It 'detects a control that appeared or vanished' {
        $a = @(Compare-SwdMap -Before @(Format-Row -Handle 1) -After @((Format-Row -Handle 1), (Format-Row -Handle 2)))
        @($a | Where-Object { $_.Kind -eq 'APPEARED' }).Handle | Should -Be 2
        $v = @(Compare-SwdMap -Before @((Format-Row -Handle 1), (Format-Row -Handle 2)) -After @(Format-Row -Handle 1))
        @($v | Where-Object { $_.Kind -eq 'VANISHED' }).Handle | Should -Be 2
    }

    It 'flags OnTarget for the probe, its siblings and its children, and nothing else' {
        $before = @((Format-Row -Handle 10 -Parent 900), (Format-Row -Handle 11 -Parent 900),
                    (Format-Row -Handle 12 -Parent 10),  (Format-Row -Handle 13 -Parent 500))
        $after  = @((Format-Row -Handle 10 -Parent 900 -Text 'x'), (Format-Row -Handle 11 -Parent 900 -Text 'x'),
                    (Format-Row -Handle 12 -Parent 10 -Text 'x'),  (Format-Row -Handle 13 -Parent 500 -Text 'x'))
        $diff = @(Compare-SwdMap -Before $before -After $after -ProbeHandle 10 -ProbeParent 900)
        ($diff | Where-Object Handle -eq 10).OnTarget | Should -BeTrue    # the probe
        ($diff | Where-Object Handle -eq 11).OnTarget | Should -BeTrue    # a sibling
        ($diff | Where-Object Handle -eq 12).OnTarget | Should -BeTrue    # a child
        ($diff | Where-Object Handle -eq 13).OnTarget | Should -BeFalse   # unrelated
    }

    It 'notices Enabled and Rect changes, not only Text' {
        $d1 = @(Compare-SwdMap -Before @(Format-Row -Handle 1 -Enabled $true) -After @(Format-Row -Handle 1 -Enabled $false))
        $d1.Field | Should -Be 'Enabled'
        $d2 = @(Compare-SwdMap -Before @(Format-Row -Handle 1 -Rect '1,2,3,4') -After @(Format-Row -Handle 1 -Rect '9,9,9,9'))
        $d2.Field | Should -Be 'Rect'
    }
}

# ---------------------------------------------------------------------------
#  Cross-process block. Everything above runs against this process; the three
#  behaviours below CANNOT be tested in-process - measured 2026-08-27, BM_CLICK
#  on an unshown in-process button returns Sent=$true and never raises Click,
#  because nothing pumps the queue. So a throwaway WinForms host is launched,
#  parked off-screen, and killed in AfterAll. It is NOT SWD and never touches it.
# ---------------------------------------------------------------------------
Describe 'Live-control behaviour (throwaway cross-process WinForms target)' {
    BeforeAll {
        $targetPs = Join-Path $TestDrive 'target.ps1'
        $targetSrc = @(
            "Add-Type -AssemblyName System.Windows.Forms"
            "Add-Type -AssemblyName System.Drawing"
            "`$f = New-Object System.Windows.Forms.Form"
            "`$f.Text = 'SWDTESTS-TARGET'"
            "`$f.StartPosition = 'Manual'"
            "`$f.Location = New-Object System.Drawing.Point(-32000, -32000)"
            "`$b = New-Object System.Windows.Forms.Button"
            "`$b.Text = 'clicks 0'; `$b.Width = 160; `$f.Controls.Add(`$b)"
            "`$script:n = 0"
            "`$b.Add_Click({ `$script:n++; `$b.Text = `"clicks `$script:n`" })"
            "`$d = New-Object System.Windows.Forms.Button"
            "`$d.Text = 'disabled'; `$d.Enabled = `$false; `$d.Top = 40; `$f.Controls.Add(`$d)"
            "`$l = New-Object System.Windows.Forms.Label"
            "`$l.Text = 'plain label'; `$l.Top = 80; `$f.Controls.Add(`$l)"
            # Blocks this target's pump from inside its own handler, which is the
            # only way to make a WM_GETTEXT genuinely time out on demand.
            "`$sb2 = New-Object System.Windows.Forms.Button"
            "`$sb2.Text = 'SLOWCTL 0'; `$sb2.Width = 160; `$sb2.Top = 240; `$f.Controls.Add(`$sb2)"
            "`$script:sn = 0"
            "`$sb2.Add_Click({ [System.Threading.Thread]::Sleep(4000); `$script:sn++; `$sb2.Text = `"SLOWCTL `$script:sn`" })"
            "`$nud = New-Object System.Windows.Forms.NumericUpDown"
            "`$nud.Minimum = 0; `$nud.Maximum = 30; `$nud.DecimalPlaces = 2; `$nud.Value = 12.50"
            "`$nud.Top = 120; `$f.Controls.Add(`$nud)"
            # An order-recording control. Its WndProc appends every message this
            # layer sends into a log, and the log is published on a Label so the
            # parent can read it back with WM_GETTEXT. That is what makes MESSAGE
            # ORDERING directly assertable rather than inferred from documentation.
            "Add-Type -TypeDefinition @'"
            "using System;using System.Text;using System.Windows.Forms;"
            "public class OrderEdit : TextBox {"
            "  public static StringBuilder Log = new StringBuilder();"
            "  protected override void WndProc(ref Message m) {"
            "    switch ((uint)m.Msg) {"
            '      case 0x000C: Log.Append("SETTEXT;");   break;'
            '      case 0x000D: Log.Append("GETTEXT;");   break;'
            '      case 0x0100: Log.Append("KEYDOWN;");   break;'
            '      case 0x0101: Log.Append("KEYUP;");     break;'
            '      case 0x0008: Log.Append("KILLFOCUS;"); break;'
            "    }"
            "    base.WndProc(ref m);"
            "  }"
            "}"
            "'@ -ReferencedAssemblies System.Windows.Forms, System.Drawing"
            "`$oe = New-Object OrderEdit"
            "`$oe.Text = '12.50'; `$oe.Top = 160; `$f.Controls.Add(`$oe)"
            "`$ol = New-Object System.Windows.Forms.Label"
            "`$ol.Top = 200; `$ol.Width = 1200; `$ol.Text = 'ORDER:'; `$f.Controls.Add(`$ol)"
            "`$tm = New-Object System.Windows.Forms.Timer"
            "`$tm.Interval = 25"
            "`$tm.Add_Tick({ `$ol.Text = 'ORDER:' + [OrderEdit]::Log.ToString() })"
            "`$tm.Start()"
            "[System.Windows.Forms.Application]::Run(`$f)"
        )
        Set-Content -LiteralPath $targetPs -Value $targetSrc -Encoding ASCII

        # -WindowStyle Hidden goes to powershell.exe (hides its CONSOLE), never to
        # Start-Process: as a Start-Process parameter it sets SW_HIDE in the
        # STARTUPINFO, WinForms honours that for the first form, and the form is
        # then created invisible - so Process.MainWindowHandle, which only returns
        # VISIBLE top-level windows, stays 0 forever. Measured; it cost a fixture.
        # The form is parked off-screen instead. ShowInTaskbar = $false ALSO
        # forces MainWindowHandle to 0, so it is deliberately not set.
        $script:Target = Start-Process powershell.exe -PassThru -ArgumentList @(
            '-NoProfile', '-ExecutionPolicy', 'Bypass', '-STA', '-WindowStyle', 'Hidden', '-File', $targetPs)
        $script:TargetId = $script:Target.Id
        $mainH = 0
        for ($i = 0; $i -lt 80 -and $mainH -eq 0; $i++) {
            Start-Sleep -Milliseconds 250
            $mainH = (Get-Process -Id $script:TargetId -ErrorAction Stop).MainWindowHandle
        }
        if ($mainH -eq 0) { throw 'throwaway WinForms target never produced a visible window' }

        # THE SEAM. Every live-application function routes through Get-SwdProcess,
        # so redefining it here points the whole library at the throwaway target.
        # A later definition wins in the same scope; no SWD is involved anywhere.
        function Get-SwdProcess {
            $p = Get-Process -Id $script:TargetId -ErrorAction Stop
            if ($p.MainWindowHandle -eq 0) { throw 'target has no main window' }
            $p
        }

        $all = @(Get-SwdControl)
        $script:BtnH  = ($all | Where-Object { $_.Text -like 'clicks*' } | Select-Object -First 1).Handle
        $script:DisH  = ($all | Where-Object { $_.Text -eq 'disabled' } | Select-Object -First 1).Handle
        $script:LblH  = ($all | Where-Object { $_.Class -like '*STATIC*' } | Select-Object -First 1).Handle
        $script:EditH = ($all | Where-Object { $_.Class -like '*EDIT*' } | Select-Object -First 1).Handle
        # The order-recording EDIT is the SECOND *EDIT* on the form; the first
        # belongs to the NumericUpDown. Both are needed: the clamp tests drive
        # the NumericUpDown, the ordering test drives this one.
        $script:OrderH = @($all | Where-Object { $_.Class -like '*EDIT*' })[1].Handle
        $script:OrderLogH = ($all | Where-Object { $_.Text -like 'ORDER:*' } | Select-Object -First 1).Handle
        $script:SlowCtlH  = ($all | Where-Object { $_.Text -like 'SLOWCTL*' } | Select-Object -First 1).Handle
        foreach ($h in $script:BtnH, $script:DisH, $script:LblH, $script:EditH, $script:OrderH, $script:OrderLogH, $script:SlowCtlH) {
            if (-not $h) { throw 'could not locate every control on the throwaway target' }
        }
    }

    AfterAll {
        if ($script:Target) { Stop-Process -Id $script:Target.Id -Force -ErrorAction SilentlyContinue }
    }

    Context 'Invoke-SwdButton' {
        It 'has no Ok field, because BM_CLICK always returns zero' {
            # Reverting Sent -> Ok left round 1 fully green. This is the test that
            # would have caught it.
            $r = Invoke-SwdButton -Handle $script:BtnH
            $names = $r.PSObject.Properties.Name
            $names | Should -Not -Contain 'Ok'
            $names | Should -Contain 'Sent'
            $names | Should -Contain 'LastError'
            $r.Sent | Should -BeTrue
        }

        It 'actually operates the control it is pointed at' {
            $before = Get-SwdText -Handle $script:BtnH
            $null = Invoke-SwdButton -Handle $script:BtnH
            Start-Sleep -Milliseconds 300
            Get-SwdText -Handle $script:BtnH | Should -Not -Be $before
        }

        It 'refuses a <label> without -Force, and permits it with -Force' -ForEach @(
            @{ label = 'disabled control'; which = 'Dis'; expect = '*DISABLED*' }
            @{ label = 'non-BUTTON class'; which = 'Lbl'; expect = '*not a BUTTON*' }
        ) {
            $h = if ($which -eq 'Dis') { $script:DisH } else { $script:LblH }
            { Invoke-SwdButton -Handle $h } | Should -Throw $expect
            (Invoke-SwdButton -Handle $h -Force).Forced | Should -BeTrue
        }

        It 'DOES NOT CLICK during a -WhatIf rehearsal' {
            # The round-2 Critical. Both sibling mutators honour ShouldProcess and
            # this one did not, so a scan driver rehearsing a configuration
            # configured nothing and still pressed the application's buttons.
            $before = Get-SwdText -Handle $script:BtnH
            $r = Invoke-SwdButton -Handle $script:BtnH -WhatIf
            Start-Sleep -Milliseconds 300
            Get-SwdText -Handle $script:BtnH | Should -BeExactly $before
            $r.Sent | Should -BeFalse
            $r.WhatIf | Should -BeTrue
        }

        It 'DOES NOT CLICK when WhatIfPreference is inherited from a caller' {
            # A scan driver sets -WhatIf on itself and every advanced function it
            # calls inherits it. A simple function silently does not.
            $before = Get-SwdText -Handle $script:BtnH
            $WhatIfPreference = $true
            try { $r = Invoke-SwdButton -Handle $script:BtnH } finally { $WhatIfPreference = $false }
            Start-Sleep -Milliseconds 300
            Get-SwdText -Handle $script:BtnH | Should -BeExactly $before
            $r.Sent | Should -BeFalse
        }

        It 'distinguishes a QUEUED post from a HANDLED send' {
            # ROUND 2, C1. `Sent` answers "did the transport call succeed", and
            # that means two different things per transport: PostMessage returns
            # non-zero for putting a message on a queue and essentially cannot
            # fail against a live window, so Sent=$true there is a constant, not
            # evidence. Observed names what was actually seen.
            $s = Invoke-SwdButton -Handle $script:BtnH
            $s.Method   | Should -Be 'SendMessageTimeout'
            $s.Observed | Should -Be 'handled'
            $p = Invoke-SwdButton -Handle $script:BtnH -Post
            $p.Method   | Should -Be 'PostMessage'
            $p.Observed | Should -Be 'queued'
            $p.Sent     | Should -BeTrue   # and yet nothing was delivered
        }

        It 'every mutator honours an INHERITED $WhatIfPreference' {
            # S5 and W1 together. A scan driver declares SupportsShouldProcess and
            # is run with -WhatIf; every ADVANCED function it calls inherits the
            # preference and a SIMPLE one silently does not. Only two of the
            # mutators were covered, and the uncovered set is where
            # Save-SwdWindowImage was quietly writing PNGs and creating
            # directories during a rehearsal.
            $beforeEdit = Get-SwdText -Handle $script:EditH
            $beforeBtn  = Get-SwdText -Handle $script:BtnH
            $imgDir = Join-Path $TestDrive 'rehearsal-images'

            $WhatIfPreference = $true
            try {
                $n   = Set-SwdNumeric   -Handle $script:EditH -Value '9'
                $b   = Invoke-SwdButton -Handle $script:BtnH
                $f   = Set-SwdForeground -SettleMs 50
                $img = Save-SwdWindowImage -Name 'rehearsal' -Dir $imgDir
            } finally { $WhatIfPreference = $false }

            $n.WhatIf | Should -BeTrue
            $b.WhatIf | Should -BeTrue
            $f.WhatIf | Should -BeTrue
            $b.Sent   | Should -BeFalse
            $img      | Should -BeNullOrEmpty
            # nothing on disk, and nothing moved in the application
            Test-Path -LiteralPath $imgDir | Should -BeFalse
            Start-Sleep -Milliseconds 300
            Get-SwdText -Handle $script:EditH | Should -BeExactly $beforeEdit
            Get-SwdText -Handle $script:BtnH  | Should -BeExactly $beforeBtn
        }

        It 'Save-SwdWindowImage DOES write when it is not rehearsing' {
            # The other half: a guard that always refuses is not a guard.
            $d = Join-Path $TestDrive 'real-images'
            $out = Save-SwdWindowImage -Name 'real' -Dir $d
            $out | Should -Not -BeNullOrEmpty
            Test-Path -LiteralPath $out | Should -BeTrue
            (Get-Item -LiteralPath $out).Length | Should -BeGreaterThan 0
        }
    }

    Context 'Set-SwdForeground - W6, which had no Describe at all' {
        It 'reports the answer from Test-SwdOwnsForeground, pinned <pinned>' -ForEach @(
            @{ pinned = $true }, @{ pinned = $false }
        ) {
            # Hardcoding IsForeground=$true passed the whole suite, because
            # nothing anywhere called this function. The second limb is subtler:
            # it compared handle identity against MainWindowHandle, so activation
            # onto SWD's OWN MODAL read as failure - the exact defect
            # Test-SwdOwnsForeground was written to fix one level up, in the
            # diagnostic, and left standing here. Pinning the predicate proves
            # the result is the predicate's answer and not a handle comparison:
            # a handle-identity revert cannot return $true for a foreground
            # window that is not the main window.
            function Test-SwdOwnsForeground { param($Handle, $ProcessId) $pinned }
            $r = Set-SwdForeground -SettleMs 60 -Confirm:$false
            $r.IsForeground | Should -Be $pinned
        }

        It 'passes UNKNOWN through as $null rather than collapsing it to $false' {
            function Test-SwdOwnsForeground { param($Handle, $ProcessId) $null }
            $r = Set-SwdForeground -SettleMs 60 -Confirm:$false
            ($null -eq $r.IsForeground) | Should -BeTrue
            $r.IsForeground | Should -Not -Be $false
        }

        It 'reports what it MEASURED, consistent with the handle it reports' {
            # No pinning: the real predicate, and the two fields must agree.
            $r = Set-SwdForeground -SettleMs 200 -Confirm:$false
            $r.IsForeground | Should -Be (Test-SwdOwnsForeground -Handle $r.Foreground -ProcessId $script:TargetId)
            $r.SwdMain | Should -Be ([int64](Get-Process -Id $script:TargetId).MainWindowHandle)
        }

        It 'changes nothing and claims nothing during a -WhatIf rehearsal' {
            $fgBefore = [SwdWin]::GetForegroundWindow()
            $r = Set-SwdForeground -WhatIf
            $r.WhatIf | Should -BeTrue
            $r.Called | Should -BeFalse
            # NOT $false: nothing was attempted, so nothing was measured.
            ($null -eq $r.IsForeground) | Should -BeTrue
            [SwdWin]::GetForegroundWindow() | Should -Be $fgBefore
        }
    }

    Context 'Set-SwdNumeric' {
        It 'commits a value the control accepts' {
            $r = Set-SwdNumeric -Handle $script:EditH -Value '20.25'
            $r.Ok | Should -BeTrue
            $r.After | Should -Be '20.25'
        }

        It 'returns Ok=$false with the clamped value when the control rejects the request' {
            # W2's regression test. The settle poll used to exit on the echo of
            # its own WM_SETTEXT, so Ok could be true for a value the control
            # never took - 40 against a Maximum of 30.
            $r = Set-SwdNumeric -Handle $script:EditH -Value '40'
            $r.Ok | Should -BeFalse
            $r.After | Should -Be '30.00'
            $r.Reason | Should -BeLike '*did not take the value*'
        }

        It 'observes the control, not the write: After is what the control says' {
            $null = Set-SwdNumeric -Handle $script:EditH -Value '5'
            $r = Set-SwdNumeric -Handle $script:EditH -Value '40'
            $r.After | Should -Not -Be '40'          # never the echo of the request
            $r.After | Should -Be (Get-SwdText -Handle $script:EditH)
        }

        It 'sends nothing during a -WhatIf rehearsal' {
            $before = Get-SwdText -Handle $script:EditH
            $r = Set-SwdNumeric -Handle $script:EditH -Value '7' -WhatIf
            $r.WhatIf | Should -BeTrue
            $r.Ok | Should -BeFalse
            Get-SwdText -Handle $script:EditH | Should -BeExactly $before
        }

        It 'sends the commit keys BEFORE it reads back - asserted on the order the target recorded' {
            # ROUND 3, W1. The clamp test above does NOT bite this: the local
            # target validates inside the first poll interval, so it returns the
            # honest answer whether the commit keys were sent or posted. The
            # defect is an ORDERING one, so it is asserted on ordering.
            #
            # PostMessage only QUEUES. A thread sitting in GetMessage dispatches
            # SENT messages ahead of returning a POSTED one, so a posted commit
            # can still be in the queue when the sent WM_GETTEXT is serviced, and
            # the readback then observes the echo of the write rather than the
            # control. Reverting to PostMessage makes this test fail.
            $null = Set-SwdNumeric -Handle $script:OrderH -Value '20.25'
            Start-Sleep -Milliseconds 250
            $log = Get-SwdText -Handle $script:OrderLogH
            $log | Should -BeLike 'ORDER:*'
            $seq = @(($log -replace '^ORDER:', '').TrimEnd(';') -split ';' | Where-Object { $_ })
            $seq.Count | Should -BeGreaterThan 3

            # Only the segment belonging to THIS call. The log is cumulative over
            # the target's whole lifetime, so reading it from the front measures
            # an earlier call instead - which produced a confident and entirely
            # wrong verdict the first time this was run by hand.
            $lastSet = [array]::LastIndexOf([string[]]$seq, 'SETTEXT')
            $lastSet | Should -BeGreaterThan -1
            $tail = @($seq[($lastSet + 1)..($seq.Count - 1)])

            $firstCommit = -1
            $firstRead = -1
            for ($i = 0; $i -lt $tail.Count; $i++) {
                if ($firstCommit -lt 0 -and @('KEYDOWN', 'KEYUP', 'KILLFOCUS') -contains $tail[$i]) { $firstCommit = $i }
                if ($firstRead -lt 0 -and $tail[$i] -eq 'GETTEXT') { $firstRead = $i }
            }
            $firstCommit | Should -BeGreaterThan -1 -Because 'the commit keys must reach the control at all'
            $firstRead | Should -BeGreaterThan -1 -Because 'the readback must reach the control at all'
            $firstCommit | Should -BeLessThan $firstRead -Because 'the readback must observe the control, never the echo of the write'
        }

        It 'distinguishes a timed-out PRE-read from a control that read as empty' {
            # ROUND 2, S3, and mutation survivor N11. TimedOut has always meant
            # the READBACK, so a timed-out pre-read left Before=$null with
            # TimedOut=$false - "did not answer" and "answered empty" collapsed
            # into one row on that side of the write. Adding BeforeTimedOut was
            # not enough: pinning it $false passed the whole suite, because
            # nothing ever made a pre-read fail.
            (Set-SwdNumeric -Handle $script:EditH -Value '3').BeforeTimedOut |
                Should -BeFalse -Because 'a healthy control answers its pre-read'

            [void][SwdWin]::PostMessage([intptr]$script:SlowCtlH, [SwdWin]::BM_CLICK, [intptr]0, [intptr]0)
            Start-Sleep -Milliseconds 400          # the handler is now sleeping
            try {
                $r = Set-SwdNumeric -Handle $script:EditH -Value '11' -TimeoutMs 200 -SettleMs 100
                $r.BeforeTimedOut | Should -BeTrue
                $r.Before         | Should -BeNullOrEmpty
                $r.Ok             | Should -BeFalse
            } finally { Start-Sleep -Seconds 5 }   # let the pump come back
        }

        It 'refuses a non-numeric request before touching the control' {
            $before = Get-SwdText -Handle $script:EditH
            $r = Set-SwdNumeric -Handle $script:EditH -Value 'abc'
            $r.Ok | Should -BeFalse
            $r.Reason | Should -BeLike '*not numeric*'
            Get-SwdText -Handle $script:EditH | Should -BeExactly $before
        }
    }
}

# ---------------------------------------------------------------------------
#  MODAL DIALOG LAYER
#
#  Motivating measurement, 2026-08-28: clicking SWD's scan button raised a
#  confirmation and the scan did not start until a human pressed OK. Nothing in
#  the toolchain could SEE that dialog, because Get-SwdControl walks
#  EnumChildWindows from the MAIN window and a dialog is a separate TOP-LEVEL
#  window. The same click reported lastError=1460.
#
#  ROUND 4. The first version of this block was green at 191/191 while SIX of
#  nine deliberate reversals survived - including a safety predicate pinned to
#  BOTH constants. A green suite that does not bite launders confidence, so
#  every test below names the mutation it kills. Two structural moves made the
#  difference:
#
#    1. A GENUINELY MODAL harness. The old target used a modeless second form
#       because "a modal would block this process's own pump and the harness
#       could never read it back". That is true only of a modal in THIS process:
#       the target is a CHILD PROCESS, so ShowDialog blocks its pump and not
#       ours, and its nested message loop keeps servicing sent messages anyway.
#       "Untestable" has now meant "not yet written" four times in this target.
#    2. SHADOWING Get-SwdDialogControl, the same seam trick the suite already
#       uses on Get-SwdProcess. Two defects live in the window between
#       enumerating a dialog and clicking it - a race no wall clock hits
#       reliably, and perfectly deterministic once the test owns the enumeration.
# ---------------------------------------------------------------------------
Describe 'Source hygiene (the checks whose ABSENCE was itself a finding)' {
    # ROUND 2, W7. The previous round REPORTED adding a multi-line-string check.
    # It did not exist: it was run once as a throwaway shell command and then
    # written up as an artifact. That is the same defect this whole target is
    # about - claiming a state that was never achieved - committed in the report
    # rather than the code. It is a TEST now, so it runs with the guard, and so
    # its absence would fail rather than merely be untrue.
    BeforeAll {
        $script:SrcFiles = @(
            (Join-Path (Split-Path -Parent $PSScriptRoot) 'swd_msg.ps1')
            (Join-Path (Split-Path -Parent $PSScriptRoot) 'swd_diagnose.ps1')
            (Join-Path $PSScriptRoot 'swd_msg.Tests.ps1')
            (Join-Path $PSScriptRoot 'swd_diagnose.Tests.ps1')
        )
    }

    It 'has no accidental multi-line string literal in <leaf>' -ForEach @(
        @{ leaf = 'swd_msg.ps1' }, @{ leaf = 'swd_diagnose.ps1' }
        @{ leaf = 'swd_msg.Tests.ps1' }, @{ leaf = 'swd_diagnose.Tests.ps1' }
    ) {
        # THE HAZARD, measured: dropping one closing quote from a Log line makes
        # the string swallow every following line until the next quote. The file
        # still PARSES - a single-quoted PowerShell string may span lines - and
        # Invoke-ScriptAnalyzer -Severity Error,Warning still returns nothing. So
        # neither of the two checks this project already runs can see it, and the
        # only visible symptom is log lines quietly disappearing.
        #
        # A here-string is the legitimate way to span lines and is excluded by
        # its own opening token. Nothing else in these four files may.
        $path = @($script:SrcFiles | Where-Object { (Split-Path -Leaf $_) -eq $leaf })[0]
        $path | Should -Not -BeNullOrEmpty
        $tokens = $null; $errors = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors)
        @($errors).Count | Should -Be 0
        $spanning = @($tokens | Where-Object {
            ($_.Kind -eq 'StringLiteral' -or $_.Kind -eq 'StringExpandable') -and
            $_.Extent.StartLineNumber -ne $_.Extent.EndLineNumber -and
            -not ($_.Text.StartsWith("@'") -or $_.Text.StartsWith('@"'))
        })
        $where = ($spanning | ForEach-Object { "line $($_.Extent.StartLineNumber)" }) -join ', '
        $spanning.Count | Should -Be 0 -Because "a non-here-string spanning lines is almost always a dropped quote ($where)"
    }

    It 'keeps <leaf> at <ending>, ASCII, no BOM' -ForEach @(
        @{ leaf = 'swd_msg.ps1';             ending = 'LF' }
        @{ leaf = 'swd_diagnose.ps1';        ending = 'CRLF' }
        @{ leaf = 'swd_msg.Tests.ps1';       ending = 'LF' }
        @{ leaf = 'swd_diagnose.Tests.ps1';  ending = 'LF' }
    ) {
        # The other constraint that has only ever been REMEMBERED. CRLF in a file
        # the tooling treats as LF broke a seam anchor this same round (W4), and
        # Windows PowerShell 5.1 mis-reads non-ASCII without a BOM while the
        # project forbids the BOM - so the only safe point in that space is
        # ASCII with no BOM, and it should be asserted rather than trusted.
        $path = @($script:SrcFiles | Where-Object { (Split-Path -Leaf $_) -eq $leaf })[0]
        $bytes = [IO.File]::ReadAllBytes($path)
        $lf = @($bytes | Where-Object { $_ -eq 0x0A }).Count
        $cr = @($bytes | Where-Object { $_ -eq 0x0D }).Count
        $lf | Should -BeGreaterThan 0
        if ($ending -eq 'CRLF') { $cr | Should -Be $lf } else { $cr | Should -Be 0 }
        @($bytes | Where-Object { $_ -gt 127 }).Count | Should -Be 0 -Because 'non-ASCII needs a BOM to survive 5.1, and the BOM is forbidden'
        ($bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) | Should -BeFalse
        ($bytes[0] -eq 0xFF -or $bytes[0] -eq 0xFE) | Should -BeFalse
    }

    It 'detects a dropped quote that BOTH existing checks miss' {
        # The check has to be shown to bite, or it is one more claim. A copy of
        # swd_diagnose.ps1 with exactly two characters removed: parse is clean,
        # PSScriptAnalyzer Error+Warning is clean, and the hygiene rule fires.
        # TWO dropped quotes, not one. That is what the real defect looked like:
        # an ODD number leaves the file unterminated at EOF and DOES raise a
        # parse error, so a one-quote fixture would prove the opposite of the
        # point. An even number re-pairs, the file parses, and a whole Log line
        # is silently swallowed into the string above it.
        $broken = Join-Path $TestDrive 'broken-quote.ps1'
        Set-Content -LiteralPath $broken -Encoding ASCII -Value @(
            'function Log { param([Parameter(ValueFromRemainingArguments)]$Text) Write-Output $Text }'
            "Log '     first line of guidance'"
            "Log '     second line, closing quote dropped"
            "Log '     third line, closing quote dropped"
            "Log '     fourth line of guidance'"
        )
        $t = $null; $e = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile($broken, [ref]$t, [ref]$e)
        @($e).Count | Should -Be 0 -Because 'this is the point: it parses cleanly'
        @(Invoke-ScriptAnalyzer -Path $broken -Severity Error, Warning).Count |
            Should -Be 0 -Because 'and PSScriptAnalyzer says nothing either'
        @($t | Where-Object {
            ($_.Kind -eq 'StringLiteral' -or $_.Kind -eq 'StringExpandable') -and
            $_.Extent.StartLineNumber -ne $_.Extent.EndLineNumber -and
            -not ($_.Text.StartsWith("@'") -or $_.Text.StartsWith('@"'))
        }).Count | Should -BeGreaterThan 0 -Because 'the hygiene rule is the only one that sees it'
    }
}

Describe 'Format-SwdSendError' {
    It 'reports 1460 as AMBIGUOUS, committing to neither reading' {
        # C3. The helper first said "THE SEND FAILED. Nothing was measured"; that
        # was replaced by "the click most likely LANDED ... do NOT read this as
        # failure", which is the same error with the sign flipped. Measured
        # 2026-08-28 on a throwaway cross-process WinForms target, BOTH of these
        # produce exactly 1460:
        #   pump blocked by a sleeping UI thread - two sends, both 1460, and the
        #     click counter still read 'CNT 0'.  NEITHER CLICK LANDED.
        #   click lands, handler opens a modal - 1460, caption advanced. LANDED.
        $m = Format-SwdSendError -LastError 1460 -Sent $false
        $m | Should -BeLike '*TIMED OUT*'
        $m | Should -BeLike '*AMBIGUOUS*'
        $m | Should -BeLike '*Wait-SwdDialog*'
        # It must name BOTH possibilities rather than going silent ...
        $m | Should -BeLike '*never landed*'
        # ... and commit to neither.
        $m | Should -Not -BeLike '*most likely*'
        $m | Should -Not -BeLike '*do NOT read this as failure*'
        $m | Should -Not -BeLike '*Nothing was measured*'
    }

    It 'reads 5 as the UIPI signature and names the fix' {
        $m = Format-SwdSendError -LastError 5 -Sent $false
        $m | Should -BeLike '*ACCESS_DENIED*'
        $m | Should -BeLike '*elevated*'
    }

    It 'reports a delivered send as delivered regardless of a stale error code' {
        # Transport-aware now: a SENT message that completed was handled by the
        # window procedure, and a POSTED one was only queued. Reporting the
        # latter as delivered was C1.
        Format-SwdSendError -LastError 1460 -Sent $true | Should -BeLike 'delivered*'
        Format-SwdSendError -LastError 0 -Sent $true -Method 'PostMessage' |
            Should -BeLike '*QUEUED ONLY*'
        Format-SwdSendError -LastError 0 -Sent $true -Method 'PostMessage' |
            Should -Not -BeLike 'delivered*'
    }

    It 'does not invent meaning for an unknown code' {
        Format-SwdSendError -LastError 9999 -Sent $false | Should -BeLike '*9999*'
    }
}

Describe 'Test-SwdOwnsForeground' {
    # W4. This predicate had ZERO effective coverage: mutants returning
    # unconditional $true and unconditional $false BOTH passed the full 18-test
    # diagnostic suite. It also failed UNSAFE - every unanswerable case returned
    # $false, and $false is not "unknown", it is the affirmative claim that SWD
    # does NOT hold the foreground. That claim is the sole premise for "THE CLICK
    # LANDED WITHOUT FOCUS", the project's load-bearing headless result.
    It 'returns $true when the handle belongs to the process' {
        Test-SwdOwnsForeground -Handle $script:OwnHwnd -ProcessId $PID | Should -BeTrue
    }

    It 'returns $false when the handle belongs to a DIFFERENT live process' {
        # A real window of a real other process, not a fabricated pid: the
        # comparison has to be wrong for the right reason.
        $other = Start-Process powershell.exe -PassThru -ArgumentList @(
            '-NoProfile', '-Command', 'Start-Sleep -Seconds 30')
        try {
            Test-SwdOwnsForeground -Handle $script:OwnHwnd -ProcessId $other.Id | Should -BeFalse
        } finally { Stop-Process -Id $other.Id -Force -ErrorAction SilentlyContinue }
    }

    It 'returns $null - UNKNOWN, never $false - when there is no foreground window' {
        # GetForegroundWindow returns 0 on a locked workstation and on the UAC
        # secure desktop. The old code called that "SWD does not hold focus".
        ($null -eq (Test-SwdOwnsForeground -Handle 0 -ProcessId $PID)) | Should -BeTrue
    }

    It 'returns $null - UNKNOWN - for a handle that is no longer a window' {
        ($null -eq (Test-SwdOwnsForeground -Handle $script:DeadHwnd -ProcessId $PID)) | Should -BeTrue
    }

    It 'returns $null - UNKNOWN - for a process id that cannot be real' {
        ($null -eq (Test-SwdOwnsForeground -Handle $script:OwnHwnd -ProcessId 0)) | Should -BeTrue
    }

    It 'never answers $false for a question it could not ask' {
        # The mutation pinned to $false passed the old suite outright. If any
        # unanswerable input comes back $false, section F prints an unfocused
        # claim it never measured.
        foreach ($h in @([int64]0, $script:DeadHwnd)) {
            (Test-SwdOwnsForeground -Handle $h -ProcessId $PID) | Should -Not -Be $false
        }
    }
}

Describe 'SwdWin.TopLevelForPid' {
    # W5. Deleting the pid filter in the C# left the whole suite green, and this
    # enumerator then walks EVERY top-level window on the desktop - the defect
    # [SwdWin]::Children throws to prevent, after SQA measured 479 foreign
    # windows flowing into the control map.
    It 'returns only windows owned by the requested process' {
        $rows = @([SwdWin]::TopLevelForPid($PID))
        $rows.Count | Should -BeGreaterThan 0
        foreach ($line in $rows) {
            $f = $line -split ([regex]::Escape([SwdWin]::SEP))
            $f.Count | Should -Be ([SwdWin]::TOPLEVEL_FIELDS)
            [SwdWin]::OwnerPid([intptr][int64]$f[0]) | Should -Be $PID
        }
    }

    It 'does not return a window belonging to another process' {
        # A WINDOWED process, not a bare `powershell -Command Start-Sleep`. The
        # first version of this fixture used the latter and asserted on an EMPTY
        # set: under ConPTY the console window belongs to the terminal host, not
        # to powershell.exe, so TopLevelForPid returned nothing and the test
        # proved nothing about discrimination. A test whose evidence set is empty
        # passes for the same reason a broken filter would.
        $ps = Join-Path $TestDrive 'toplevel-other.ps1'
        Set-Content -LiteralPath $ps -Encoding ASCII -Value @(
            'Add-Type -AssemblyName System.Windows.Forms'
            'Add-Type -AssemblyName System.Drawing'
            '$f = New-Object System.Windows.Forms.Form'
            "`$f.Text = 'SWDTESTS-OTHERPROC'"
            "`$f.StartPosition = 'Manual'"
            '$f.Location = New-Object System.Drawing.Point(-32000, -32000)'
            '[System.Windows.Forms.Application]::Run($f)')
        $other = Start-Process powershell.exe -PassThru -ArgumentList @(
            '-NoProfile', '-ExecutionPolicy', 'Bypass', '-STA', '-WindowStyle', 'Hidden', '-File', $ps)
        try {
            $h = 0
            for ($i = 0; $i -lt 80 -and $h -eq 0; $i++) {
                Start-Sleep -Milliseconds 250
                $h = (Get-Process -Id $other.Id -ErrorAction Stop).MainWindowHandle
            }
            $h | Should -Not -Be 0 -Because 'the fixture must actually own a window'

            $mine = @([SwdWin]::TopLevelForPid($PID) | ForEach-Object {
                        [int64](($_ -split ([regex]::Escape([SwdWin]::SEP)))[0]) })
            $theirs = @([SwdWin]::TopLevelForPid($other.Id) | ForEach-Object {
                        [int64](($_ -split ([regex]::Escape([SwdWin]::SEP)))[0]) })
            $theirs.Count | Should -BeGreaterThan 0
            $theirs | Should -Contain ([int64]$h)
            foreach ($x in $theirs) { $mine | Should -Not -Contain $x }
        } finally { Stop-Process -Id $other.Id -Force -ErrorAction SilentlyContinue }
    }

    It 'refuses pid 0, which is what GetWindowThreadProcessId leaves on failure' {
        { [SwdWin]::TopLevelForPid(0) } | Should -Throw
    }
}

Describe 'Dialog layer (throwaway target with a REAL modal and two modeless dialogs)' {
    BeforeAll {
        $dlgPs = Join-Path $TestDrive 'modaltarget.ps1'
        $src = @(
            "Add-Type -AssemblyName System.Windows.Forms"
            "Add-Type -AssemblyName System.Drawing"
            "`$f = New-Object System.Windows.Forms.Form"
            "`$f.Text = 'SWDTESTS-MODALMAIN'"
            "`$f.StartPosition = 'Manual'"
            "`$f.Location = New-Object System.Drawing.Point(-32000, -32000)"
            # RAISE opens a GENUINELY MODAL dialog. ShowDialog blocks the TARGET
            # process and never this one, which is the whole reason a child
            # process makes the modal case testable.
            "`$raise = New-Object System.Windows.Forms.Button"
            "`$raise.Text = 'RAISE'; `$raise.Width = 120; `$f.Controls.Add(`$raise)"
            # Two MODELESS dialogs, so -TitleLike has something to discriminate.
            # Both are OWNED by the main form, so .NET MainWindowHandle - which
            # picks the first VISIBLE UNOWNED top-level window - keeps resolving
            # to the main form and the seam stays stable.
            "`$a = New-Object System.Windows.Forms.Form"
            "`$a.Text = 'SWDTESTS-DLG-A'; `$a.StartPosition = 'Manual'"
            "`$a.Location = New-Object System.Drawing.Point(-31000, -32000)"
            "`$b = New-Object System.Windows.Forms.Form"
            "`$b.Text = 'SWDTESTS-DLG-B'; `$b.StartPosition = 'Manual'"
            "`$b.Location = New-Object System.Drawing.Point(-30000, -32000)"
            # An INVISIBLE top-level window: reading .Handle forces the HWND to
            # exist without ever showing the window.
            "`$hid = New-Object System.Windows.Forms.Form"
            "`$hid.Text = 'SWDTESTS-HIDDEN'"
            "`$null = `$hid.Handle"
            "`$script:okn = 0; `$script:slown = 0"
            "`$raise.Add_Click({"
            "  `$g = New-Object System.Windows.Forms.Form"
            "  `$g.Text = 'SWDTESTS-MODAL'; `$g.StartPosition = 'Manual'"
            "  `$g.Location = New-Object System.Drawing.Point(-29000, -32000)"
            "  `$g.Width = 420; `$g.Height = 440"
            "  `$lbl = New-Object System.Windows.Forms.Label"
            "  `$lbl.Text = 'HydroScan can takes more than 60 mn'; `$lbl.Width = 340"
            "  `$g.Controls.Add(`$lbl)"
            "  `$ok = New-Object System.Windows.Forms.Button"
            "  `$ok.Text = 'OK'; `$ok.Top = 30; `$ok.Width = 150; `$g.Controls.Add(`$ok)"
            "  `$ok.Add_Click({ `$script:okn++; `$ok.Text = `"OK `$script:okn`" })"
            # SLOW blocks the target's pump from INSIDE its own click handler -
            # the exact shape of SWD's scan button opening a modal, and the only
            # deterministic way to produce lastError=1460.
            "  `$slow = New-Object System.Windows.Forms.Button"
            "  `$slow.Text = 'SLOW'; `$slow.Top = 60; `$slow.Width = 150; `$g.Controls.Add(`$slow)"
            "  `$slow.Add_Click({ [System.Threading.Thread]::Sleep(4000);"
            "     `$script:slown++; `$slow.Text = `"SLOW `$script:slown`" })"
            "  `$cf = New-Object System.Windows.Forms.Button"
            "  `$cf.Text = '&Confirm'; `$cf.Top = 90; `$cf.Width = 150; `$g.Controls.Add(`$cf)"
            "  `$r1 = New-Object System.Windows.Forms.Button"
            "  `$r1.Text = 'Retry'; `$r1.Top = 120; `$r1.Width = 150; `$g.Controls.Add(`$r1)"
            "  `$r2 = New-Object System.Windows.Forms.Button"
            "  `$r2.Text = '&Retry'; `$r2.Top = 150; `$r2.Width = 150; `$g.Controls.Add(`$r2)"
            "  `$ap = New-Object System.Windows.Forms.Button"
            "  `$ap.Text = 'Apply'; `$ap.Enabled = `$false; `$ap.Top = 180; `$ap.Width = 150"
            "  `$g.Controls.Add(`$ap)"
            # The W2 pair. Both are CheckBoxes reporting a BUTTON window class;
            # only the FlatStyle=System one is separable by its style word.
            "  `$cb = New-Object System.Windows.Forms.CheckBox"
            "  `$cb.Text = 'Delete this hydroscan'; `$cb.Top = 210; `$cb.Width = 250"
            "  `$g.Controls.Add(`$cb)"
            "  `$sc = New-Object System.Windows.Forms.CheckBox"
            "  `$sc.Text = 'SysDelete'; `$sc.FlatStyle = 'System'; `$sc.Top = 240; `$sc.Width = 250"
            "  `$g.Controls.Add(`$sc)"
            "  `$cn = New-Object System.Windows.Forms.Button"
            "  `$cn.Text = 'Cancel'; `$cn.Top = 270; `$cn.Width = 150; `$g.Controls.Add(`$cn)"
            "  `$cn.Add_Click({ `$g.Close() })"
            "  [void]`$g.ShowDialog(`$f)"
            "})"
            "`$f.Add_Shown({ `$a.Show(`$f); `$b.Show(`$f) })"
            "[System.Windows.Forms.Application]::Run(`$f)"
        )
        Set-Content -LiteralPath $dlgPs -Value $src -Encoding ASCII

        $script:DlgTarget = Start-Process powershell.exe -PassThru -ArgumentList @(
            '-NoProfile', '-ExecutionPolicy', 'Bypass', '-STA', '-WindowStyle', 'Hidden', '-File', $dlgPs)
        $script:DlgId = $script:DlgTarget.Id
        $mainH = 0
        for ($i = 0; $i -lt 80 -and $mainH -eq 0; $i++) {
            Start-Sleep -Milliseconds 250
            $mainH = (Get-Process -Id $script:DlgId -ErrorAction Stop).MainWindowHandle
        }
        if ($mainH -eq 0) { throw 'modal target never produced a visible window' }
        $script:DlgMainH = $mainH

        # THE SEAM. Same one the live-control harness uses: every live-application
        # function routes through Get-SwdProcess, so redefining it points the whole
        # library at the throwaway target. No SWD is involved anywhere.
        function Get-SwdProcess {
            $p = Get-Process -Id $script:DlgId -ErrorAction Stop
            if ($p.MainWindowHandle -eq 0) { throw 'target has no main window' }
            $p
        }

        # Raise the modal by POSTING BM_CLICK. Posted, not sent: a sent BM_CLICK
        # would not return until the modal was dismissed, which is the very
        # deadlock this layer exists to survive.
        $script:RaiseH = (Get-SwdControl | Where-Object { $_.Text -eq 'RAISE' } |
                            Select-Object -First 1).Handle
        if (-not $script:RaiseH) { throw 'could not find the RAISE button' }
        [void][SwdWin]::PostMessage([intptr]$script:RaiseH, [SwdWin]::BM_CLICK, [intptr]0, [intptr]0)

        $script:Modal = $null
        for ($i = 0; $i -lt 40 -and -not $script:Modal; $i++) {
            # No trailing wildcard: '*SWDTESTS-MODAL' must not match the MAIN
            # window, which is called SWDTESTS-MODALMAIN.
            $script:Modal = Wait-SwdDialog -TimeoutMs 1000 -TitleLike '*SWDTESTS-MODAL'
            if (-not $script:Modal) { Start-Sleep -Milliseconds 150 }
        }
        if (-not $script:Modal) { throw 'the modal dialog never appeared' }

        function Block-TargetPump {
            <#  Fire the modal's SLOW button and WAIT until the target pump is
                genuinely blocked, bounded. A fixed Start-Sleep is not enough:
                posted clicks QUEUE, so one test's block can still be pending
                when the next test starts, and the read then succeeds - failing
                the test for a reason that has nothing to do with the code.  #>
            $h = @(Get-SwdDialogControl -Handle $script:Modal.Handle |
                     Where-Object { $_.Text -like 'SLOW*' })[0].Handle
            [void][SwdWin]::PostMessage([intptr]$h, [SwdWin]::BM_CLICK, [intptr]0, [intptr]0)
            for ($i = 0; $i -lt 60; $i++) {
                Start-Sleep -Milliseconds 50
                if ($null -eq [SwdWin]::GetText([intptr]$script:Modal.Handle, 150)) { return $true }
            }
            return $false
        }

        function Get-ModalChild {
            param([string]$Like)
            $m = @(Get-SwdDialogControl -Handle $script:Modal.Handle |
                     Where-Object { $_.Text -like $Like })
            if ($m.Count -eq 0) { throw "no child of the modal matches '$Like'" }
            $m[0]
        }

        # One fake row shaped exactly like a Get-SwdDialogControl record. Used by
        # the shadowing tests below; built here so the shape is stated once.
        function New-FakeRow {
            param([int64]$Handle, [string]$Class = 'Button', [string]$Text = 'OK',
                  [bool]$Enabled = $true, [bool]$TimedOut = $false, [bool]$Skipped = $false,
                  [bool]$Visible = $true)
            [pscustomobject]@{
                Handle = $Handle; Class = $Class; CtrlId = 1; Visible = $Visible
                Enabled = $Enabled; Rect = '0,0,1,1'; Parent = 0
                Text = $(if ($TimedOut) { $null } else { $Text })
                TimedOut = $TimedOut; Skipped = $Skipped; LastError = 0
            }
        }
    }

    AfterAll {
        if ($script:DlgTarget) { Stop-Process -Id $script:DlgTarget.Id -Force -ErrorAction SilentlyContinue }
    }

    Context 'enumeration' {
        It 'finds a REAL modal that Get-SwdControl structurally cannot see' {
            $script:Modal.Handle | Should -Not -Be 0
            $script:Modal.Handle | Should -Not -Be $script:DlgMainH
            @(Get-SwdControl | Where-Object { $_.Handle -eq $script:Modal.Handle }).Count | Should -Be 0
        }

        It 'excludes the main window from the dialog list' {
            @(Get-SwdDialog).Handle | Should -Not -Contain $script:DlgMainH
        }

        It 'returns only windows owned by the target process' {
            # W5 at the PowerShell layer, above the C# filter that has its own test.
            foreach ($d in @(Get-SwdDialog)) {
                [SwdWin]::OwnerPid([intptr]$d.Handle) | Should -Be $script:DlgId
            }
        }

        It 'HIDES an invisible top-level window unless -IncludeInvisible is given' {
            # Mutation: dropping the visibility filter left the suite green, and a
            # driver then treats a window the user cannot see as a live dialog.
            $vis = @(Get-SwdDialog)
            @($vis | Where-Object { $_.Title -like '*SWDTESTS-HIDDEN*' }).Count | Should -Be 0
            foreach ($d in $vis) { $d.Visible | Should -BeTrue }

            $all = @(Get-SwdDialog -IncludeInvisible)
            @($all | Where-Object { $_.Title -like '*SWDTESTS-HIDDEN*' }).Count | Should -Be 1
            $all.Count | Should -BeGreaterThan $vis.Count
        }

        It 'enumerates the dialog OWN children with the full Get-SwdControl record shape' {
            # W3: the first version emitted no Skipped field, so reading .Skipped
            # threw under the StrictMode this library installs - and
            # swd_diagnose.ps1 consumes .Skipped on sibling rows.
            $kids = @(Get-SwdDialogControl -Handle $script:Modal.Handle)
            $kids.Count | Should -BeGreaterThan 1
            foreach ($f in 'Handle', 'Class', 'CtrlId', 'Visible', 'Enabled', 'Rect',
                           'Parent', 'Text', 'TimedOut', 'Skipped', 'LastError') {
                $kids[0].PSObject.Properties.Name | Should -Contain $f
            }
            { @($kids | Where-Object { $_.Skipped }).Count } | Should -Not -Throw
            @($kids | Where-Object { $_.Text -like 'OK*' }).Count | Should -BeGreaterThan 0
        }

        It 'publishes an aggregate that names the enumeration it describes' {
            # W3: after enumerating five dialog children, Get-SwdControlSummary
            # still reported the PREVIOUS call's Total=0 - an aggregate describing
            # an enumeration it never saw.
            $null = @(Get-SwdControl)
            (Get-SwdControlSummary).Scope | Should -BeLike 'MainWindow*'
            $kids = @(Get-SwdDialogControl -Handle $script:Modal.Handle)
            $s = Get-SwdControlSummary
            $s.Scope | Should -BeLike "Dialog $($script:Modal.Handle)*"
            $s.Total | Should -Be $kids.Count
            $s.Total | Should -BeGreaterThan 0
        }

        It 'produces TimedOut=$true from a REALLY unreadable control, not a fabricated row' {
            # ROUND 2, W2. Every TimedOut=$true in the suite was a hand-built row
            # handed to a shadowed enumerator, so deleting the flag's PRODUCTION
            # passed 225/225 - and that silently defeats the read-coverage gate,
            # because a half-read dialog would come back FullyRead=$true and be
            # clicked. SLOW blocks the target pump from inside its own handler,
            # which makes a genuinely unreadable control reproducible.
            (Block-TargetPump) | Should -BeTrue -Because 'the fixture must actually block the pump'
            try {
                $kids = @(Get-SwdDialogControl -Handle $script:Modal.Handle -TimeoutMs 250)
                $out  = @($kids | Where-Object { $_.TimedOut })
                $out.Count | Should -BeGreaterThan 0
                foreach ($k in $out) { $k.Text | Should -BeNullOrEmpty }
                (Get-SwdControlSummary).TimedOut | Should -Be $out.Count
            } finally { Start-Sleep -Seconds 5 }   # let the pump come back
        }

        It 'the read-coverage gate REFUSES a really-unreadable dialog, end to end' {
            # The consequence W2 names, asserted against a real blocked pump
            # rather than a fabricated row.
            (Block-TargetPump) | Should -BeTrue -Because 'the fixture must actually block the pump'
            try {
                $r = Invoke-SwdDialogButton -DialogHandle $script:Modal.Handle `
                        -ExpectLike '*more than 60 mn*' -ButtonLike 'OK*' -TimeoutMs 250 -Confirm:$false
                $r.FullyRead | Should -BeFalse
                $r.Matched   | Should -BeFalse
                $r.Attempted | Should -BeFalse
                $r.Reason    | Should -BeLike '*NOT fully read*'
            } finally { Start-Sleep -Seconds 5 }
        }

        It 'caps the whole TOP-LEVEL enumeration with -DeadlineMs' {
            # ROUND 2 mutation survivor N12. The deadline was added because
            # Wait-SwdDialog calls Get-SwdDialog in a poll loop, so an unbounded
            # enumeration was N x TimeoutMs PER ITERATION against a hung SWD -
            # but nothing exercised it, and deleting it passed the whole suite.
            #
            # The pump is blocked first so the FIRST read really does consume the
            # budget; with a healthy target a 1 ms deadline is a race against a
            # sub-millisecond WM_GETTEXT and would not fire reliably.
            $before = @(Get-SwdDialog -IncludeInvisible)
            $before.Count | Should -BeGreaterThan 1

            (Block-TargetPump) | Should -BeTrue -Because 'the fixture must actually block the pump'
            try {
                $sw = [Diagnostics.Stopwatch]::StartNew()
                $capped = @(Get-SwdDialog -IncludeInvisible -TimeoutMs 200 -DeadlineMs 1)
                $sw.Stop()
                # every window is still REPORTED - capped, never silently missing
                $capped.Count | Should -Be $before.Count
                foreach ($d in $capped | Where-Object { $_.TimedOut }) { $d.Title | Should -BeNullOrEmpty }

                # THE DISCRIMINATOR IS ELAPSED TIME, not the TimedOut flag. With
                # the pump blocked every read times out anyway, so asserting
                # "something timed out" passes with OR without the cap - which is
                # exactly how the first version of this test let the mutant live.
                # The cap means only the FIRST window is actually read; without
                # it, every window costs the full TimeoutMs.
                $sw.ElapsedMilliseconds |
                    Should -BeLessThan (200 * $before.Count) -Because "the cap must stop the enumeration paying $($before.Count) x 200 ms"
                $sw.ElapsedMilliseconds | Should -BeLessThan 500
            } finally { Start-Sleep -Seconds 5 }
        }

        It 'produces Skipped=$true when the enumeration deadline bites' {
            # -DeadlineMs was plumbed but never exercised, so its production side
            # was in the same position as TimedOut.
            $kids = @(Get-SwdDialogControl -Handle $script:Modal.Handle -DeadlineMs 1)
            @($kids | Where-Object { $_.Skipped }).Count | Should -BeGreaterThan 0
            foreach ($k in $kids | Where-Object { $_.Skipped }) {
                $k.Text     | Should -BeNullOrEmpty
                $k.TimedOut | Should -BeTrue   # skipped is a KIND of not-read
            }
            (Get-SwdControlSummary).DeadlineHit | Should -BeTrue
        }

        It 'honours -TitleLike in BOTH directions' {
            # Mutation: ignoring -TitleLike left the suite green, because with one
            # dialog the unfiltered answer happened to be the right one. Two
            # dialogs and two opposite requests cannot both be satisfied by a
            # function that ignores the filter, whatever the Z-order.
            (Wait-SwdDialog -TimeoutMs 4000 -TitleLike '*DLG-A*').Title | Should -BeLike '*DLG-A*'
            (Wait-SwdDialog -TimeoutMs 4000 -TitleLike '*DLG-B*').Title | Should -BeLike '*DLG-B*'
        }

        It 'returns $null - NOT SEEN - for a title that is not there, inside its budget' {
            # S5: the elapsed check sat only at the top of the loop, so the real
            # bound was TimeoutMs plus a whole poll interval plus an enumeration.
            # A poll interval far LONGER than the budget is what separates the two
            # implementations. Checking only at the loop top sleeps the whole
            # PollMs first and returns at ~3.1 s; clamping the sleep to what is
            # left returns at ~0.6 s. A 1000/400 pair could not tell them apart -
            # both land under 2.5 s - which is how the original defect survived.
            $sw = [Diagnostics.Stopwatch]::StartNew()
            $r = Wait-SwdDialog -TimeoutMs 500 -PollMs 3000 -TitleLike '*NO-SUCH-DIALOG*'
            $sw.Stop()
            $r | Should -BeNullOrEmpty
            $sw.ElapsedMilliseconds | Should -BeLessThan 1500
        }
    }

    Context 'the -ExpectLike safety gate' {
        It 'REFUSES to click when the dialog text does not match' {
            # If this ever passes with the gate removed, a driver can accept
            # "Delete this hydroscan?" while expecting the 60-minute confirmation.
            # On a licensed install holding 143 reports that is not recoverable.
            $before = (Get-ModalChild 'OK*').Text
            $r = Invoke-SwdDialogButton -DialogHandle $script:Modal.Handle `
                    -ExpectLike '*Delete this hydroscan is what I expect*' -ButtonLike 'OK*' -Confirm:$false
            $r.Matched   | Should -BeFalse
            $r.Attempted | Should -BeFalse
            $r.Sent      | Should -BeFalse
            $r.Observed  | Should -Be 'not-attempted'
            $r.Reason    | Should -BeLike '*REFUSED*'
            Start-Sleep -Milliseconds 300
            (Get-ModalChild 'OK*').Text | Should -Be $before
        }

        It 'clicks when the dialog says what the caller expected' {
            $before = (Get-ModalChild 'OK*').Text
            $r = Invoke-SwdDialogButton -DialogHandle $script:Modal.Handle `
                    -ExpectLike '*more than 60 mn*' -ButtonLike 'OK*' -Confirm:$false
            $r.Matched   | Should -BeTrue
            $r.FullyRead | Should -BeTrue
            $r.Attempted | Should -BeTrue
            $r.Sent      | Should -BeTrue
            $r.Method    | Should -Be 'SendMessageTimeout'
            $r.Observed  | Should -Be 'handled'
            Start-Sleep -Milliseconds 400
            (Get-ModalChild 'OK*').Text | Should -Not -Be $before
        }

        It 'refuses a handle that does not belong to the target process' {
            # A real -ButtonLike, not '*': the suite used to normalise away the
            # very escape hatch it should be exercising.
            { Invoke-SwdDialogButton -DialogHandle ([int64](Get-Process -Id $PID).MainWindowHandle) `
                  -ExpectLike '*more than 60 mn*' -ButtonLike 'OK*' -Confirm:$false } | Should -Throw
        }

        It 'requires -ExpectLike, and REFUSES a bare wildcard without -AnyText' {
            # S4 plus the settled decision. -ButtonLike was made mandatory because
            # 'OK' is the caption a blind driver presses on the wrong dialog; '*'
            # is that defect one level up, and this round proved the button-type
            # guard inert against WinForms and Visible unconsulted - so -ExpectLike
            # is the only gate here still carrying weight.
            (Get-Command Invoke-SwdDialogButton).Parameters['ExpectLike'].Attributes |
                Where-Object { $_ -is [Parameter] } |
                ForEach-Object { $_.Mandatory } | Should -Contain $true

            foreach ($pattern in '*', '**', '  *  ') {
                { Invoke-SwdDialogButton -DialogHandle $script:Modal.Handle `
                    -ExpectLike $pattern -ButtonLike 'OK*' -Confirm:$false } |
                    Should -Throw '*defeats the only gate*'
            }
            # -AnyText is how a caller says it meant it.
            $ok = Invoke-SwdDialogButton -DialogHandle $script:Modal.Handle `
                    -ExpectLike '*' -AnyText -ButtonLike 'OK*' -WhatIf -Confirm:$false
            $ok.Matched | Should -BeTrue
            $ok.WhatIf  | Should -BeTrue
        }

        It 'asks for confirmation by default - ConfirmImpact is High' {
            # The second settled decision. Every call in this suite passes
            # -Confirm:$false, so without this assertion the attribute could be
            # deleted and nothing would notice: the tests would simply stop being
            # protected by a prompt they never see. Asserted on the metadata
            # rather than by driving a prompt, which would hang the run.
            $ci = (Get-Command Invoke-SwdDialogButton).ScriptBlock.Attributes |
                    Where-Object { $_ -is [System.Management.Automation.CmdletBindingAttribute] }
            $ci.SupportsShouldProcess | Should -BeTrue
            $ci.ConfirmImpact | Should -Be 'High'
        }

        It 'requires -ButtonLike rather than defaulting to OK' {
            # S4. 'OK' is precisely the caption a blind driver would press on the
            # wrong dialog, so it may not be the value you get by saying nothing.
            (Get-Command Invoke-SwdDialogButton).Parameters['ButtonLike'].Attributes |
                Where-Object { $_ -is [Parameter] } |
                ForEach-Object { $_.Mandatory } | Should -Contain $true
        }
    }

    Context 'button resolution' {
        It 'strips ampersand accelerators from both sides' {
            # Mutation: neutering the stripping left the suite green.
            $r = Invoke-SwdDialogButton -DialogHandle $script:Modal.Handle `
                    -ExpectLike '*more than 60 mn*' -ButtonLike 'Confirm' -WhatIf -Confirm:$false
            $r.Candidates   | Should -Be 1
            $r.ButtonHandle | Should -Not -BeNullOrEmpty
        }

        It 'REFUSES an ambiguous -ButtonLike instead of resolving it by Z-order' {
            # W2. 'Retry' and '&Retry' both strip to 'Retry'. Select-Object
            # -First 1 used to pick one of them silently.
            $r = Invoke-SwdDialogButton -DialogHandle $script:Modal.Handle `
                    -ExpectLike '*more than 60 mn*' -ButtonLike 'Retry' -Confirm:$false
            $r.Matched    | Should -BeTrue
            $r.Candidates | Should -Be 2
            $r.Attempted  | Should -BeFalse
            $r.Sent       | Should -BeFalse
            $r.Reason     | Should -BeLike '*AMBIGUOUS*'
        }

        It 'REFUSES a caption match that is enabled but INVISIBLE' {
            # W5. Visible was captured on every row and never consulted. Measured
            # in SWD's own control-map.csv: 13 of 53 *BUTTON* rows are
            # Visible=False with Enabled=True, captioned 'Apply', 'Clean Shape',
            # 'UnLock' among others - so a caption match alone selects controls
            # the operator cannot see, on a layout SWD already ships.
            function Get-SwdDialogControl { param($Handle, $TimeoutMs, $DeadlineMs)
                New-FakeRow -Handle $script:DeadHwnd -Text 'Apply' -Visible $false }
            $r = Invoke-SwdDialogButton -DialogHandle $script:Modal.Handle `
                    -ExpectLike '*SWDTESTS-MODAL*' -ButtonLike 'Apply' -Confirm:$false
            $r.Matched    | Should -BeTrue
            $r.Candidates | Should -Be 0
            $r.Attempted  | Should -BeFalse
            $r.Reason     | Should -BeLike '*INVISIBLE*'
        }

        It 'tells "all matches are disabled" apart from "no such button"' {
            $d = Invoke-SwdDialogButton -DialogHandle $script:Modal.Handle `
                    -ExpectLike '*more than 60 mn*' -ButtonLike 'Apply' -Confirm:$false
            $d.Attempted | Should -BeFalse
            $d.Reason    | Should -BeLike '*DISABLED*'

            $n = Invoke-SwdDialogButton -DialogHandle $script:Modal.Handle `
                    -ExpectLike '*more than 60 mn*' -ButtonLike 'Proceed' -Confirm:$false
            $n.Attempted | Should -BeFalse
            $n.Reason    | Should -BeLike '*no BUTTON matching*'
            # and the two refusals must not read alike: one is "fix your
            # pattern", the other is "wait, the application is not ready".
            $d.Reason | Should -Not -BeLike '*no BUTTON matching*'
        }

        It 'REFUSES a control whose style word says CheckBox, and permits it with -Force' {
            # W2, the half the style word CAN answer. Measured 2026-08-28: a
            # FlatStyle=System CheckBox reports BS_TYPE=5, separable from a
            # pushbutton's 0 or 1.
            $r = Invoke-SwdDialogButton -DialogHandle $script:Modal.Handle `
                    -ExpectLike '*more than 60 mn*' -ButtonLike 'SysDelete' -Confirm:$false
            $r.Candidates | Should -Be 1
            $r.ButtonType | Should -Be 5
            $r.Attempted  | Should -BeFalse
            $r.Reason     | Should -BeLike '*NOT a pushbutton*'

            $f = Invoke-SwdDialogButton -DialogHandle $script:Modal.Handle `
                    -ExpectLike '*more than 60 mn*' -ButtonLike 'SysDelete' -Force -WhatIf -Confirm:$false
            $f.WhatIf | Should -BeTrue
            $f.Reason | Should -Not -BeLike '*NOT a pushbutton*'
        }

        It 'ADMITS a WinForms checkbox and SAYS SO, because the style cannot separate them' {
            # The measured LIMIT of the guard above, asserted so that nobody
            # "fixes" it by refusing BS_OWNERDRAW - which would refuse every
            # WinForms button there is. Measured 2026-08-28: WinForms
            # FlatStyle=Standard Button, CheckBox and RadioButton ALL report
            # BS_TYPE=11, and SWD is built entirely from WindowsForms10.* .
            $r = Invoke-SwdDialogButton -DialogHandle $script:Modal.Handle `
                    -ExpectLike '*more than 60 mn*' -ButtonLike 'Delete this*' -WhatIf -Confirm:$false
            $r.Candidates    | Should -Be 1
            $r.ButtonType    | Should -Be 11
            $r.TypeAmbiguous | Should -BeTrue
            $r.WhatIf        | Should -BeTrue
        }
    }

    Context 'ShouldProcess - C1, the round-2 Critical reintroduced verbatim' {
        It 'DOES NOT CLICK during a -WhatIf rehearsal' {
            $before = (Get-ModalChild 'OK*').Text
            $r = Invoke-SwdDialogButton -DialogHandle $script:Modal.Handle `
                    -ExpectLike '*more than 60 mn*' -ButtonLike 'OK*' -WhatIf -Confirm:$false
            Start-Sleep -Milliseconds 400
            (Get-ModalChild 'OK*').Text | Should -BeExactly $before
            $r.WhatIf    | Should -BeTrue
            $r.Attempted | Should -BeFalse
            $r.Sent      | Should -BeFalse
            # A rehearsal still reports what it FOUND - that is its whole value,
            # and why the gate sits after the reads rather than before them.
            $r.Matched      | Should -BeTrue
            $r.ButtonHandle | Should -Not -BeNullOrEmpty
        }

        It 'DOES NOT CLICK when WhatIfPreference is inherited from a caller' {
            # THE ACTUAL DEFECT. A scan driver declares SupportsShouldProcess and
            # is run with -WhatIf; every advanced function it calls inherits
            # $WhatIfPreference. A SIMPLE function silently does not - so the
            # rehearsal suppressed every numeric write and then answered the
            # application's confirmation dialogs for real.
            $before = (Get-ModalChild 'OK*').Text
            $WhatIfPreference = $true
            try {
                $r = Invoke-SwdDialogButton -DialogHandle $script:Modal.Handle `
                        -ExpectLike '*more than 60 mn*' -ButtonLike 'OK*' -Confirm:$false
            } finally { $WhatIfPreference = $false }
            Start-Sleep -Milliseconds 400
            (Get-ModalChild 'OK*').Text | Should -BeExactly $before
            $r.WhatIf    | Should -BeTrue
            $r.Attempted | Should -BeFalse
            $r.Sent      | Should -BeFalse
        }
    }

    Context 'C2 and W1 - the enumerate-then-click window, made deterministic' {
        # Get-SwdDialogControl is shadowed inside each test below, the same seam
        # trick the suite already uses on Get-SwdProcess, and defined INSIDE the
        # It so it is unambiguously on the dynamic scope chain the library
        # resolves against. The dialog handle stays REAL, so the ownership check
        # and the title read are untouched.

        It 'C2: reports Attempted=$false when the button stopped being a window' {
            # THE INTAKE EVIDENCE, deterministic. Against a stale handle the old
            # code returned Matched=True Clicked=True Sent=False LastError=1400 -
            # a click that never happened, reported as one that did.
            $dead = New-Object System.Windows.Forms.Form
            $deadH = [int64]$dead.Handle
            $dead.Dispose()
            function Get-SwdDialogControl { param($Handle, $TimeoutMs, $DeadlineMs)
                New-FakeRow -Handle $deadH }
            $r = Invoke-SwdDialogButton -DialogHandle $script:Modal.Handle `
                    -ExpectLike '*SWDTESTS-MODAL*' -ButtonLike 'OK' -Confirm:$false
            $r.Matched   | Should -BeTrue
            $r.Attempted | Should -BeFalse
            $r.Sent      | Should -BeFalse
            $r.Reason    | Should -BeLike '*stopped being a window*'
        }

        It 'C2: has no field named for an outcome it cannot observe' {
            function Get-SwdDialogControl { param($Handle, $TimeoutMs, $DeadlineMs)
                New-FakeRow -Handle $script:DeadHwnd }
            $r = Invoke-SwdDialogButton -DialogHandle $script:Modal.Handle `
                    -ExpectLike '*SWDTESTS-MODAL*' -ButtonLike 'OK' -Confirm:$false
            $names = $r.PSObject.Properties.Name
            $names | Should -Not -Contain 'Clicked'
            $names | Should -Contain 'Attempted'
            $names | Should -Contain 'Sent'
        }

        It 'W1: REFUSES a dialog whose body contains text it could not read' {
            # Measured on the old code: one child with TimedOut=$true and
            # Text=$null still produced Matched=True, Sent=True and a real click,
            # because $null joined into the body as an empty string.
            function Get-SwdDialogControl { param($Handle, $TimeoutMs, $DeadlineMs)
                @( (New-FakeRow -Handle 1 -Class 'Static' -TimedOut $true),
                   (New-FakeRow -Handle 2 -Text 'OK') ) }
            $r = Invoke-SwdDialogButton -DialogHandle $script:Modal.Handle `
                    -ExpectLike '*' -AnyText -ButtonLike 'OK' -Confirm:$false
            $r.FullyRead   | Should -BeFalse
            $r.UnreadCount | Should -Be 1
            $r.Matched     | Should -BeFalse
            $r.Attempted   | Should -BeFalse
            $r.Sent        | Should -BeFalse
            # and the refusal must NOT read as "the dialog said something else"
            $r.Reason | Should -BeLike '*NOT fully read*'
            $r.Reason | Should -Not -BeLike '*does not match*'
        }

        It 'W1: an empty -ExpectLike no longer waves through an unread dialog' {
            # '*' matches anything, including the '' a timed-out read used to
            # contribute. The read-coverage gate is what makes that safe now.
            function Get-SwdDialogControl { param($Handle, $TimeoutMs, $DeadlineMs)
                New-FakeRow -Handle 1 -Class 'Static' -TimedOut $true }
            (Invoke-SwdDialogButton -DialogHandle $script:Modal.Handle `
                -ExpectLike '*' -AnyText -ButtonLike '*' -Confirm:$false).Attempted | Should -BeFalse
        }

        It 'W1: a caller can tell "did not match" from "could not read"' {
            # The retry-versus-abort decision an unattended driver has to make.
            # Both used to be Matched=$false with nothing to separate them.
            function Get-SwdDialogControl { param($Handle, $TimeoutMs, $DeadlineMs)
                New-FakeRow -Handle 2 -Text 'OK' }
            $m = Invoke-SwdDialogButton -DialogHandle $script:Modal.Handle `
                    -ExpectLike '*definitely not this dialog*' -ButtonLike 'OK' -Confirm:$false
            $m.FullyRead   | Should -BeTrue
            $m.UnreadCount | Should -Be 0
            $m.Matched     | Should -BeFalse
            $m.Reason      | Should -BeLike '*does not match*'
        }

        It 'W1: counts a DEADLINE-skipped child as unread, not as empty text' {
            function Get-SwdDialogControl { param($Handle, $TimeoutMs, $DeadlineMs)
                New-FakeRow -Handle 3 -Class 'Static' -TimedOut $true -Skipped $true }
            $r = Invoke-SwdDialogButton -DialogHandle $script:Modal.Handle `
                    -ExpectLike '*' -AnyText -ButtonLike 'OK' -Confirm:$false
            $r.UnreadCount | Should -Be 1
            $r.FullyRead   | Should -BeFalse
            $r.Attempted   | Should -BeFalse
        }
    }

    Context 'C3 and W6 - transport, on a pump that really blocks' {
        It 'W6: -Post uses PostMessage, and a posted BM_CLICK really does actuate' {
            # The sibling documents -Post as REQUIRED for anything long-running,
            # and the button this function exists to press is the OK that starts a
            # ~31 minute scan. A transport that did not actuate the control would
            # be a worse trap than the one it fixes, so it is asserted, not
            # assumed.
            $before = (Get-ModalChild 'OK*').Text
            $r = Invoke-SwdDialogButton -DialogHandle $script:Modal.Handle `
                    -ExpectLike '*more than 60 mn*' -ButtonLike 'OK*' -Post -Confirm:$false
            $r.Method    | Should -Be 'PostMessage'
            $r.Attempted | Should -BeTrue
            $r.Sent      | Should -BeTrue
            # C1: Sent=$true here is a CONSTANT - PostMessage cannot fail against
            # a live window - so it is not evidence, and Observed says so.
            $r.Observed  | Should -Be 'queued'
            $r.Reason    | Should -BeLike '*QUEUED ONLY*'
            $r.Reason    | Should -Not -BeLike 'delivered*'
            Start-Sleep -Milliseconds 600
            (Get-ModalChild 'OK*').Text | Should -Not -Be $before
        }

        It 'C3: a click that LANDS can still report 1460, and Sent stays $false' {
            # THE MEASUREMENT BEHIND C3, reproduced inside the suite. SLOW blocks
            # the target's pump from inside its own click handler for 4 s - the
            # exact shape of SWD's scan button opening a modal. The send cannot be
            # acknowledged, so it times out at 1460, and the click landed anyway.
            #
            # It is also the only deterministic way to make Sent=$false here, so
            # it is what kills the mutation that forced Sent=$true.
            $before = (Get-ModalChild 'SLOW*').Text
            $r = Invoke-SwdDialogButton -DialogHandle $script:Modal.Handle `
                    -ExpectLike '*more than 60 mn*' -ButtonLike 'SLOW*' -TimeoutMs 1200 -Confirm:$false
            $r.Attempted | Should -BeTrue
            $r.Sent      | Should -BeFalse
            $r.LastError | Should -Be 1460
            $r.Observed  | Should -Be 'ambiguous'
            $r.Reason    | Should -BeLike '*AMBIGUOUS*'
            $r.Reason    | Should -Not -BeLike '*most likely*'

            # ... and now observe what the error code could not tell us. The click
            # DID land, which is exactly why 1460 may be read as neither failure
            # nor success.
            Start-Sleep -Seconds 6
            (Get-ModalChild 'SLOW*').Text | Should -Not -Be $before
        }

        It 'C3/S7: Wait-SwdDialogGone answers in both directions' {
            # Format-SwdSendError says the ambiguity can only be settled by
            # observing. This is that observation, so it has to be right both ways.
            Wait-SwdDialogGone -Handle $script:Modal.Handle -TimeoutMs 600 | Should -BeFalse
            Wait-SwdDialogGone -Handle $script:DeadHwnd -TimeoutMs 600 | Should -BeTrue
        }

        It 'C3/S7: observes a dialog actually being dismissed' {
            # The full loop the scan driver will run: answer the modal, then prove
            # it went, rather than trusting a transport code that cannot say.
            $r = Invoke-SwdDialogButton -DialogHandle $script:Modal.Handle `
                    -ExpectLike '*more than 60 mn*' -ButtonLike 'Cancel*' -Post -Confirm:$false
            $r.Attempted | Should -BeTrue
            Wait-SwdDialogGone -Handle $script:Modal.Handle -TimeoutMs 8000 | Should -BeTrue
        }
    }
}
