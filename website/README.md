# Effect Dart website

Static documentation and progress website for the five Dart packages. The hosted site is public; preserve its current audience. It is an independent project inspired by Effect, not
an official Effect-TS site. All five packages are published on pub.dev, with PostgreSQL at 0.0.2 and the others at 0.0.1.

## Build and preview

From the repository root:

```sh
python3 website/build.py
python3 website/check.py
python3 -m http.server 8765 --bind 127.0.0.1 --directory website/dist
```

Open `http://127.0.0.1:8765/`. Python uses only its standard library. The checker
also uses an installed Node executable to syntax-check temporary browser scripts;
there is no npm installation, dependency manifest, or Node application source.
The static pages use a small embedded browser script for search and goal filters.

## Update content

- Edit `content/getting-started.md` and `content/goals.json` for the introduction
  and roadmap. Goal status is versioned editorial data, not live agent activity.
  Roadmap phases distinguish released scope, ordered next priorities and future
  proposals. Upcoming goals require prerequisites and completion criteria.
  After editing goals, run `python3 website/roadmap.py --write` to update the root
  README, then build and check the site. The build rejects a stale README roadmap.
- Package pages are generated from package READMEs; guides come from
  `docs/effect-port`. Edit those sources, then rebuild.
- Progress comes from the validation JSON reports under `docs/effect-port`.
  The builder checks published runtime source hashes and recorded acceptance
  hashes. The registry snapshot in `content/releases.json` records exact releases
  and narrowly documented historical metadata / dartdoc changes. Any other
  source mismatch stops the build; rerun relevant checks before rebuilding.
- Styles and the original SVG mark are maintained in `dist/styles.css` and
  `dist/favicon.svg`; generated HTML and evidence are committed for static hosting.

The counts combine dated validation runs, not one fresh aggregate run. Local
OpenAI HTTP/SSE checks do not prove live model acceptance. Production database
acceptance remains a separate future goal; package publication is complete.

## Validation performed on 7 October 2026

`build.py` generated 15 routes with matching implementation evidence hashes.
`check.py` passed for 16 HTML files, checking local links, assets, anchors,
unique IDs, one primary heading, search data, and browser script syntax.

The local browser preview was checked at 375 × 812 and 1200 × 900. Homepage and
progress layouts fit the mobile document width; the menu, documentation search,
OpenAI guide navigation, and roadmap filters worked. The Active filter correctly
showed no active goals, and Awaiting input showed live OpenAI acceptance. No
browser console errors were observed during these checks. Dart suites were not
rerun for this website-only change; their dated evidence is displayed separately.

The Site configuration is in `.openai/hosting.json`. Deploy through the Sites
workflow using that existing project ID and preserve the current public audience. Temporary
preview/deployment files are ignored under the repository's `.sites-runtime/`.
This directory is excluded from the core Dart package archive via `.pubignore`.

Live acceptance update: two native Responses smoke checks passed on 7 October
2026. The separate manual record is openai-live-validation.json; these checks
are not added to the automated VM/Chrome totals. Broader live coverage remains
a separate roadmap goal.

## Publication update on 9 October 2026

The homepage, package guides, getting-started instructions, progress and roadmap
reflect hosted releases. Every package has a pub.dev link and its current version.
PostgreSQL 0.0.2 has a verified hosted score of 160/160. Test counts retain their
dated release/patch acceptance records; publishing is separate from production
acceptance. Published runtime source files were compared with downloaded registry
archives before the release snapshot was recorded.

The publication-update build generated 15 routes. The checker passed for all 16
HTML pages, including local routes, assets, anchors, search data, heading structure
and embedded script syntax. No Dart runtime tests were rerun for this site-only
update; the site presents the dated package release and PostgreSQL patch evidence.

## Roadmap update on 9 October 2026

Six milestones are delivered, none is in progress, two are planned, one awaits
API-enabled test access, and four are future proposals. Each future milestone
has prerequisites and completion criteria; no release dates are promised.
The root README and hosted roadmap share `content/goals.json`. Filters include
proposals and hide groups with no matching goals. The existing recorded package
test counts remain distinct from this documentation-only validation.

## Sequential SQL acceptance update on 9 October 2026

Production SQL acceptance is in progress. SQL-P1 (isolated root/intermediate
CA trust and hostname rejection) passed six real-driver checks with no skips;
connection-loss/pool recovery is next. Ordered completion criteria are in
`docs/effect-port/acceptance-plan.md`. The new evidence is displayed separately
from the 207/167 dated release totals. The build generated 16 routes and the
checker passed for 17 HTML pages. Maintained Dart analysis, core VM tests, type
fixtures and adapter classification checks passed; existing real transaction
suites were not rerun in this TLS-only task.

## Performance evidence update on 10 October 2026

The OpenAI performance guide includes repeated native AOT SDK/Effect comparisons,
post-GC retention checkpoints and six real macOS Flutter profile runs. Progress
links to this guide, with raw evidence downloadable separately from functional
release totals. Runtime and benchmark source hashes are verified by the build;
failed or partial benchmark reports cannot be displayed as completed acceptance.
