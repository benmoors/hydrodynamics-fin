# 📘 English column names for SWD data

### 🎯 Learning Objectives

> - Find the English name of any SWD field, and the French name it came from
> - Know how each translation was checked, and how far to trust it
> - Put the English headings back after a new extraction

---

## 1. What changed

ShaperWaveDynamics (SWD) is French software, and it names its data fields in French.
`SWD/tools/extract_board.ps1` and `SWD/tools/phase2/swd_solver_table.py` copy those names straight into
their CSV headers. On 2026-10-21, `SWD/tools/translate_columns.py` renamed them through one map,
[`SWD/tools/column_names.csv`](../tools/column_names.csv): 79 rows, each with the English name, its meaning,
a confidence grade and the sources behind it.

Only French names changed. Names that were already English kept their spelling, so the live-solver
`lift_n` and the top-level `lift_total_n` still differ (Benjamin, 2026-10-21). Only the header line of
each file was rewritten; every data row is byte for byte what it was.

| Files | Count | Headings renamed in each |
|---|---:|---:|
| `SWD/data/<board>/board.csv` | 13 | 27 |
| `SWD/data/<board>/elements.csv` and `sub_elements.csv` | 28 | 24 |
| `SWD/data/live_solver/default_shortboard/*/solver_points_all_columns.csv` | 2 | 41 |

That is 1,105 headings in 43 files. The top-level `boards.csv`, `elements.csv` and `operating_points.csv`,
the per-board `operating_points.csv` and `geometry_contact.csv`, and `computed-data/` were already English.

To put the English names back after a new extraction or a new live-solver table:

```
py -3.14 SWD/tools/translate_columns.py               # every per-board and live-solver CSV
py -3.14 SWD/tools/translate_columns.py --self-test
```

> **Point of note:** re-running `extract_board.ps1` writes the French headers again. `SWD/tools/make_data_dictionary.py`
> reads the English names, so run `translate_columns.py` before it. The extractor itself was deliberately left untouched: it
> carries a clean SQA verdict.

---

## 2. How a name was chosen

1. **One SWD field, one English name.** Where the repository already had an English name for a field
   (the maps in `SWD/tools/swd_extract.ps1` that build the top-level CSVs), the per-board and live-solver
   columns reuse it, so the same quantity has the same name in every file. Where the evidence prefers
   another word, the `meaning` column says so and the name is left alone.
2. **The developer's own English comes before a dictionary, and project facts come before both.**
   `vitesse_flux_relatif_ms` is literally "relative flow speed", but it became `board_speed_setting_ms`,
   because it is the board's stored setting and not the speed the scan ran at (`CLAUDE.md` § 6).
3. **No name reuses a symbol the paper defines.** Charles et al. (2026) use Ra for Radicality, V for gauge
   voltage, α for tail flexion, Rx/Ry/Rz for rotation speeds, and "trimming" for a phase of the ride. So
   the planing angle stays `planing_angle`, never "trim".
4. **Lower-case snake_case, keeping SWD's unit suffix, and no invented units.** `pression_statique` is
   `static_pressure`, not `static_pressure_pa`: SWD gives no unit, and Pa is only inferred from the
   stored value of 100000.
5. **French grammar counts as French.** "Surface" meaning area, French word order (`deviation_rail` to
   `rail_deviation`, `index_point_contact` to `contact_point_index`) and "gr" for grams were all
   translated. `lamda_Savitsky` (a misspelling, not French), `Ra_micron`, `index_` and every `Fx_*`,
   `projection_*` and `Moment_*` name were left as they are.

---

## 3. How each translation was checked

Each row of the map lists its sources by key. Most rows cite at least one translation source and at
least one domain or project source. Rows built from everyday words or cognates (`name`,
`first_attack_element_index`, `total_mass_resin_kg`) cite one, and the `sources` column shows exactly
which. Every page below was opened on 2026-10-21, except MDPI, which refuses automated access.

| Key | Source |
|---|---|
| SWD-EN, SWD-FR | The SWD developer's paired English and French pages, the strongest source: [methods](https://www.surfhydrodynamics.com/en/methodes%20calculs%20surf.html) ([FR](https://www.surfhydrodynamics.com/fr/methodes%20calculs%20surf.html)), [axes](https://www.surfhydrodynamics.com/en/repere_axe_surf.html), [buoyancy](https://www.surfhydrodynamics.com/en/flotaison_stabilite.html), [rail and boundary layer](https://www.surfhydrodynamics.com/en/rail_couche_limite.html) ([FR](https://www.surfhydrodynamics.com/fr/rail_couche_limite.html)), [turning](https://www.surfhydrodynamics.com/en/viragesurf.html), [drift](https://www.surfhydrodynamics.com/en/drift_surf.html), [relative flow](https://www.surfhydrodynamics.com/en/flux%20relatif.html) |
| OQLF | Office québécois de la langue française, [Grand dictionnaire terminologique](https://vitrinelinguistique.oqlf.gouv.qc.ca/), a terminology bank. Fiches used include [portance](https://vitrinelinguistique.oqlf.gouv.qc.ca/fiche-gdt/fiche/8400979/portance), [décollement](https://vitrinelinguistique.oqlf.gouv.qc.ca/fiche-gdt/fiche/8465895/decollement), [chanfrein](https://vitrinelinguistique.oqlf.gouv.qc.ca/fiche-gdt/fiche/17052830/chanfrein), [ligne de flottaison](https://vitrinelinguistique.oqlf.gouv.qc.ca/fiche-gdt/fiche/8881568/ligne-de-flottaison) and [roulis](https://vitrinelinguistique.oqlf.gouv.qc.ca/fiche-gdt/fiche/8354265/roulis) |
| LAR | [Larousse French-English](https://www.larousse.fr/dictionnaires/francais-anglais/portance) |
| WR | [WordReference French-English](https://www.wordreference.com/fren/d%C3%A9crochage) |
| WIKT | [Wiktionary](https://en.wiktionary.org/wiki/tra%C3%AEn%C3%A9e) |
| LIN | [Linguee](https://www.linguee.com/french-english/translation/veine+fluide.html), a bilingual corpus showing terms in context |
| TS | [techno-science.net](https://www.techno-science.net/definition/1627.html): French Cz is English CL |
| SAV | Savitsky (1964) planing notation, read through two open implementations because the original was not reached: [OpenPlaning](https://raw.githubusercontent.com/elcf/python-openplaning/master/openplaning/openplaning.py) and the [nauticalsolver Savitsky calculator](https://nauticalsolver.com/calculators/resistance/savitsky/savitsky.php) |
| WP | Wikipedia, [Ship motions](https://en.wikipedia.org/wiki/Ship_motions) and [Planing (boat)](https://en.wikipedia.org/wiki/Planing_(boat)) |
| SR | Surfresearch.com.au glossary, [C](https://www.surfresearch.com.au/agc.html) and [T](https://www.surfresearch.com.au/agt.html) |
| AKU, OPS | Hollow-wood board builders: [AkuShaper](https://help.akushaper.com/article/17-hollow-wood-surfboards) and [OpenShaper](https://openshaper.com/build-a-hollow-wooden-surfboard) |
| GRAIN | Grain Surfboards [glassing manual](https://cdn.shopify.com/s/files/1/0000/5597/files/GlassManual_2017.pdf) |
| FALK | Falk et al. (2019), surfboard CFD, [record](https://cris.fau.de/publications/223556650) (abstract only) |
| MDPI | J. Compos. Sci. 7(9):351, [areal weight](https://www.mdpi.com/2504-477X/7/9/351). Search snippet only; the page refuses automated access |
| XTR | The English names already in `SWD/tools/swd_extract.ps1` (lines 959-988 and 1066-1081) |
| DDG | The descriptions in `SWD/tools/make_data_dictionary.py` |
| CLAUDE6 | `CLAUDE.md` § 6 |
| DATA | The values stored in `SWD/data/` |

**Not reached:** IATE and TERMIUM Plus (the two big terminology banks), ScienceDirect, the ITTC
Dictionary of Ship Hydrodynamics, Faltinsen, and Hendricks (1969). No English SWD manual, and no
screenshot of English interface labels, was found online.

**Confidence.** H: the sources agree and domain usage matches. M: the words are certain, but SWD does not
document exactly which quantity it is. L: the meaning is unclear, so the name is a careful literal
reading, not a known one.

> **Point of note — the paper does not settle these names.** Charles et al. (2026), *Results in
> Engineering* 29:108868 ([doi:10.1016/j.rineng.2025.108868](https://api.crossref.org/works/10.1016/j.rineng.2025.108868)),
> is about an instrumented surfboard: IMUs and strain gauges. It never uses lift, drag, planing,
> wetted, rail, Savitsky or SWD. It fixes only the axis words (X roll, Y pitch, Z yaw) and nose and
> tail, which the names follow, and the symbols in rule 3, which the names avoid.

---

## 4. Choices worth knowing

| SWD | English | Why |
|---|---|---|
| `index_point_decrochage` | `separation_point_index` | Every dictionary gives "stall", but stall means lost lift on a wing. SWD's English says "detachment point" and "separation of the boundary layer", and the planing literature says flow separation |
| `…veine…` | `jet_…` | The dictionaries know "veine" only as a vein. SWD-EN translates it literally as "vein of fluid", then models it "as a jet in the open air" |
| `angle_planing_effectif_deg` (live solver, already `planing_angle_deg`) | unchanged | Savitsky calls the hull's angle the trim τ. A rolled board's local planing angle is not the hull trim, and the paper uses "trimming" for something else |
| `Vecteur_flottaison_n`, `hauteur_flottaison_mm` | `buoyancy_vector_n`, `waterline_height_mm` | "Flottaison" is buoyancy (LAR, WIKT) or waterline (WR, OQLF). SWD computes a buoyancy force and a cutting-plane height, so each name follows what it measures |
| `volume_flotaison_litres` | `volume_float_l` | The literal reading is a submerged volume, and SWD's buoyancy page does compute one. But on the two boards where this field is set, it equals `volume_shape_litres` exactly, so it holds the whole board's volume. The existing name claims no more than "float" |
| `epaisseur_ames_bois_mm`, `…plaquage…`, `…sections…` | `wood_spine_…`, `wood_skin_…`, `wood_rib_…` | The dictionaries say core, veneer and section. In surfing "core" means the foam, and hollow-wood builders use exactly this spine, skin and rib triad. All three are 4 mm on two boards and 0 on the other eleven |
| `chanfrein_nose` | `nose_chamfer` | Every dictionary gives chamfer first. Shapers say bevel, mostly for rails |
| `rayon_planning_m` | `turn_radius_m` | "Planning" is French for a schedule. SWD spells planing that way, and its English page says "radius of the turn" |
| `epaisseur_relative_au_wide_point` | `relative_thickness_at_wide_point` | Ambiguous in French. The data settles it: 0.0105 to 0.0425 across the 13 boards. Read as thickness ÷ width, `default_longboard` (0.021) would be 1.2 cm thick, so it is thickness ÷ length, which `src/data.py` already assumed |
| `Cz_effectif` | `cl_effective` | French writes the lift coefficient Cz, English CL |

---

## 5. What is still uncertain

Rows graded L or M-L are careful literal readings: `plane_delta_deg`, `attack_line_point_1_index` and
`attack_line_point_2_index`, `internal_elements`, `initial_angle_deg`, `hydrostatic_fx_active_element_n`,
the three `bottom_line_*` lists, both widening-ratio lists, `projection_weighted_displacement_horizontal_n`,
`wood_spine_thickness_mm` and the two `roll_section_*_point_index` columns.

> **Aside:** the developer's site mentions English versions of its Shape Room tutorials, so SWD may have
> an English interface. Its own labels would settle most of these rows. That needs SWD open, and it has
> not been tried.

These were found during the check but left alone, because the names are not French:

- `Ra_micron` (surface roughness) shares its symbol with the paper's Radicality Ra.
- `drag_rail_n` and `drag_rocker_n` say drag for a force that can be thrust.
- `hydrostatic_fx_n` grows with speed, which a hydrostatic force should not.

---

## 🤖 AI Acknowledgment

**What AI was used.** Claude Opus 5.5 via Claude Code 2.1.306 (Anthropic), 21 October 2026, with four of its
read-only research subagents. The full record is `AI-USE.md` §§ 2, 4 and 5.

**How AI was used.** AI searched the dictionaries, the terminology bank, the SWD developer's site and the planing
literature, proposed every English name, wrote `translate_columns.py` and `column_names.csv`, renamed the headings and
drafted this page. Translating every SWD/data CSV, leaving the extractor untouched, changing only the French names and
checking each one against several sources and the paper were my decisions (`AI-USE.md` § 4).

**Human oversight and responsibility.** Every page cited above was fetched again to confirm it exists, and the
developer's wording behind the key choices was re-read on his pages. The rename changes only header lines, which
`git diff` confirms file by file; the tests pass, and the trajectory model reproduces its committed output byte for
byte. The names are mine to review before submission, starting with the rows § 5 lists as uncertain.

**Errors the AI made.** It first quoted the thickness ratio's range from three boards as if it held for all, and read
`volume_float_l` as a submerged volume until the data showed it is the whole board's volume (E127). It also rebuilt the
HTML docs in a way that would have committed the OneDrive path, and reverted that before any commit (E128).
