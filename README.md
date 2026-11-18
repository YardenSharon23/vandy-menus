# Vandy Menus

Daily snapshot of Vanderbilt Campus Dining menus with nutrition facts, scraped from
[NetNutrition](https://netnutrition.cbord.com/nn-prod/vucampusdining).

- `scrape-menus.ps1` — the scraper (PowerShell). Run `./scrape-menus.ps1` for today's menus.
- `.github/workflows/scrape.yml` — runs the scraper every morning and commits the results.
- `docs/menus/YYYY-MM-DD.json` — one file per day (today and tomorrow, last 14 days kept).
- `docs/menus/index.json` — list of available dates.

Served with GitHub Pages at `https://<user>.github.io/<repo>/menus/<date>.json`.

Each item has: `name`, `station`, `serving`, `grams`, `calories`, `protein_g`, `carbs_g`,
`fat_g`, `sat_fat_g`, `fiber_g`, `sugar_g`, `sodium_mg`, `tags` (Vegan, Halal, …).

Nutrition data comes from Vanderbilt Campus Dining and may contain their errors.
