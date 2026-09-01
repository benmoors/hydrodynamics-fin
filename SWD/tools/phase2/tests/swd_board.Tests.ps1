<#
    Pester 6.x. Runs with SWD CLOSED.

    Closes SQA finding 14: swd_board.ps1 had no test file at all, in the one file that
    can reach SWD's File menu and therefore Save.

    UIA element trees cannot be faked wholesale offline, so the two traversal functions
    (Get-SwdBoardList, Get-SwdMenuItem) and Get-SwdUiaWindow are out of reach and are
    listed as untested at the bottom rather than papered over. Everything that decides
    whether to ACT is covered: the allowlist gate, the caption parser, the ambiguity
    refusals, and Select-SwdBoard's success verdict.
#>

BeforeAll {
    $script:Phase2 = Split-Path -Parent $PSScriptRoot
    . (Join-Path $script:Phase2 'swd_msg.ps1')
    . (Join-Path $script:Phase2 'swd_board.ps1')

    function New-MenuItem {
        param($Name, $Invokable = $true, $Enabled = $true)
        [pscustomobject]@{
            Name = $Name; Element = $null; Invokable = $Invokable; Enabled = $Enabled
        }
    }

    # Get-SwdBoardList and Get-SwdMenuItem both end `return ,$out`. A stub that STREAMS
    # its items is MORE FORGIVING than the function it stands in for, and that is
    # exactly what hid a Critical for two SQA rounds: both were piped straight into
    # Where-Object, so $_ was the whole array and @(f).Count returned 1 for a
    # 2-element result. Every stub below reproduces the comma-wrapped shape.
    function New-Wrapped { param([object[]]$Items) return ,([object[]]$Items) }

    function New-BoardItem {
        param($Name, $Selectable = $true)
        $element = New-Object psobject
        $element | Add-Member -MemberType ScriptMethod -Name TryGetCurrentPattern -Value {
            param($Pattern, $Sink)
            $selector = New-Object psobject
            $selector | Add-Member -MemberType ScriptMethod -Name Select -Value { } -PassThru | Out-Null
            $Sink.Value = $selector
            return $true
        }
        [pscustomobject]@{
            Name = $Name; Element = $element; Selectable = $Selectable; Expandable = $false
        }
    }

    function New-Caption {
        param($Board = 'other', $LengthMm = 1800.0, $Parsed = $true, $Title = 'a title')
        [pscustomobject]@{
            Board = $Board; LengthMm = $LengthMm; Title = $Title
            Parsed = $Parsed; ReadError = $null
        }
    }
}

Describe 'Get-SwdLoadedBoard - the board-identity oracle' {

    It 'parses a real caption' {
        Mock Get-SwdWindowTitle {
            'FYN Shaper Wave Dynamics  <Board: default_shortboard(1800.0mm)>  <no Wave>  <Surfer: Surfer Pro(80Kg)>'
        }
        $r = Get-SwdLoadedBoard
        $r.Parsed   | Should -BeTrue
        $r.Board    | Should -Be 'default_shortboard'
        $r.LengthMm | Should -Be 1800.0
    }

    It 'keeps a board name containing underscores and digits intact' {
        Mock Get-SwdWindowTitle {
            'FYN Shaper Wave Dynamics  <Board: 2003_Taylor_Knox_channel_island_Copy_1(2133.6mm)>  <no Wave>'
        }
        (Get-SwdLoadedBoard).Board | Should -Be '2003_Taylor_Knox_channel_island_Copy_1'
    }

    It 'does not confuse a board with its _Copy_1 sibling' {
        # Separate library hulls with different measured geometry, 24.0 L vs 35.2 L.
        Mock Get-SwdWindowTitle { 'FYN Shaper Wave Dynamics  <Board: default_shortboard_Copy_1(1800.0mm)>' }
        (Get-SwdLoadedBoard).Board | Should -Not -Be 'default_shortboard'
        (Get-SwdLoadedBoard).Board | Should -Be 'default_shortboard_Copy_1'
    }

    It 'reports Parsed=$false rather than throwing on a malformed length' {
        # SQA W7: [\d.]+ admits '1.2.3' and the old [double] cast threw INSIDE the poll
        # loop, after Select() had already acted - abandoning the caller with the app
        # changed and no result object.
        Mock Get-SwdWindowTitle { 'FYN Shaper Wave Dynamics  <Board: weird(1.2.3mm)>' }
        { Get-SwdLoadedBoard } | Should -Not -Throw
        (Get-SwdLoadedBoard).Parsed   | Should -BeFalse
        (Get-SwdLoadedBoard).LengthMm | Should -BeNullOrEmpty
    }

    It 'distinguishes a caption that did not answer from one that answered nothing' {
        Mock Get-SwdWindowTitle { $null }
        (Get-SwdLoadedBoard).Parsed | Should -BeFalse
        Mock Get-SwdWindowTitle { '' }
        (Get-SwdLoadedBoard).Parsed | Should -BeFalse
    }

    It 'reports Parsed=$false when the caption has no Board segment' {
        Mock Get-SwdWindowTitle { 'Starting HydroScan' }
        (Get-SwdLoadedBoard).Parsed | Should -BeFalse
    }
}

Describe 'Read-SwdLoadedBoard - never throws past the point of no return' {

    It 'returns a record carrying ReadError instead of throwing' {
        # Past Select() nothing may abort: the app has been changed and the caller must
        # still get a result object. Twin of Read-SwdGeometryState. Note it returns a
        # POPULATED record rather than $null, so the caller learns WHY the read failed
        # and not merely that it did.
        Mock Get-SwdWindowTitle { throw 'SWD is not running' }
        { Read-SwdLoadedBoard } | Should -Not -Throw
        $r = Read-SwdLoadedBoard
        $r.Parsed    | Should -BeFalse
        $r.ReadError | Should -BeLike '*not running*'
        $r.Board     | Should -BeNullOrEmpty
    }
}

Describe 'Invoke-SwdMenuItem - the default-deny gate' {

    BeforeEach {
        Mock Get-SwdMenuItem {
            New-Wrapped @((New-MenuItem 'Save'), (New-MenuItem 'Save As...'), (New-MenuItem 'Open'))
        }
    }

    It 'refuses everything when -Allow is not supplied' {
        # THE finding. Pre-fix this invoked Save, measured three ways.
        { Invoke-SwdMenuItem -Name 'Save' -Confirm:$false } |
            Should -Throw -ExpectedMessage '*-Allow*'
    }

    It 'refuses a name that is not on the allowlist' {
        { Invoke-SwdMenuItem -Name 'Save' -Allow 'Open' -Confirm:$false } |
            Should -Throw -ExpectedMessage '*-Allow*'
    }

    It 'refuses an empty allowlist explicitly passed' {
        { Invoke-SwdMenuItem -Name 'Save' -Allow @() -Confirm:$false } |
            Should -Throw -ExpectedMessage '*-Allow*'
    }

    It 'does not accept a wildcard as an allowlist entry' {
        { Invoke-SwdMenuItem -Name 'Save' -Allow '*' -Confirm:$false } |
            Should -Throw -ExpectedMessage '*-Allow*'
    }

    It 'still refuses when ConfirmImpact is bypassed' {
        $ConfirmPreference = 'None'
        { Invoke-SwdMenuItem -Name 'Save' } | Should -Throw -ExpectedMessage '*-Allow*'
    }

    It 'refuses an invisible-character homoglyph of an allowed name' {
        # Linguistic -eq treats U+00AD (soft hyphen) and U+200D as equal to nothing, so
        # gate and selector disagreed and that WAS the bypass. Ordinal comparison closes
        # it: the gate and the selector must accept exactly the same set.
        # The message matters. A bare -Throw passes for the WRONG REASON: under a
        # linguistic selector the item IS found and the call then dies on the stub's
        # null Element, so the mutant survives. Asserting 'no menu item' pins that the
        # SELECTOR refused, which is the property under test.
        $softHyphen = "Sa$([char]0x00AD)ve"
        { Invoke-SwdMenuItem -Name $softHyphen -Allow $softHyphen -Confirm:$false } |
            Should -Throw -ExpectedMessage '*no menu item*'
    }

    It 'refuses a zero-width-joiner homoglyph too' {
        $zwj = "Sa$([char]0x200D)ve"
        { Invoke-SwdMenuItem -Name $zwj -Allow $zwj -Confirm:$false } |
            Should -Throw -ExpectedMessage '*no menu item*'
    }

    It 'refuses a homoglyph NAME against a plain allowlist entry' {
        # This is the one that pins THE GATE rather than the selector. Passing the same
        # string to both -Name and -Allow cannot distinguish ordinal from linguistic,
        # because either comparison admits a string against itself - measured: that
        # mutant survived. Here -Allow holds the plain 'Save' while -Name carries the
        # homoglyph, so a linguistic gate ADMITS and an ordinal gate REFUSES.
        $softHyphen = "Sa$([char]0x00AD)ve"
        { Invoke-SwdMenuItem -Name $softHyphen -Allow 'Save' -Confirm:$false } |
            Should -Throw -ExpectedMessage '*-Allow*'
        Should -Invoke Get-SwdMenuItem -Times 0
    }

    It 'refuses a case-and-homoglyph combination against a plain allowlist entry' {
        $mixed = "SA$([char]0x200D)VE"
        { Invoke-SwdMenuItem -Name $mixed -Allow 'Save' -Confirm:$false } |
            Should -Throw -ExpectedMessage '*-Allow*'
    }

    It 'refuses positionally-supplied arguments' {
        # PositionalBinding was on, so `Invoke-SwdMenuItem 'Save' 'Save'` bound -Allow
        # positionally and reached Invoke().
        { Invoke-SwdMenuItem 'Save' 'Save' } | Should -Throw
    }

    It 'refuses an unknown item name' {
        { Invoke-SwdMenuItem -Name 'Explode' -Allow 'Explode' -Confirm:$false } |
            Should -Throw -ExpectedMessage '*no menu item*'
    }

    It 'refuses to guess between duplicate names' {
        Mock Get-SwdMenuItem { New-Wrapped @((New-MenuItem 'Save'), (New-MenuItem 'Save')) }
        { Invoke-SwdMenuItem -Name 'Save' -Allow 'Save' -Confirm:$false } |
            Should -Throw -ExpectedMessage '*refusing to guess*'
    }

    It 'refuses an item exposing no InvokePattern' {
        Mock Get-SwdMenuItem { New-Wrapped @((New-MenuItem 'Save' -Invokable $false)) }
        { Invoke-SwdMenuItem -Name 'Save' -Allow 'Save' -Confirm:$false } |
            Should -Throw -ExpectedMessage '*InvokePattern*'
    }

    It 'refuses a disabled item, with no override available' {
        # -Force was DELETED this round. InvokePattern.Invoke() is specified to raise
        # ElementNotEnabledException on a disabled element, so the switch could only ever
        # turn a clean refusal into an exception on the one path that reaches Save.
        Mock Get-SwdMenuItem { New-Wrapped @((New-MenuItem 'Save' -Enabled $false)) }
        { Invoke-SwdMenuItem -Name 'Save' -Allow 'Save' -Confirm:$false } |
            Should -Throw -ExpectedMessage '*disabled*'
        (Get-Command Invoke-SwdMenuItem).Parameters.ContainsKey('Force') | Should -BeFalse
    }

    It 'does not enumerate the menu at all before refusing' {
        # Default-deny must fire before anything is touched.
        { Invoke-SwdMenuItem -Name 'Save' -Confirm:$false } | Should -Throw
        Should -Invoke Get-SwdMenuItem -Times 0
    }

    It 'does not invoke under -WhatIf' {
        (Invoke-SwdMenuItem -Name 'Save' -Allow 'Save' -WhatIf).Invoked | Should -BeFalse
    }

    It 'supports -WhatIf, so a rehearsal cannot invoke Save for real' {
        (Get-Command Invoke-SwdMenuItem).Parameters.ContainsKey('WhatIf') | Should -BeTrue
    }
}

Describe 'The comma-return idiom, on real functions' {

    It 'preserves an empty result from a real comma-returning function' {
        # Previously this asserted against local helpers, which proves the language
        # works rather than that the code uses it. Get-SwdDescendant is a real
        # comma-returning function reachable without UIA.
        . (Join-Path (Split-Path -Parent $PSScriptRoot) 'swd_geometry.ps1')
        $leaf = Get-SwdDescendant -Handle 1 -Controls @(
            [pscustomobject]@{ Handle=1; Class='X'; Parent=0; Text=''; Enabled=$true; Visible=$true })
        $leaf.Count | Should -Be 0
    }

    It 'shows why a comma-returned array must not be piped straight into Where-Object' {
        # The third Critical, found during round 3 and missed by both SQA rounds. The
        # wrapper survives the pipe, so $_ is the WHOLE ARRAY and the count collapses
        # to 1. It read as working only because `array -eq 'x'` is a filter whose
        # non-empty result is truthy. Assign first, then filter.
        function script:Wrapped { $o = @('a', 'b'); return ,$o }
        @(Wrapped | Where-Object { $_ -eq 'a' }).Count | Should -Be 1   # the trap
        $assigned = Wrapped
        $assigned.Count | Should -Be 2                                  # the truth
        @($assigned | Where-Object { $_ -eq 'a' }).Count | Should -Be 1
    }

    It 'confirms an unnamed item is dropped by a specific -Like' {
        # SQA W10: `if ($name -and $name -notlike $Like)` KEPT every unnamed item, so a
        # '*Save*' capability probe returned non-empty on a build with no Save item.
        ('' -notlike '*Save*')    | Should -BeTrue    # so `continue` fires: dropped
        ('' -notlike '*')         | Should -BeFalse   # so the default still lists it
        ($null -notlike '*Save*') | Should -BeTrue
    }
}

Describe 'Select-SwdBoard - refusals before acting' {

    BeforeEach {
        Mock Get-SwdUiaWindow { $null }
        Mock Get-SwdLoadedBoard { New-Caption }
    }

    It 'refuses a board name that is not in the tree' {
        Mock Get-SwdBoardList { New-Wrapped @((New-BoardItem 'A')) }
        { Select-SwdBoard -Name 'Missing' -Confirm:$false } |
            Should -Throw -ExpectedMessage '*no tree item*'
    }

    It 'refuses to guess between duplicate tree items' {
        Mock Get-SwdBoardList { New-Wrapped @((New-BoardItem 'A'), (New-BoardItem 'A')) }
        { Select-SwdBoard -Name 'A' -Confirm:$false } |
            Should -Throw -ExpectedMessage '*refusing to guess*'
    }

    It 'refuses a node with no SelectionItemPattern instead of clicking a coordinate' {
        Mock Get-SwdBoardList { New-Wrapped @((New-BoardItem 'A' -Selectable $false)) }
        { Select-SwdBoard -Name 'A' -Confirm:$false } |
            Should -Throw -ExpectedMessage '*SelectionItemPattern*'
    }

    It 'refuses an invisible-character homoglyph of a real board name' {
        # Measured on 5.1: 'Sa<U+00AD>ve' -eq 'Save' is TRUE, and so is -contains.
        # A linguistic selector would therefore load a DIFFERENT board than the caller
        # named, silently - the "scans variant n while reporting variant m" failure.
        Mock Get-SwdBoardList { New-Wrapped @((New-BoardItem 'default_shortboard')) }
        $homoglyph = "default_short$([char]0x00AD)board"
        { Select-SwdBoard -Name $homoglyph -Confirm:$false } |
            Should -Throw -ExpectedMessage '*no tree item*'
    }

    It 'refuses a board name differing only by Unicode normalisation form' {
        Mock Get-SwdBoardList { New-Wrapped @((New-BoardItem 'default_shortboard')) }
        $nfd = 'default_shortboard'.Normalize([Text.NormalizationForm]::FormD) + [char]0x200D
        { Select-SwdBoard -Name $nfd -Confirm:$false } |
            Should -Throw -ExpectedMessage '*no tree item*'
    }

    It 'supports -WhatIf' {
        (Get-Command Select-SwdBoard).Parameters.ContainsKey('WhatIf') | Should -BeTrue
    }

    It 'rejects an invalid -PollMs BEFORE Select() can act' {
        # SQA round 3 W1. Unvalidated, -PollMs -1 threw out of Start-Sleep inside the
        # poll loop - after Select() had already acted - abandoning the caller with SWD
        # changed and no result object. The guard existed in the sibling and had not
        # been copied here.
        Mock Get-SwdBoardList { New-Wrapped @((New-BoardItem 'A')) }
        { Select-SwdBoard -Name 'A' -PollMs -1 -Confirm:$false } |
            Should -Throw -ExpectedMessage '*PollMs must be 1 or more*'
        Should -Invoke Get-SwdBoardList -Times 0
    }

    It 'rejects a negative -TimeoutMs before acting' {
        Mock Get-SwdBoardList { New-Wrapped @((New-BoardItem 'A')) }
        { Select-SwdBoard -Name 'A' -TimeoutMs -1 -Confirm:$false } |
            Should -Throw -ExpectedMessage '*TimeoutMs must be 0 or more*'
        Should -Invoke Get-SwdBoardList -Times 0
    }
}

Describe 'Get-SwdWindowTitle - what is reachable without a live SWD' {

    # SQA round 3 W2. This function had ZERO coverage and was missing from this file's
    # own "NOT COVERED" list - a false completeness claim about the one function round 2
    # rewrote to fix a Critical. Deleting all four of its guards left the suite green.
    #
    # Its body calls the STATIC [SwdWin]::TopLevelForPid, which cannot be mocked, so its
    # sweep and deadline behaviour genuinely are out of reach offline. What IS reachable
    # is its contract, and the gap is now declared at the foot of this file instead of
    # being implied away.

    It 'exposes both bounding knobs, so a caller can actually limit the sweep' {
        # The bound is the whole point of the round-2 rewrite: pre-fix this swept every
        # top-level window of the pid with no aggregate deadline, measured at 21,582 ms
        # on a pid owning 53 windows, and no caller could reach the knob.
        $p = (Get-Command Get-SwdWindowTitle).Parameters
        $p.ContainsKey('TimeoutMs')  | Should -BeTrue
        $p.ContainsKey('DeadlineMs') | Should -BeTrue
    }

    It 'threads both knobs through Get-SwdLoadedBoard, which used to take none' {
        # Round 2's defect was not only the missing deadline: Get-SwdLoadedBoard was
        # declared param(), so Select-SwdBoard -TimeoutMs could not reach the read at all
        # and it always ran at its own default.
        $p = (Get-Command Get-SwdLoadedBoard).Parameters
        $p.ContainsKey('TimeoutMs')  | Should -BeTrue
        $p.ContainsKey('DeadlineMs') | Should -BeTrue
    }

    It 'propagates a process fault, which is why the Read- wrapper exists' {
        # Get- may throw; Read- may not. The pairing is the discipline, and a test that
        # only checked Read- would not show that the two genuinely differ.
        Mock Get-SwdProcess { throw 'SWD is not running' }
        { Get-SwdWindowTitle }  | Should -Throw
        { Read-SwdLoadedBoard } | Should -Not -Throw
    }
}

Describe 'Select-SwdBoard - the success verdict' {

    BeforeEach {
        Mock Get-SwdUiaWindow { $null }
        Mock Get-SwdBoardList { New-Wrapped @((New-BoardItem 'target')) }
    }

    It 'reports Selected only when the CAPTION confirms the board loaded' {
        # 'scans variant n while reporting variant m' is the worst failure this file has
        # available, and this verdict previously had no test at all: mutants setting
        # Selected=$true survived all 60 tests.
        Mock Get-SwdLoadedBoard { New-Caption -Board 'other' }
        Mock Read-SwdLoadedBoard { New-Caption -Board 'target' -LengthMm 2000.0 }
        $r = Select-SwdBoard -Name 'target' -Confirm:$false -TimeoutMs 3000 -PollMs 1
        $r.Selected      | Should -BeTrue
        $r.AlreadyLoaded | Should -BeFalse
        $r.Reason        | Should -Be 'ok'
    }

    It 'does NOT report Selected when the caption never names the board' {
        Mock Get-SwdLoadedBoard { New-Caption -Board 'other' }
        Mock Read-SwdLoadedBoard { New-Caption -Board 'other' }
        $r = Select-SwdBoard -Name 'target' -Confirm:$false -TimeoutMs 30 -PollMs 1
        $r.Selected | Should -BeFalse
        $r.Reason   | Should -Not -Be 'ok'
    }

    It 'flags a board that was ALREADY loaded, which is no evidence Select() works' {
        # Same class as Set-SwdGeometry's already-at-target: a run that started where it
        # meant to finish establishes nothing about the mechanism.
        Mock Get-SwdLoadedBoard { New-Caption -Board 'target' -LengthMm 2000.0 }
        Mock Read-SwdLoadedBoard { New-Caption -Board 'target' -LengthMm 2000.0 }
        (Select-SwdBoard -Name 'target' -Confirm:$false -TimeoutMs 30 -PollMs 1).AlreadyLoaded |
            Should -BeTrue
    }

    It 'does not accept a caption whose board name differs by an invisible character' {
        # The CAPTION comparison, distinct from the tree selector tested above. A
        # linguistic compare here would report Selected=$true for a board whose real
        # name differs from the one requested - "scans variant n, reports variant m"
        # in its purest form. Measured: this mutant survived until this test existed.
        Mock Get-SwdLoadedBoard { New-Caption -Board 'other' }
        Mock Read-SwdLoadedBoard { New-Caption -Board "tar$([char]0x00AD)get" -LengthMm 2000.0 }
        $r = Select-SwdBoard -Name 'target' -Confirm:$false -TimeoutMs 30 -PollMs 1
        $r.Selected | Should -BeFalse
        $r.Reason   | Should -Not -Be 'ok'
    }

    It 'does not report Selected when the caption cannot be read at all' {
        Mock Get-SwdLoadedBoard { New-Caption -Board 'other' }
        Mock Read-SwdLoadedBoard {
            [pscustomobject]@{ Board=$null; LengthMm=$null; Title=$null
                               Parsed=$false; ReadError='did not answer' }
        }
        $r = Select-SwdBoard -Name 'target' -Confirm:$false -TimeoutMs 30 -PollMs 1
        $r.Selected | Should -BeFalse
        $r.Reason   | Should -Not -Be 'ok'
    }

    It 'returns a result object rather than throwing when the read fails after Select()' {
        Mock Get-SwdLoadedBoard { New-Caption -Board 'other' }
        Mock Read-SwdLoadedBoard {
            [pscustomobject]@{ Board=$null; LengthMm=$null; Title=$null
                               Parsed=$false; ReadError='did not answer' }
        }
        { Select-SwdBoard -Name 'target' -Confirm:$false -TimeoutMs 30 -PollMs 1 } |
            Should -Not -Throw
    }
}

<#
    NOT COVERED HERE, and stated rather than implied.

    This list was itself an SQA finding (round 3, W2): it omitted Get-SwdWindowTitle
    while reading as complete, and a reader would have concluded that the function round
    2 rewrote to fix a Critical was tested. It was not. Anything added to this file that
    cannot be reached offline belongs here on the same commit.

    Needs a live UIA tree:
    * Get-SwdUiaWindow's pid + title-pattern resolution and its two-match refusal.
    * Get-SwdBoardList / Get-SwdMenuItem traversal and pattern probing.
    * Whether SelectionItemPattern.Select() actually loads a board, and whether a
      MenuItem named 'Save' is enumerable without expanding File first.
    * The re-identification at Invoke-SwdMenuItem, which compares the element's live
      .Current.Name against the requested name. Reaching it needs a fake element chain
      exposing Current.Name plus an InvokePattern. Its mutant is a KNOWN SURVIVOR.

    Needs a real SWD process:
    * Get-SwdWindowTitle's window sweep, its per-read timeout and its aggregate
      deadline. The body calls the STATIC [SwdWin]::TopLevelForPid, which cannot be
      mocked, so only its parameter contract is asserted above. Note that -DeadlineMs 0
      silently means UNBOUNDED rather than "no time at all" - an open Suggestion.

    Scope note: the phase2 directory reports ~340 passing tests, but only the three
    geometry/board files can touch these targets. swd_msg.Tests.ps1 and
    swd_diagnose.Tests.ps1 never dot-source either file and are structurally incapable
    of killing a mutant here. Quote the subset, not the directory total.

    Live items are tier 2b.5 and 2b.6 in TODO.md.
#>
