---
paths:
  - "SWD/**"
  - "src/**"
  - "tests/**"
---

# SWD technical facts (moved verbatim from CLAUDE.md § 5)

Loads only when a file under `SWD/`, `src/` or `tests/` is read. Other docs that say "CLAUDE.md § 5" mean this file.

## 5. Technical facts already established — do not rediscover these

Each cost real debugging time.

- **`BinaryFormatter` requires Windows PowerShell 5.1 (`powershell.exe`), not `pwsh` 7+.** It was
  removed in .NET 9. `ReflectionOnlyLoad` is likewise unsupported on .NET Core.
- **The `AssemblyResolve` handler must return an already-loaded assembly and must never call
  `LoadFrom` inside itself.** An unguarded `LoadFrom` there recurses into an uncatchable
  `StackOverflowException`. This happened twice. The handler exists because reports are stamped
  `SurfHydrodynamics, Version=1.0.0.5` while the installed assembly is `1.0.8.1`.
- **Never call `asm.GetTypes()` bare** — it throws `ReflectionTypeLoadException` on this build. Use
  `GetType(name)`, or catch and filter `$_.Exception.Types`.
- **Never string-interpolate a reference-typed field** from these objects. Formatting the cyclic
  object graph is a second route into a stack overflow.
- **36 of `element_hydrodynamique`'s 101 fields are `[NonSerialized]`** and deserialise as 0/null
  regardless of the real physics — including both yaw-moment fields, every `_projection_*`,
  `_list_vitesse_moyenne_veine_ms`, `planche_ref` and `infos_planing`. Exporting them produces columns
  of fake zeros that look like data. Yaw rate is derived as `R_z = V / R` instead.
- **Field names contain French accents** (e-acute in `_trainee_globale_horizontale_n` and two in
  `_masse_flux_devie_kg_sec_planing`). Build them from explicit char codes so file encoding cannot
  corrupt them.
- **`fyn_profile_data_base.xml` uses French locale**: comma decimal separator, semicolon list
  separator. Parse with `InvariantCulture` after replacing commas.
- **Write CSV as UTF-8 without a BOM.** A BOM breaks the Python readers downstream.
- **SWD's water density is a 4-entry LOOKUP TABLE, not a constant and not a formula.**
  Recovered from `Form_shaper.actualiser_fluide()` by decompilation (2026-08-31).
  `temperature_eau` must be one of 0/10/20/30 degC, and there are separate salt and
  fresh arrays, so `rho` can only ever be one of eight values:

      salt : 1028 / 1027 / 1025 / 1023        (0 / 10 / 20 / 30 degC)
      fresh: 999.87 / 999.73 / 998.23 / 995.67
      salt dynamic viscosity: 0.00182 / 0.00138 / 0.00107 / 0.00084 Pa.s

  Defaults in `SurfHydrodynamics.exe.config` are `temperature_eau=20`,
  `salt_water=True`, i.e. rho = 1025.
- **The "0.015% density residual" DOES NOT EXIST, and the "second scan speed" is not
  a speed.** `mass_flux / frontal_section` is exactly `rho * V`, and across the corpus
  it takes exactly TWO values: **20460.0** (5,404 elements) and **20500.0** (1,404).
  Those are `1023 x 20.000` and `1025 x 20.000` - **one flow speed at two water
  temperatures**. Dividing the 1025 group by an assumed 1023 is precisely what
  produced the phantom second speed: `20500/1023 = 20.0391` exactly.
  On `default_shortboard` alone the ratio is **20460.000 +/- 0.002**, i.e. rho = 1023
  and V = 20.000 to 6 significant figures.
  The earlier note here claiming rho = 1023.154 with a real 0.015% bias was wrong: it
  averaged a bimodal mixture and read the spread as measurement noise. The note it
  had itself "corrected" - that the ratio factorises exactly as 1023 - was right.
- **The friction model is Blasius + 1/7-power + Schlichting, NOT ITTC-57 or
  Schoenherr.** Recovered from `Module_couche_limite.epaisseur_couche_limite()`:

      transition pinned at Re_crit = 5e5,  x_tr = 5e5 * nu / V
      laminar        Cf = 1.328 / sqrt(Re)
      turbulent      Cf = 0.031 / Re^(1/7)                 when Ra <= 50 micron
      fully rough    Cf = (1.89 + 1.62*log10(L/Ra))^-2.5   when Ra >  50 micron
      F = 0.5 * rho * V^2 * Cf * area,  summed over the laminar and turbulent runs
      delta_lam = 5L/sqrt(Re_L),  delta_turb = 0.16*(L-x_tr)/Re^(1/7)

  Reimplemented in Python it reproduces SWD's own `_Fx_friction_n` to within 1-3%
  median. Note the turbulent branch gives `F ~ V^(13/7) = V^1.857`, so total drag
  does **not** scale as a clean `V^2`.
- **`element.actualiser_couche_limite()` reads `planche_ref.vitesse_flux_relatif_ms`**
  for the friction velocity - i.e. the board's own stored setting, the field exported
  as `board_speed_setting_ms`.
