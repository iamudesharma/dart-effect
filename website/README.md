# Effect Dart website

Static documentation and progress website for the five Dart packages. The first
preview is owner-private. It is an independent project inspired by Effect, not
an official Effect-TS site. Packages remain development candidates.

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
- Package pages are generated from package READMEs; guides come from
  `docs/effect-port`. Edit those sources, then rebuild.
- Progress comes from the three validation JSON reports under `docs/effect-port`.
  The builder checks recorded source hashes and stops if evidence is stale.
  Rerun relevant package checks and refresh their reports before rebuilding.
- Styles and the original SVG mark are maintained in `dist/styles.css` and
  `dist/favicon.svg`; generated HTML and evidence are committed for static hosting.

The counts combine dated validation runs, not one fresh aggregate run. Local
OpenAI HTTP/SSE checks do not prove live model acceptance. Production database
acceptance and pub.dev release are separate future goals.

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
workflow using that existing project ID and preserve private access. Temporary
preview/deployment files are ignored under the repository's `.sites-runtime/`.
This directory is excluded from the core Dart package archive via `.pubignore`.
