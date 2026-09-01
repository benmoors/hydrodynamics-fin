"""Mutation spot-check for the hunks changed by the SQA rounds on swd_extract.ps1.

Every mutant is compile-checked (Parser::ParseFile) BEFORE the suite runs -- a
mutant that does not parse proves nothing about coverage.

Each mutant is tagged with the kind of evidence that kills it:

    behavioural  the suite runs the real code and observes wrong output
    structural   the suite only asserts on the script's source text

A structural-only kill is weaker and is reported separately, because a source
assertion cannot tell a working loop from a broken one. Round 2 flagged that the
two CRITICAL 1 mutants were structural-only; they are behavioural now, via
Read-PolarDatabase.

Paths are derived from this file's own location -- an earlier revision hardcoded
a session scratchpad that no longer exists.
"""
import os
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))          # SWD/tools/tests
TOOLS = os.path.dirname(HERE)                              # SWD/tools
SRC = os.path.join(TOOLS, "swd_extract.ps1")
TESTS = os.path.join(HERE, "swd_extract.Tests.ps1")
RUNNER = os.path.join(HERE, "run_pester.ps1")
MUT = os.path.join(os.environ.get("TEMP", os.path.join(HERE, "_mutants")), "swd_mutants")
os.makedirs(MUT, exist_ok=True)

base = open(SRC, encoding="ascii", newline="").read()

# id, evidence-kind, description, old, new
MUTANTS = [
    ("C1a", "behavioural", "polar loop: invert the Table4 node test",
     "if ($reader.NodeType -ne [System.Xml.XmlNodeType]::Element -or $reader.LocalName -ne 'Table4') {",
     "if ($reader.NodeType -eq [System.Xml.XmlNodeType]::Element -or $reader.LocalName -ne 'Table4') {"),
    ("C1b", "behavioural", "polar loop: re-introduce the every-second-block skip",
     "                [void]$reader.Read()\n                continue\n            }\n            $blocks++",
     "                [void]$reader.Read()\n                continue\n            }\n            [void]$reader.Read()\n            $blocks++"),
    ("C1c", "structural", "drop the block-count assertion entirely",
     'if ($blocks -ne $expected) {\n        throw "fin polar parse incomplete:',
     'if ($false) {\n        throw "fin polar parse incomplete:'),
    ("C1d", "behavioural", "raw block scan miscounts by rejecting a tab after the tag",
     "if ($after -eq [char]0x3E -or $after -eq [char]0x20 -or $after -eq [char]0x09 -or $after -eq [char]0x2F) {",
     "if ($after -eq [char]0x20 -or $after -eq [char]0x09 -or $after -eq [char]0x2F) {"),

    ("R3a", "behavioural", "CRITICAL round 3: stop protecting the PARENT of each root",
     "        $parent = Split-Path -Parent $full\n        if ($parent) {",
     "        $parent = $null\n        if ($parent) {"),
    ("R3b", "behavioural", "W1: Test-PathUnderRoot -or becomes -and",
     "        if ($p -eq $rr -or $p.StartsWith($rr + '\\', [StringComparison]::OrdinalIgnoreCase)) { return $rr }",
     "        if ($p -eq $rr -and $p.StartsWith($rr + '\\', [StringComparison]::OrdinalIgnoreCase)) { return $rr }"),
    ("R3c", "behavioural", "W1: drop the UNC / extended-length / device refusal",
     "if ($OutDir.StartsWith('\\\\')) {",
     "if ($false) {"),
    ("R3d", "behavioural", "W1: Resolve-CanonicalTarget stops canonicalising",
     "    $tail = New-Object 'System.Collections.Generic.List[string]'\n    $cur = $Path.TrimEnd('\\')",
     "    return $Path.TrimEnd('\\')\n    $tail = New-Object 'System.Collections.Generic.List[string]'\n    $cur = $Path.TrimEnd('\\')"),
    ("R3e", "behavioural", "W1: Get-CanonicalDirectory ignores the junction target",
     "        if ([SwdPath.Native]::GetFinalPathNameByHandleW($h, $sb, 32767, 0) -eq 0) { return $null }",
     "        if ([SwdPath.Native]::GetFinalPathNameByHandleW($h, $sb, 32767, 0) -eq 0) { return $null }\n        return $Path"),
    ("R3f", "behavioural", "W2: summary reverts to member enumeration on a possibly-empty array",
     "$radii    = @($boardRows | ForEach-Object { $_.turn_radius_m } | Sort-Object -Unique)",
     "$radii    = @($boardRows.turn_radius_m | Sort-Object -Unique)"),
    ("R3g", "structural", "W3: disable removal of tables this run did not write",
     "    if ($script:WrittenTables.Contains($known)) { continue }",
     "    if ($true) { continue }"),
    ("R3h", "structural", "W4: put the absolute script path back into the manifest",
     "        generated_utc   = (Get-Date).ToUniversalTime().ToString('o')\n        skip_elements   = [bool]$SkipElements",
     "        generated_utc   = (Get-Date).ToUniversalTime().ToString('o')\n        script          = $PSCommandPath\n        skip_elements   = [bool]$SkipElements"),
    ("R3i", "behavioural", "W3: Write-CsvNoBom stops recording what it wrote",
     "    $script:WrittenTables[$name] = [ordered]@{",
     "    $null = [ordered]@{"),

    ("M4", "behavioural", "drop the @() that pins the constant-zero result to an array",
     "    $drop = @(Get-ConstantZeroColumn -Rows $rows -Keep $Keep)",
     "    $drop = Get-ConstantZeroColumn -Rows $rows -Keep $Keep"),
    ("M5", "behavioural", "constant-zero scan: invert the disqualifying comparison",
     "                if ($null -eq $d -or $d -ne 0.0) { $cand.RemoveAt($i) }",
     "                if ($null -eq $d -or $d -eq 0.0) { $cand.RemoveAt($i) }"),
    ("M5b", "behavioural", "constant-zero scan: cast instead of -as, so a non-numeric column throws",
     "                $d = $v -as [double]",
     "                $d = [double]$v"),
    ("M6", "behavioural", "board name: revert the split class so it misses a backslash",
     "        return ($FullName.Substring($rootFull.Length + 1) -split '[\\\\/]')[0]",
     "        return ($FullName.Substring($rootFull.Length + 1) -split '[\\/]')[0]"),
    ("M7", "behavioural", "Get-FieldDouble: cast a null straight to double instead of NaN",
     "    if ($null -eq $v) {\n        Write-WarningOnce \"field is null on $($Type.Name), writing NaN: $Name\"\n        return [double]::NaN\n    }",
     "    if ($null -eq $v) {\n        Write-WarningOnce \"field is null on $($Type.Name), writing NaN: $Name\"\n        return [double]$v\n    }"),
    ("M8", "structural", "roll min/max: reseed with infinities",
     "        $rollSum = 0.0; $rollMin = [double]::NaN; $rollMax = [double]::NaN",
     "        $rollSum = 0.0; $rollMin = [double]::PositiveInfinity; $rollMax = [double]::NegativeInfinity"),
    ("M9", "behavioural", "ConvertTo-DoubleList: stop counting unparseable tokens",
     "                else { $script:PolarBadTokens++ }",
     "                else { }"),
    ("M10", "behavioural", "Get-XmlText: invert the local-name match",
     "    foreach ($c in $Element.ChildNodes) { if ($c.LocalName -eq $Name) { return $c.InnerText } }",
     "    foreach ($c in $Element.ChildNodes) { if ($c.LocalName -ne $Name) { return $c.InnerText } }"),
    ("M11", "behavioural", "CSV writer: emit a UTF-8 BOM",
     "    $sw = New-Object System.IO.StreamWriter($Path, $false, (New-Object Text.UTF8Encoding($false)))",
     "    $sw = New-Object System.IO.StreamWriter($Path, $false, (New-Object Text.UTF8Encoding($true)))"),
    ("M12", "behavioural", "CSV writer: emit bare LF instead of CRLF",
     '        $sw.NewLine = "`r`n"',
     '        $sw.NewLine = "`n"'),
    ("M3", "behavioural", "median: return the upper-middle value on even counts",
     "    if ($sorted.Count % 2 -eq 1) { return [double]$sorted[$mid] }\n    return ([double]$sorted[$mid - 1] + [double]$sorted[$mid]) / 2.0",
     "    if ($sorted.Count % 2 -eq 1) { return [double]$sorted[$mid] }\n    return [double]$sorted[$mid]"),
    ("M14", "behavioural", "shaper_name: put the column back",
     "        scan_files        = $scanCount",
     "        shaper_name       = [string](Get-FieldValue -Object $bd -Name 'shaper_name' -Type $T_board)\n        scan_files        = $scanCount"),
    ("M15", "behavioural", "Get-ConstantZeroColumn: ignore -Keep",
     "        if ($Keep -contains $p.Name) { continue }",
     "        if ($false) { continue }"),
]


def compile_check(path):
    ps = ("$e = $null; "
          "[void][System.Management.Automation.Language.Parser]::ParseFile('%s', [ref]$null, [ref]$e); "
          "if ($e) { Write-Output ('PARSE_FAIL ' + $e[0].Message) } else { Write-Output 'PARSE_OK' }" % path)
    r = subprocess.run(["powershell.exe", "-NoProfile", "-NonInteractive", "-Command", ps],
                       capture_output=True, text=True)
    return r.stdout.strip()


def run_suite(target):
    env = dict(os.environ)
    env["SWD_EXTRACT_TARGET"] = target
    env["SWD_DATA_DIR"] = os.path.join(os.path.dirname(TOOLS), "data")
    r = subprocess.run(["powershell.exe", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", RUNNER, TESTS],
                       capture_output=True, text=True, env=env)
    out = re.sub(r"\x1b\[[0-9;]*m", "", r.stdout + r.stderr)
    m = re.search(r"Tests Passed: (\d+), Failed: (\d+)", out)
    if not m:
        return None, None, out[-600:]
    return int(m.group(1)), int(m.group(2)), ""


def main():
    only = sys.argv[1:] or None
    p0, f0, err0 = run_suite(SRC)
    print("BASELINE  passed=%s failed=%s %s" % (p0, f0, err0))
    if f0 != 0:
        print("baseline suite is not green; mutation results would be meaningless")
        return 1

    results = []
    for mid, kind, desc, old, new in MUTANTS:
        if only and mid not in only:
            continue
        if base.count(old) != 1:
            print("%-5s %-11s %-52s BAD-MUTANT (%d matches)" % (mid, kind, desc[:52], base.count(old)))
            results.append((mid, kind, desc, "BAD-MUTANT"))
            continue
        path = os.path.join(MUT, "mutant_%s.ps1" % mid)
        open(path, "w", encoding="ascii", newline="").write(base.replace(old, new))
        cc = compile_check(path)
        if not cc.startswith("PARSE_OK"):
            print("%-5s %-11s %-52s INVALID (does not parse)" % (mid, kind, desc[:52]))
            results.append((mid, kind, desc, "INVALID"))
            continue
        p, f, err = run_suite(path)
        status = "ERROR" if f is None else ("KILLED" if f > 0 else "SURVIVED")
        print("%-5s %-11s %-52s %-9s (passed=%s failed=%s)" % (mid, kind, desc[:52], status, p, f))
        results.append((mid, kind, desc, status))

    valid = [r for r in results if r[3] in ("KILLED", "SURVIVED")]
    killed = [r for r in valid if r[3] == "KILLED"]
    beh = [r for r in killed if r[1] == "behavioural"]
    print()
    print("mutation score: %d/%d killed (%.0f%%) over %d valid mutants; %d invalid/bad"
          % (len(killed), len(valid), 100.0 * len(killed) / max(len(valid), 1), len(valid),
             len(results) - len(valid)))
    print("  behavioural kills: %d   structural-only kills: %d"
          % (len(beh), len(killed) - len(beh)))
    print("  NOT proven: a spot-check of hand-picked mutants over the CHANGED hunks only. It says")
    print("  nothing about untouched code, and 4-39% of mutants are equivalent and unkillable.")
    for r in results:
        if r[3] != "KILLED":
            print("  NOT KILLED: %s (%s) %s -- %s" % (r[0], r[1], r[2], r[3]))
    for r in killed:
        if r[1] == "structural":
            print("  STRUCTURAL-ONLY: %s %s" % (r[0], r[2]))
    return 0


if __name__ == "__main__":
    sys.exit(main())
