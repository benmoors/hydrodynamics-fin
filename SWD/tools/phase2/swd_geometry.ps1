<#
.SYNOPSIS
    Read and change SWD's Shape Room geometry, verified against three oracles.

.DESCRIPTION
    The Board Length / Board Width / Board Volume panel is fully mapped in all three
    captured control maps, with a stable parent-group structure. But HANDLES ARE
    SESSION-SCOPED - every handle in every document in this repository is stale. So
    nothing here is addressed by a literal handle. Controls are resolved structurally
    at run time:

        SysTabControl32 -> Window.8 'SizeConfig'
                             |- Window.8 'Board Length'   -> enabled EDIT + 'Apply Length'
                             |- Window.8 'Board Width'    -> enabled EDIT + 'Apply Width'
                             |- Window.8 'Board Volume: N liters'
                             |    -> (NumericUpDown container) -> EDIT + 'Apply Volume'
                             \- STATIC 'Configuration: ...'   <- the read-back oracle

    THE APPLY BUTTONS HAVE NEVER BEEN MEASURED. This is the single most important fact
    about this file. The repository contains one claim that a board was homothetically
    scaled 1800 -> 2000 mm through this route; that claim was RETRACTED the same day it
    was written, because after the scan the length field read 1800 via WM_GETTEXT and so
    did the window title (SWD/data/coverage.md). project-io-spec.md and SWD/TODO.md still
    repeat the withdrawn version. No click has ever been driven against Apply Length,
    Apply Width or Apply Volume. Their coupling - whether Apply Length also moves Width
    and Volume, whether Apply Volume really changes thickness alone - is a HYPOTHESIS.

    Hence Set-SwdGeometry reports what actually moved on every dimension rather than
    what was asked for, and never claims an apply succeeded because the click was sent.
    Precedent: 'Apply situation' was clicked on 2026-08-31 and returned Sent=True,
    Observed=handled, LastError=0 with every caption byte-identical either side.
    Transport was demonstrated; actuation was not.

    THE HOMOTHETY CHECKBOX IS NEVER TOUCHED. It read Enabled=False in all three captures,
    and its state is unreadable: BM_GETCHECK is blind on FlatStyle=Standard WinForms
    checkboxes, which is what SWD ships. It is reported as 'unknown' - not as unchecked.

.NOTES
    Windows PowerShell 5.1 (Desktop). Dot-source; this file sends nothing to SWD on
    load. It DOES dot-source swd_msg.ps1 from $PSScriptRoot when that layer is not
    already present, which brings Set-StrictMode into the caller's scope.
#>

Set-StrictMode -Version Latest

if ($PSVersionTable.PSEdition -ne 'Desktop') {
    throw 'Windows PowerShell 5.1 required (matches the rest of the phase2 tooling).'
}

$script:SwdGeomRoot = $PSScriptRoot
if (-not $script:SwdGeomRoot) {
    $script:SwdGeomRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
}

# Every swd_msg.ps1 function this file calls. Most are paired with a parameter that
# only the HARDENED version of that function has; Get-SwdProcess is mapped to $null
# because it has no such parameter, so for that one entry this is a PRESENCE CHECK
# ONLY and the comment used to overstate what it does.
#
# Checking ONE name was not enough on two counts. Five more were called without ever
# being checked, so a partial load failed at the call site instead of at the door. And
# `Get-Command <name>` answers for an Application, an alias or a stub just as readily
# as for the real function - the realistic trigger being an operator who dot-sourced an
# older swd_msg.ps1 out of a backup snapshot. The parameter probe is what separates the
# hardened layer from a same-named ancestor: Invoke-SwdButton without -WhatIf is the
# pre-round-2 version whose rehearsal PRESSED THE BUTTONS FOR REAL.
#
# What it still cannot detect: a swd_msg.ps1 that carries the right signatures and the
# wrong bodies. There is no version constant in that file to check against.
$script:GeomRequiredMsgApi = [ordered]@{
    'Get-SwdControl'    = 'DeadlineMs'
    'Get-SwdText'       = 'TimeoutMs'
    'Get-SwdProcess'    = $null
    'Test-SwdHandle'    = 'Handle'
    'ConvertTo-SwdNumber' = 'Text'
    'Set-SwdNumeric'    = 'SettleMs'
    'Invoke-SwdButton'  = 'WhatIf'
}

function Test-SwdGeometryMsgApi {
    <#
    .SYNOPSIS
        Names of $script:GeomRequiredMsgApi entries that are absent or not hardened.
    #>
    [CmdletBinding()]
    param()
    $bad = @()
    foreach ($name in $script:GeomRequiredMsgApi.Keys) {
        $cmd = Get-Command -Name $name -CommandType Function -ErrorAction SilentlyContinue
        if (-not $cmd) { $bad += "$name (not loaded as a function)"; continue }
        $param = $script:GeomRequiredMsgApi[$name]
        if ($param -and -not $cmd.Parameters.ContainsKey($param)) {
            $bad += "$name (loaded, but has no -$param - this is an OLD swd_msg.ps1)"
        }
    }
    return ,$bad
}

if ((Test-SwdGeometryMsgApi).Count -gt 0) {
    $msg = Join-Path $script:SwdGeomRoot 'swd_msg.ps1'
    if (-not (Test-Path -LiteralPath $msg)) {
        throw "swd_msg.ps1 not found beside this script at '$msg'."
    }
    . $msg
    $stillBad = Test-SwdGeometryMsgApi
    if ($stillBad.Count -gt 0) {
        throw ("swd_msg.ps1 was loaded from '$msg' but does not provide the hardened API " +
               "this file requires: $($stillBad -join '; ').")
    }
}

# Group captions. Volume's caption embeds the current value ('Board Volume: 26.8 liters')
# so it must be matched as a prefix, never compared for equality.
#
# Tolerance is ABSOLUTE, in the axis's own unit, and is HALF THE CONFIGURATION LABEL'S
# OWN PRINTING QUANTUM - the label prints whole millimetres ('Length 2134 mm') and
# hundredths of a litre ('Volume 26.85 Liters'). It was a RELATIVE 0.02, which is
# +/-42.7 mm on a 2134 mm board: wider than most changes worth making, so any request
# under 2% was unfalsifiable and came back at-target whatever happened.
$script:GeometryAxes = @{
    Length = @{ Group = 'Board Length'; Apply = 'Apply Length'; Unit = 'mm';     Tolerance = 0.5   }
    Width  = @{ Group = 'Board Width';  Apply = 'Apply Width';  Unit = 'mm';     Tolerance = 0.5   }
    Volume = @{ Group = 'Board Volume'; Apply = 'Apply Volume'; Unit = 'litres'; Tolerance = 0.005 }
}

# The Configuration label's fields, in one place: ConvertFrom-SwdConfigurationText
# builds them and Set-SwdGeometry diffs them, and two hand-maintained copies of the
# same list drift into a delta table that silently stops reporting a dimension.
$script:ConfigFields = @('VolumeL', 'DisplacementL', 'LengthMm', 'WidthMm', 'ThickMm',
                         'LengthOverWidth', 'WidthOverThick', 'LengthOverThick')

# Same literal as swd_board.ps1's $script:MainTitleLike, duplicated rather than shared:
# swd_msg.ps1 is the only file both import and it is frozen, while swd_board.ps1 loads
# UIAutomationClient, which this file must never require.
$script:GeomMainTitleLike = 'FYN Shaper Wave Dynamics*'


function Get-SwdDescendant {
    <#
    .SYNOPSIS
        All controls beneath one handle, from a flat control list.
    .DESCRIPTION
        The Volume EDIT sits two hops down inside a NumericUpDown container, so a
        direct-children search finds the group and misses the box. Walks breadth-first
        with a visited set: the control list is built from live enumeration and a cycle
        would otherwise hang the caller rather than fail.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Controls,
        [Parameter(Mandatory)][int64] $Handle
    )

    $byParent = @{}
    foreach ($c in $Controls) {
        $key = [int64]$c.Parent
        if (-not $byParent.ContainsKey($key)) { $byParent[$key] = @() }
        $byParent[$key] += $c
    }

    $out = @()
    $seen = New-Object 'System.Collections.Generic.HashSet[int64]'
    $queue = New-Object System.Collections.Queue
    [void]$queue.Enqueue($Handle)
    [void]$seen.Add($Handle)

    while ($queue.Count -gt 0) {
        $current = [int64]$queue.Dequeue()
        if (-not $byParent.ContainsKey($current)) { continue }
        foreach ($child in $byParent[$current]) {
            $h = [int64]$child.Handle
            if (-not $seen.Add($h)) { continue }
            $out += $child
            [void]$queue.Enqueue($h)
        }
    }
    # Comma operator: PowerShell unrolls a returned array, so an EMPTY one
    # arrives at the caller as $null and .Count throws under StrictMode. Found by
    # swd_geometry.Tests.ps1 'returns nothing for a leaf'.
    return ,$out
}


function Resolve-SwdGeometryControl {
    <#
    .SYNOPSIS
        Locate the geometry panel's boxes, Apply buttons and Configuration label.
    .DESCRIPTION
        Structural resolution, run fresh every time. Never trusts a stored handle.
    .OUTPUTS
        PSCustomObject with Length/Width/Volume (each Edit + Apply handles and
        ApplyEnabled), ConfigurationHandle, and Missing (names that could not be
        resolved).
    #>
    [CmdletBinding()]
    param($Controls)

    # $null, not falsiness: an explicitly supplied EMPTY list is a caller saying "these
    # are the controls", and re-enumerating instead reaches for a live SWD that the
    # caller may deliberately not have.
    if ($null -eq $Controls) { $Controls = Get-SwdControl }

    $panel = @($Controls | Where-Object {
        $_.Class -like '*Window.8*' -and $_.Text -eq 'SizeConfig' })
    if ($panel.Count -eq 0) {
        # A HUNG SWD LOOKS EXACTLY LIKE A HIDDEN TAB from the panel count alone: every
        # row comes back Text=$null, so nothing matches 'SizeConfig' either way.
        # swd_msg.ps1 emits TimedOut/Skipped per row for precisely this, and the two
        # cases want OPPOSITE actions - switching tabs on a mid-scan SWD is the wrong
        # move, and the old message advised exactly that.
        $unread = @($Controls | Where-Object {
            ($_.PSObject.Properties['TimedOut'] -and $_.TimedOut) -or
            ($_.PSObject.Properties['Skipped']  -and $_.Skipped) })
        if ($unread.Count -gt 0) {
            throw ("no 'SizeConfig' panel found, but $($unread.Count) of " +
                   "$(@($Controls).Count) controls did not answer WM_GETTEXT - the " +
                   'control map is INCOMPLETE, so the panel may well be present and ' +
                   'simply unread. Do NOT switch tabs: an unresponsive SWD is usually ' +
                   'mid-scan. Wait for it to answer and re-read the map.')
        }
        throw ("no 'SizeConfig' panel found. The Shape Room tab must be the visible tab " +
               'when the control map is taken - controls on a hidden tab are not ' +
               'enumerated at all, which is why flow ms was absent from control-map.csv.')
    }
    if ($panel.Count -gt 1) { throw "$($panel.Count) 'SizeConfig' panels found; refusing to guess." }

    $inside = Get-SwdDescendant -Controls $Controls -Handle ([int64]$panel[0].Handle)

    $result = [ordered]@{}
    $missing = @()

    foreach ($axis in 'Length', 'Width', 'Volume') {
        $spec = $script:GeometryAxes[$axis]

        # Volume's caption carries its current value, so prefix-match every group.
        $group = @($inside | Where-Object {
            $_.Class -like '*Window.8*' -and $_.Text -and
            # Ordinal: the default overload is CurrentCulture, under which a caption
            # carrying a soft hyphen or a zero-width joiner still 'starts with'
            # 'Board Length'. Which group is which decides where a write lands.
            $_.Text.StartsWith($spec.Group, [StringComparison]::Ordinal) })
        if ($group.Count -ne 1) {
            $missing += "$axis group ('$($spec.Group)'): found $($group.Count)"
            $result[$axis] = $null
            continue
        }

        $within = Get-SwdDescendant -Controls $Controls -Handle ([int64]$group[0].Handle)

        # Exactly one EDIT per group is enabled - the others are read-only unit
        # conversions (feet, inches) that would silently accept a write and not apply.
        $edits = @($within | Where-Object {
            $_.Class -like '*EDIT*' -and [bool]$_.Enabled -and [bool]$_.Visible })
        $buttons = @($within | Where-Object {
            $_.Class -like '*BUTTON*' -and $_.Text -eq $spec.Apply })

        if ($edits.Count -ne 1)   { $missing += "$axis enabled EDIT: found $($edits.Count)" }
        if ($buttons.Count -ne 1) { $missing += "$axis '$($spec.Apply)' button: found $($buttons.Count)" }

        $result[$axis] = [pscustomobject]@{
            Group  = [int64]$group[0].Handle
            Edit   = if ($edits.Count -eq 1)   { [int64]$edits[0].Handle }   else { $null }
            Apply  = if ($buttons.Count -eq 1) { [int64]$buttons[0].Handle } else { $null }
            # Carried so Set-SwdGeometry can refuse a disabled Apply BEFORE it writes
            # the box, rather than discovering it inside Invoke-SwdButton afterwards.
            ApplyEnabled = if ($buttons.Count -eq 1) { [bool]$buttons[0].Enabled } else { $false }
            Unit   = $spec.Unit
        }
    }

    $config = @($inside | Where-Object {
        $_.Class -like '*STATIC*' -and $_.Text -and $_.Text -like 'Configuration:*' })
    if ($config.Count -ne 1) { $missing += "Configuration label: found $($config.Count)" }

    $result['ConfigurationHandle'] = if ($config.Count -eq 1) { [int64]$config[0].Handle } else { $null }
    $result['Missing'] = $missing
    return [pscustomobject]$result
}


function ConvertFrom-SwdConfigurationText {
    <#
    .SYNOPSIS
        Parse the Configuration label into named quantities.
    .DESCRIPTION
        The label restates every dimension SWD knows, e.g.

            Configuration:
            Displacement (board+surfer)80.10 Liters,
            Volume 26.85 Liters,
            Length 2134 mm,
            Width 553 mm
            Length/Width: 3.9
            Thick: 40.3 mm
            Width/Thick: 13.7
            Length/Thick: 53.0

        Each field is matched independently, so a layout change loses one value rather
        than all of them, and every unmatched field stays $null instead of 0. A zero
        would flow into a delta calculation and read as 'this dimension collapsed'.

        EVERY NUMBER PATTERN IS ANCHORED on what follows it. The five dimensioned
        fields were already anchored by their unit ('...mm', '...Liters'); the three
        ratios were not, and an unanchored [\d.]+ stops dead at a comma: measured,
        'Length/Width: 3,9' returned 3 and 'Width/Thick: 13,7' returned 13, with
        Parsed blind to it because a wrong number is still a number. SWD is French in
        origin (CLAUDE.md section 5 records its XML using comma decimals), so an
        unparseable French label must read $null, never a truncated integer.

        RAW IS TRI-STATE, and $Text is deliberately UNTYPED to keep it that way.
        [string] coerces $null to '', which would have made a WM_GETTEXT timeout
        indistinguishable from a genuinely empty label - and Set-SwdGeometry compares
        Raw before against Raw after to decide whether the panel MOVED.
            $null  the label was never read (timeout, or no handle)
            ''     the label answered, and answered empty
            text   the label answered
    .OUTPUTS
        PSCustomObject with VolumeL, DisplacementL, LengthMm, WidthMm, ThickMm,
        LengthOverWidth, WidthOverThick, LengthOverThick, Raw, Parsed (field count).
    #>
    [CmdletBinding()]
    param([AllowNull()] $Text)

    # ConvertTo-SwdNumber, not a [double] cast. [\d.]+ admits two dots, so a label
    # reading 'Length 21.3.4 mm' captures '21.3.4' and the cast THROWS - out of here,
    # out of Get-SwdGeometry, and into Read-SwdGeometryState, where it is swallowed and
    # reported as 'configuration-label-unreadable'. That is the $null-versus-answered
    # conflation this function's own Raw contract exists to prevent, arriving by the
    # back door. An unparseable field is $null, like any other unmatched field.
    $get = {
        param($pattern)
        if ($Text -and $Text -match $pattern) {
            $n = ConvertTo-SwdNumber -Text $Matches[1]
            if ($n.Ok) { return $n.Value }
        }
        return $null
    }

    $parsed = [pscustomobject]@{
        VolumeL         = & $get 'Volume\s+([\d.]+)\s*Liters'
        DisplacementL   = & $get 'Displacement[^)]*\)\s*([\d.]+)\s*Liters'
        LengthMm        = & $get 'Length\s+([\d.]+)\s*mm'
        WidthMm         = & $get 'Width\s+([\d.]+)\s*mm'
        ThickMm         = & $get 'Thick:\s*([\d.]+)\s*mm'
        LengthOverWidth = & $get 'Length/Width:\s*([\d.]+)(?=\s|$)'
        WidthOverThick  = & $get 'Width/Thick:\s*([\d.]+)(?=\s|$)'
        LengthOverThick = & $get 'Length/Thick:\s*([\d.]+)(?=\s|$)'
        Raw             = $Text
        Parsed          = 0
    }
    $count = 0
    foreach ($n in $script:ConfigFields) {
        if ($null -ne $parsed.$n) { $count++ }
    }
    $parsed.Parsed = $count
    return $parsed
}


function Get-SwdGeometry {
    <#
    .SYNOPSIS
        Current geometry from all three independent oracles.
    .DESCRIPTION
        Oracle 1: the Configuration label (volume, length, width, thickness, ratios).
        Oracle 2: the three editable boxes.
        Oracle 3: the window title, which carries the board name and its length.

        All three are returned unreconciled. Disagreement between them is a finding,
        not something for this function to average away.

        THE THREE BOXES ARE NOT THREE READINGS OF THE SAME THING, and Boxes.Volume in
        particular is NOT the board's volume. Length and Width do track the label. The
        Volume group's enabled EDIT is a TARGET-ENTRY field - captured reading 10 while
        the label read 26.85 L on the same board, its own caption being 'Input volume
        liters:'. Boxes.Volume is therefore what will be applied next, not what the
        board is now. Only the Configuration label answers 'what is the board'.

        Boxes.<Axis> is $null when the box did not answer, answered empty, OR answered
        something non-numeric; the three are not distinguished, which is tolerable only
        because no decision in this file is taken from Boxes.
    .OUTPUTS
        PSCustomObject with Configuration, Boxes, Title, TitleLengthMm, Homothety,
        Agree.

        Agree is TRI-STATE: $true both length oracles agree to 1 mm, $false they
        disagree - a real finding, the label and the caption should not diverge - and
        $null the question could not be asked because one of them is missing. $null is
        never 'they agree'.
    #>
    [CmdletBinding()]
    param($Controls, $Resolved)

    # $null, not falsiness - see Resolve-SwdGeometryControl.
    if ($null -eq $Controls) { $Controls = Get-SwdControl }
    if ($null -eq $Resolved) { $Resolved = Resolve-SwdGeometryControl -Controls $Controls }

    $configText = $null
    if ($Resolved.ConfigurationHandle) {
        $configText = Get-SwdText -Handle $Resolved.ConfigurationHandle
    }
    $configuration = ConvertFrom-SwdConfigurationText -Text $configText

    $boxes = [ordered]@{}
    foreach ($axis in 'Length', 'Width', 'Volume') {
        $value = $null
        if ($Resolved.$axis -and $Resolved.$axis.Edit) {
            $raw = Get-SwdText -Handle $Resolved.$axis.Edit
            $number = 0.0
            if ($raw -and [double]::TryParse(
                    $raw, [Globalization.NumberStyles]::Float,
                    [Globalization.CultureInfo]::InvariantCulture, [ref]$number)) {
                $value = $number
            }
        }
        $boxes[$axis] = $value
    }

    # Process.MainWindowHandle is NOT a trustworthy way to name the main window: it
    # returned three different values in one session during the 2026-08-31 live run and
    # once named a modal dialog captioned 'Starting HydroScan'. The caption read from it
    # is therefore VERIFIED against the main-window pattern before it is reported. An
    # unrecognised caption comes back $null - 'we did not read the main window' - rather
    # than a dialog's caption presented as the window title.
    #
    # swd_board.ps1 needs the caption as its load-bearing board-identity oracle and does
    # the full [SwdWin]::TopLevelForPid resolution instead. Here it is a soft
    # cross-check, so degrading to $null is proportionate and the cheaper route is taken
    # deliberately. That file also pulls in UIAutomationClient, which this one must not.
    $swd = Get-SwdProcess
    $title = $null
    $candidate = Get-SwdText -Handle ([int64]$swd.MainWindowHandle)
    if ($candidate -and $candidate -like $script:GeomMainTitleLike) { $title = $candidate }

    # ConvertTo-SwdNumber rather than a [double] cast: '(1.2.3 mm)' matches [\d.]+ and
    # then THROWS on the cast, and this function is called from inside Set-SwdGeometry's
    # poll loop, where a throw means the box was written and Apply clicked with no
    # result object returned at all.
    $titleLength = $null
    if ($title -and $title -match '<Board:\s*.+?\(([\d.,]+)\s*mm\)>') {
        $titleNumber = ConvertTo-SwdNumber -Text $Matches[1]
        if ($titleNumber.Ok) { $titleLength = $titleNumber.Value }
    }

    # Two independent length readings should agree to the rounding in the label, which
    # prints whole millimetres against the box's one decimal place.
    $agree = $null
    if ($null -ne $configuration.LengthMm -and $null -ne $titleLength) {
        $agree = ([math]::Abs($configuration.LengthMm - $titleLength) -le 1.0)
    }

    return [pscustomobject]@{
        Configuration = $configuration
        Boxes         = [pscustomobject]$boxes
        Title         = $title
        TitleLengthMm = $titleLength
        # Never reported as unchecked: BM_GETCHECK is blind on this control style.
        Homothety     = 'unknown'
        Agree         = $agree
    }
}


function Read-SwdGeometryState {
    <#
    .SYNOPSIS
        Get-SwdGeometry that answers $null instead of throwing.
    .DESCRIPTION
        For the paths that run AFTER the box has been written or Apply has been
        clicked. A throw there aborts with SWD already changed and NO RESULT OBJECT
        returned - the defect swd_msg.ps1 records fixing inside Set-SwdNumeric, which
        would otherwise be reintroduced one level up. $null means 'the panel could not
        be read', which is never the same claim as 'the panel is unchanged'.
    #>
    [CmdletBinding()]
    param($Controls, $Resolved)
    try {
        return Get-SwdGeometry -Controls $Controls -Resolved $Resolved
    } catch {
        Write-Verbose "geometry read failed: $($_.Exception.Message)"
        return $null
    }
}


function Set-SwdGeometry {
    <#
    .SYNOPSIS
        Set one geometry axis, apply it, and report what ACTUALLY changed.
    .DESCRIPTION
        Checks the panel's handles, writes the box (Set-SwdNumeric validates and reads
        back), clicks the matching Apply, then polls the Configuration label until it
        changes or the timeout expires, and reports the before/after of EVERY dimension
        - not only the one requested.

        That is the point of this function. The coupling between the three axes is
        unmeasured, so the delta table is the measurement.

        WHAT `Applied` MEANS, AND WHY IT TAKES FOUR THINGS. This function exists to
        settle whether the never-driven Apply buttons actuate at all, so Applied is a
        claim about the APPLICATION and needs all four of:

            1. the click was transported   ClickSent, and not a declined confirm
            2. the label was readable      both reads actually answered
            3. THIS AXIS MOVED             Deltas[<axis>] is non-zero - not merely
                                           'the label differs somewhere'
            4. it moved to the request     within the axis tolerance

        REQUIREMENT 3 IS THE ONE THAT KEEPS BEING LOST, TWICE NOW, THE SECOND TIME
        WHILE FIXING THE FIRST. Applied began as a predicate on the AFTER state alone:
        a board already sitting near the target reported Applied=True for a click
        measured as ClickSent=False, LastError=5 (UIPI-blocked, never transported) with
        the label byte-identical and all eight deltas zero. The repair added 'the panel
        moved' - and a panel is not an axis. With the requested dimension already at
        target, ANY other field moving satisfied that test, so Applied=True came back
        with dLengthMm of exactly 0 while Thick alone had changed. Inter-axis coupling
        is the very thing the delta table exists to measure, which makes 'some field
        moved' the worst possible proxy for 'this field moved'.

        Either way the harm is the same and it is permanent: a first live run against
        such a board is written up as 'Apply Length works' about a mechanism this
        file's own header records as never having been driven.

        A board already at target therefore returns Applied=$false with
        'already-at-target' - not a failure, a run that PROVES NOTHING - and says so
        even when other fields moved. Move the board off target first if the Apply
        button is what is being tested.
    .PARAMETER Axis
        Length, Width or Volume.
    .PARAMETER Value
        Target value. Length and Width in MILLIMETRES, Volume in LITRES. Must be finite
        and positive: NaN and Infinity both pass a bare '-le 0' test, and both survive
        .ToString() and the numeric validation in Set-SwdNumeric as far as WM_SETTEXT.

        NOT kilometres per hour and not metres. ConvertTo-Kmh exists in swd_msg.ps1 for
        the flow box and must never be applied here.
    .PARAMETER Tolerance
        ABSOLUTE, in the axis's own unit - millimetres for Length and Width, litres for
        Volume. Defaults to half the Configuration label's own printing quantum (see
        $script:GeometryAxes). It was RELATIVE 0.02, i.e. +/-42.7 mm on a 2134 mm board,
        so a +1.2% request with nothing whatever happening came back Applied=True.
    .OUTPUTS
        PSCustomObject. EVERY return path emits the SAME fields, so a caller may read
        any of them without a StrictMode accident:

            Axis, Requested, Tolerance   what was asked
            Applied, Changed, Reason     what was established
            Before, After                whole geometry snapshots; After is $null when
                                         the panel could not be re-read
            Deltas, DeltasUnavailable    per-dimension movement, and the fields that
                                         could not be differenced rather than silently
                                         omitted
            BoxBefore, BoxAfter          what the EDIT held either side of the write
            ClickSent, ClickObserved, ClickLastError, ClickWhatIf
                                         the whole transport answer, not just Sent
            ElapsedMs
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    param(
        [Parameter(Mandatory)][ValidateSet('Length', 'Width', 'Volume')][string] $Axis,
        [Parameter(Mandatory)][double] $Value,
        [int] $TimeoutMs = 20000,
        [int] $PollMs = 500,
        [double] $Tolerance
    )

    # NaN first: every comparison against NaN is false, so 'NaN -le 0' is $false and NaN
    # walks straight through a positivity test. [double]::Infinity likewise.
    if ([double]::IsNaN($Value) -or [double]::IsInfinity($Value)) {
        throw "Value must be a finite number; got $Value."
    }
    if ($Value -le 0)  { throw "Value must be positive; got $Value." }
    if ($TimeoutMs -lt 0) { throw "TimeoutMs must be 0 or more; got $TimeoutMs." }
    if ($PollMs -lt 1)    { throw "PollMs must be 1 or more; got $PollMs." }

    $spec = $script:GeometryAxes[$Axis]
    if (-not $PSBoundParameters.ContainsKey('Tolerance')) { $Tolerance = $spec.Tolerance }
    # IsInfinity as well as IsNaN, because the message says FINITE and +Infinity was
    # passing: Abs(anything) -le Infinity is always true, so a board left at 1 mm came
    # back Applied=True for a 2200 mm request. Same omission as the $Value guard above
    # had before this round; both halves of 'finite' are needed on both parameters.
    if ($Tolerance -lt 0 -or [double]::IsNaN($Tolerance) -or [double]::IsInfinity($Tolerance)) {
        throw "Tolerance must be a finite number of $($spec.Unit), 0 or more; got $Tolerance."
    }

    # One field set for every exit, filled in as the run establishes each part.
    $out = [ordered]@{
        Axis = $Axis; Requested = $Value; Tolerance = $Tolerance
        Applied = $false; Changed = $false
        Before = $null; After = $null
        Deltas = @{}; DeltasUnavailable = @()
        BoxBefore = $null; BoxAfter = $null
        ClickSent = $false; ClickObserved = 'not-attempted'
        ClickLastError = 0; ClickWhatIf = $false
        ElapsedMs = 0; Reason = 'not-started'
    }

    $controls = Get-SwdControl
    $resolved = Resolve-SwdGeometryControl -Controls $controls
    if ($resolved.Missing.Count -gt 0) {
        throw ("geometry panel incompletely resolved: " + ($resolved.Missing -join '; '))
    }
    $target = $resolved.$Axis

    # PRECONDITIONS BEFORE THE WRITE. Invoke-SwdButton throws on a dead, disabled or
    # non-BUTTON handle, and that throw used to land AFTER the box had been written -
    # leaving SWD holding a value nobody asked to keep, with no result object and no
    # log line. Same class as the pre-write validation Set-SwdNumeric itself carries.
    foreach ($h in @(@{ What = 'edit box';                  Handle = $target.Edit },
                     @{ What = "'$($spec.Apply)' button";   Handle = $target.Apply })) {
        if (-not (Test-SwdHandle -Handle $h.Handle)) {
            throw ("$Axis $($h.What) (handle $($h.Handle)) is not a live window belonging " +
                   'to SurfHydrodynamics. Nothing was written.')
        }
    }
    if (-not $target.ApplyEnabled) {
        throw ("$Axis '$($spec.Apply)' button is DISABLED. SWD disabled it for a reason, " +
               'and writing a box that cannot then be applied leaves the panel dirty. ' +
               'Nothing was written.')
    }

    $before = Get-SwdGeometry -Controls $controls -Resolved $resolved
    $out.Before = $before

    # THE IDENTITY ORACLES ARE READ, SO THEY ARE CONSULTED. This function was reading
    # all three and then writing to the board regardless - mutating a board the run had
    # never identified. A geometry change is written into a cloud-synced library file;
    # 'which board is this' is not optional context.
    #
    # Agree=$false is refused because this file's own documentation calls a disagreement
    # between the label and the caption 'a real finding'. Agree=$null is NOT refused: it
    # means the question could not be asked (no board segment in the caption), and there
    # is no measurement here saying that state forbids a write. No override switch is
    # offered - CLAUDE.md section 4 records what happens to guards that ship with one.
    if ($null -eq $before.Title) {
        throw ('the main window caption did not answer, so the board about to be ' +
               'modified is UNIDENTIFIED. Nothing was written.')
    }
    if ($false -eq $before.Agree) {
        throw ("the two length oracles DISAGREE: the Configuration label reads " +
               "$($before.Configuration.LengthMm) mm and the window caption reads " +
               "$($before.TitleLengthMm) mm. One of them is not describing the loaded " +
               'board. Nothing was written.')
    }

    if (-not $PSCmdlet.ShouldProcess("SWD Shape Room", "set $Axis to $Value and apply")) {
        # -WhatIf and a DECLINED CONFIRM both land here and are not the same event: one
        # is a rehearsal, the other is an operator saying no.
        $out.After = $before
        $out.Reason = if ($WhatIfPreference) { 'whatif' } else { 'not-confirmed' }
        return [pscustomobject]$out
    }

    $written = Set-SwdNumeric -Handle $target.Edit `
        -Value ($Value.ToString([Globalization.CultureInfo]::InvariantCulture))
    $out.BoxBefore = $written.Before
    $out.BoxAfter  = $written.After
    if (-not $written.Ok) {
        if ($written.WhatIf) {
            # An explicit -Confirm prompts again inside Set-SwdNumeric, and a decline
            # there is not a failure. Set-SwdNumeric guarantees nothing was sent, so
            # After = $before is a sound claim rather than an unobserved one.
            $out.After = $before
            $out.Reason = 'box-write-not-confirmed - nothing was written and nothing applied'
            return [pscustomobject]$out
        }
        # THE WRITE MAY WELL HAVE COMMITTED: 'clamped or rejected' means the control took
        # a DIFFERENT value, and 'readback TIMED OUT' means its state is unknown. Saying
        # After = $before here would assert the panel is unchanged, which is precisely
        # the claim that cannot be made. Re-read it instead, or report $null.
        $out.After = Read-SwdGeometryState -Controls $controls -Resolved $resolved
        $out.Reason = "box-write-failed: $($written.Reason)"
        return [pscustomobject]$out
    }

    # The precondition check above NARROWS the window in which Invoke-SwdButton can
    # throw; it cannot close it, because the handle may die between the check and the
    # click. Past this point the box is written, so no path may abandon the caller
    # without a result object saying so.
    try {
        $clicked = Invoke-SwdButton -Handle $target.Apply
    } catch {
        $out.After = Read-SwdGeometryState -Controls $controls -Resolved $resolved
        $out.ClickObserved = 'threw'
        $out.Reason = ("apply-click-refused: $($_.Exception.Message) " +
                       "THE BOX WAS WRITTEN and still holds $Value $($spec.Unit).")
        return [pscustomobject]$out
    }
    # Sent is TRANSPORT, not actuation - so the whole answer is carried, not just Sent.
    # A UIPI-blocked click (Sent=$false, LastError=5), a declined inner confirm
    # (WhatIf=$true) and a delivered no-op are three different events.
    $out.ClickSent      = [bool]$clicked.Sent
    $out.ClickObserved  = $clicked.Observed
    $out.ClickLastError = $clicked.LastError
    $out.ClickWhatIf    = [bool]$clicked.WhatIf

    # Observe FIRST, then sleep: an instant change used to cost a full PollMs, and at
    # TimeoutMs=0 the old loop never observed anything at all and reported on the
    # pre-click snapshot.
    $beforeRaw = $before.Configuration.Raw
    $watch = [Diagnostics.Stopwatch]::StartNew()
    $after = $null
    $sawChange = $false
    while ($true) {
        $sample = Read-SwdGeometryState -Controls $controls -Resolved $resolved
        if ($null -ne $sample -and $null -ne $sample.Configuration.Raw) {
            $after = $sample
            # A $null Raw is a WM_GETTEXT TIMEOUT, not an answer. The old test was a
            # bare -ne, so one transient timeout broke the poll early claiming the
            # board had moved - a positive claim on no evidence, with an empty delta
            # table beside it.
            if ($null -ne $beforeRaw -and $sample.Configuration.Raw -ne $beforeRaw) {
                $sawChange = $true
                break
            }
        }
        if ($watch.ElapsedMilliseconds -ge $TimeoutMs) { break }
        Start-Sleep -Milliseconds $PollMs
    }
    $watch.Stop()
    $out.After     = $after
    $out.Changed   = $sawChange
    $out.ElapsedMs = [int]$watch.ElapsedMilliseconds

    $deltas = @{}
    $unavailable = @()
    foreach ($name in $script:ConfigFields) {
        $b = $before.Configuration.$name
        $a = if ($null -ne $after) { $after.Configuration.$name } else { $null }
        # Named rather than omitted: a field silently missing from the delta table reads
        # as 'this dimension did not move'.
        if ($null -ne $a -and $null -ne $b) { $deltas[$name] = [double]($a - $b) }
        else { $unavailable += $name }
    }
    $out.Deltas = $deltas
    $out.DeltasUnavailable = $unavailable

    $observedField = @{ Length = 'LengthMm'; Width = 'WidthMm'; Volume = 'VolumeL' }[$Axis]
    $wasAtTarget = ($null -ne $before.Configuration.$observedField) -and
                   ([math]::Abs($before.Configuration.$observedField - $Value) -le $Tolerance)
    $observed = if ($null -ne $after) { $after.Configuration.$observedField } else { $null }
    $atTarget = ($null -ne $observed) -and ([math]::Abs($observed - $Value) -le $Tolerance)

    # THE REQUESTED AXIS'S OWN DELTA, not merely 'the panel changed'. This is the whole
    # verdict and it was the hole: 'the label differs' was treated as 'Apply moved this
    # dimension', so a board ALREADY at the requested value came back Applied=True the
    # moment any OTHER field moved - dLengthMm exactly 0 while Thick alone changed.
    # Inter-axis coupling is precisely what the delta table exists to measure, so the
    # one input that must never be ignored was the one being ignored.
    $axisDelta = if ($deltas.ContainsKey($observedField)) { $deltas[$observedField] } else { $null }
    $axisMoved = ($null -ne $axisDelta) -and ($axisDelta -ne 0)

    # One ordered decision, most specific first, and Applied is read off it rather than
    # computed separately - two independent expressions for one verdict is how they
    # drift apart.
    if ($clicked.WhatIf) {
        $out.Reason = ("apply-not-confirmed - THE BOX WAS WRITTEN and still holds " +
                       "$Value $($spec.Unit); nothing was applied")
    } elseif (-not $clicked.Sent) {
        $out.Reason = ("apply-click-not-transported (Observed=$($clicked.Observed), " +
                       "LastError=$($clicked.LastError); 5 is the UIPI signature). " +
                       'THE BOX WAS WRITTEN.')
    } elseif ($null -eq $beforeRaw -or $null -eq $after) {
        $out.Reason = 'configuration-label-unreadable - whether anything moved is UNKNOWN'
    } elseif ($null -eq $axisDelta) {
        $out.Reason = ("$observedField could not be differenced (it is in " +
                       'DeltasUnavailable), so whether this axis moved is UNKNOWN')
    } elseif (-not $axisMoved -and $wasAtTarget) {
        $out.Reason = ("already-at-target - $observedField moved by exactly 0, so this " +
                       "run is no evidence that '$($spec.Apply)' does anything" +
                       $(if ($sawChange) { ' (other fields on the label DID move - see Deltas)' } else { '' }))
    } elseif (-not $axisMoved -and $sawChange) {
        $out.Reason = ("the label changed but $observedField moved by exactly 0 - " +
                       'whatever Apply did, it was not this axis (see Deltas)')
    } elseif (-not $axisMoved) {
        $out.Reason = 'no-change-observed'
    } elseif (-not $atTarget) {
        $out.Reason = 'changed-but-not-to-target'
    } else {
        $out.Reason = 'ok'
    }
    $out.Applied = ($out.Reason -eq 'ok')

    return [pscustomobject]$out
}
