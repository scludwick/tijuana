# IRWM Corpus Review
**Date:** April 10, 2026  
**Source:** `planlinks.csv` (285 entries, 48 regions), `raw_data/plan_pdfs/`, `int_data/plan_txts_raw/`

---

## Overview

The corpus tracks **48 IRWM regions** across three pipeline stages: (1) links catalogued in `planlinks.csv`, (2) PDFs downloaded to `plan_pdfs/`, and (3) PDFs converted to text in `plan_txts_raw/`. Gaps can occur at any stage. The analysis below covers all three.

Three regions (3 – Anza Borrego Desert, 39 – Upper Pit River Watershed, 47 – East Stanislaus) are in `planlinks.csv` with no year recorded and no downloaded files — they appear to be placeholders. Region 26 has a **duplicate key issue**: both "San Diego" and "Tuolumne-Stanislaus" share the number 26, so their file prefixes are indistinguishable.

---

## Full Corpus Status

| Reg | Region Name | planlinks yrs | PDF yrs | TXT yrs |
|-----|-------------|--------------|---------|---------|
| 1 | American River Basin | 2006, 2013, 2018 | 2013, 2018 | 2018 |
| 2 | Antelope Valley | 2007, 2013, 2019 | 2007, 2013, 2019 | 2007, 2013, 2019 |
| 3 | Anza Borrego Desert | — | — | — |
| 4 | Yosemite-Mariposa | 2014, 2016 | 2016 | 2016 |
| 5 | Coachella Valley | 2010, 2014, 2018 | 2010, 2014, 2018 | — |
| 6 | CABY (Cosumnes/American/Bear/Yuba) | 2007, 2014, 2021 | 2007, 2014, 2021 | — |
| 7 | East Contra Costa County | 2005, 2009, 2013, 2015, 2019 | 2005, 2009, 2013, 2019 | 2005, 2009, 2013, 2019 |
| 8 | Eastern San Joaquin | 2007, 2014 | 2007, 2014 | 2007 |
| 10 | Greater Los Angeles County | 2006, 2012, 2014 | 2012, 2014 | 2012, 2014 |
| 11 | Greater Monterey County | 2013, 2018 | 2018 | — |
| 12 | Imperial | 2012 | 2012 | — |
| 13 | Inyo-Mono | 2011, 2012, 2014, 2019 | 2011, 2012, 2014, 2019 | 2011, 2012, 2014, 2019 |
| 14 | Kaweah River Basin | 2018 | 2018 | 2018 |
| 15 | Kern County | 2011, 2020 | 2020 | 2020 |
| 16 | Madera | 2008, 2014, 2019 | 2008, 2014, 2019 | 2008, 2014, 2019 |
| 17 | Merced | 2013, 2018 | 2013, 2018 | 2013, 2018 |
| 18 | Mojave | 2004, 2014, 2018 | 2014, 2018 | 2014, 2018 |
| 19 | Mokelumne/Amador/Calaveras (MAC) | 2006, 2013, 2018 | 2006, 2013, 2018 | 2006, 2013, 2018 |
| 20 | Monterey Peninsula/Carmel Bay/So. Monterey | 2019 | 2019 | 2019 |
| 21 | North Coast | 2014 | 2014 | 2014 |
| 22 | North Sacramento Valley | 2006, 2013 | 2006 | — |
| 23 | Pajaro River Watershed | 2014, 2019 | 2014, 2019 | 2014, 2019 |
| 24 | Poso Creek | 2007, 2014, 2019 | 2007, 2014, 2019 | 2007, 2014, 2019 |
| 26 | San Diego | 2007, 2013, 2019 | 2007, 2013, 2019 | — |
| 36 | Tuolumne-Stanislaus | 2013, 2017 | 2013, 2017 | 2013, 2017 |
| 27 | San Francisco Bay Area | 2006, 2013, 2019 | 2006, 2013, 2019 | 2006, 2013, 2019 |
| 28 | San Luis Obispo | 2014, 2019 | 2019 | — |
| 29 | Santa Ana (OWOW/SAWPA) | 2010, 2014, 2018 | 2010, 2014, 2018 | 2018 |
| 30 | Santa Barbara County | 2007, 2013, 2019 | 2007, 2013, 2019 | — |
| 31 | Santa Cruz County | 2014, 2019 | 2014, 2019 | — |
| 32 | South Orange County WMA | 2013, 2018 | 2013, 2018 | — |
| 33 | Southern Sierra | 2014, 2018 | 2014, 2018 | 2014, 2018 |
| 34 | Tahoe-Sierra | 2019 | 2019 | 2019 |
| 35 | Tule | 2018 | 2018 | 2018 |
| 37 | Upper Feather River Watershed | 2005, 2016 | 2005, 2016 | 2005, 2016 |
| 38 | Kings Basin Water Authority | 2007, 2012, 2018 | 2018 | 2018 |
| 39 | Upper Pit River Watershed | — | — | — |
| 40 | Upper Sacramento-McCloud | 2013, 2018 | 2013, 2018 | 2018 |
| 41 | Upper Santa Clara River | 2008, 2014 | 2008, 2014 | 2008, 2014 |
| 42 | Upper Santa Margarita | 2007, 2014 | 2014 | — |
| 43 | Watersheds Coalition of Ventura County | 2006, 2014, 2019 | 2006, 2014, 2019 | 2006 |
| 44 | Westside-San Joaquin | 2001, 2014, 2019 | 2014, 2019 | 2019 |
| 45 | Westside Sacramento (Yolo/Solano/Napa/Lake/Colusa) | 2013, 2019 | 2019 | — |
| 46 | Yuba County | 2008, 2015, 2018 | 2008, 2018 | 2018 |
| 47 | East Stanislaus | — | — | — |
| 48 | Fremont Basin | 2019 | 2019 | 2019 |
| 49 | Lahontan Basin | 2016, 2019 | 2019 | 2019 |
| 50 | San Gorgonio | 2018 | 2018 | 2018 |

---

## Gap 1 — Catalogued in planlinks but PDF not downloaded (15 region-years)

The `comment` column in `planlinks.csv` explains why each is missing. Nearly all are genuinely unavailable — not download failures. Only one (Region 22, 2013) has a URL on record; the rest were researched and either no plan was ever published or the document couldn't be located.

| Reg | Region | Year | Reason per planlinks comment |
|-----|--------|------|------------------------------|
| 1 | American River Basin | 2006 | No URL recorded |
| 4 | Yosemite-Mariposa | 2014 | No 2014 plan found |
| 7 | East Contra Costa County | 2015 | Cannot access document (access denied) |
| 10 | Greater Los Angeles County | 2006 | Can't find original plan |
| 11 | Greater Monterey County | 2013 | Can't find original |
| 15 | Kern County | 2011 | Can't find original |
| 18 | Mojave | 2004 | No original plan found |
| 22 | North Sacramento Valley | 2013 | URL broken; note: Sacramento Valley may have opted out of IRWM program |
| 28 | San Luis Obispo | 2014 | No URL recorded (not yet researched) |
| 38 | Kings Basin Water Authority | 2007, 2012 | No plan found for either year |
| 42 | Upper Santa Margarita | 2007 | No original plan found |
| 44 | Westside-San Joaquin | 2001 | Plan started but never published |
| 45 | Westside Sacramento | 2013 | No 2013 plan found |
| 46 | Yuba County | 2015 | No plan found |
| 49 | Lahontan Basin | 2016 | Can't find original |

**Region 28 (San Luis Obispo, 2014)** is the one genuinely unresearched item — worth a quick search. All others were investigated and are likely not publicly available. Region 22's note about Sacramento Valley opting out of the IRWM program is worth confirming; if true, it limits the longitudinal series for that region.

---

## Gap 2 — PDF present but not converted to text (19 region-years across 16 regions)

These PDFs are in `plan_pdfs/` but have no corresponding file in `plan_txts_raw/`, so they're invisible to any NLP analysis.

| Reg | Region | Unprocessed year(s) |
|-----|--------|---------------------|
| 1 | American River Basin | 2013 |
| 5 | Coachella Valley | 2010, 2014, 2018 *(all three)* |
| 6 | CABY | 2007, 2014, 2021 *(all three — including newest version)* |
| 8 | Eastern San Joaquin | 2014 |
| 11 | Greater Monterey County | 2018 |
| 12 | Imperial | 2012 |
| 22 | North Sacramento Valley | 2006 |
| 26 | San Diego | 2007, 2013, 2019 *(all three — web downloads, may not be valid PDFs)* |
| 28 | San Luis Obispo | 2019 |
| 29 | Santa Ana (OWOW) | 2010, 2014 |
| 30 | Santa Barbara County | 2007, 2013, 2019 *(all three)* |
| 31 | Santa Cruz County | 2014, 2019 *(both)* |
| 32 | South Orange County WMA | 2013, 2018 *(both)* |
| 40 | Upper Sacramento-McCloud | 2013 |
| 42 | Upper Santa Margarita | 2014 |
| 43 | Watersheds Coalition of Ventura County | 2014, 2019 |
| 44 | Westside-San Joaquin | 2014 |
| 45 | Westside Sacramento | 2019 |
| 46 | Yuba County | 2008 |

Highest priority: **Regions 5, 6, 30, 31, 32** are entirely absent from the text corpus despite having multiple downloaded PDFs. Re-running `pdftotext.R` with `CLOBBER <- FALSE` should pick these up automatically since they match the filename pattern.

---

## Gap 3 — New plan iterations published after corpus collection

These are versions that postdate the newest entry in `planlinks.csv` and need to be added to the database.

### Confirmed

| Reg | Region | Latest in planlinks | New version | Source |
|-----|--------|--------------------|-----------|-|
| 19 | MAC | 2018 | **2022 addendum** | https://www.umrwa.org/the-mac-plan |
| 10 | Greater LA County | 2014 | **2024 documents** | https://pw.lacounty.gov/core-service-areas/water-resources/greater-los-angeles-irwm/ |
| 18 | Mojave | 2018 | **2024 update (in progress)** | https://www.mojavewater.org/irwmp/ |

Note: CABY's 2021 plan is already in `planlinks.csv` and `plan_pdfs/` — it just hasn't been processed to text (see Gap 2).

### Likely (Prop 1 Round 2 grant cycle, 2022–2023)

DWR's 2022 grant guidelines introduced new requirements for climate vulnerability assessment, DAC integration, and tribal consultation. Regions needed a current accepted plan to access the 2023 $201M award round. The following regions have plans from 2018 or earlier and almost certainly produced addenda or updates to qualify — but those documents are not yet in `planlinks.csv`:

Regions 14 (Kaweah), 17 (Merced), 21 (North Coast), 29 (Santa Ana/OWOW), 33 (Southern Sierra), 35 (Tule), 37 (Upper Feather River), 40 (Upper Sacramento-McCloud), 41 (Upper Santa Clara River), 46 (Yuba County).

Regions with 2019 plans (2, 7, 13, 16, 23, 24, 27, 34, 44, 48, 49) are less likely to have full updates but may have project list addenda.

---

## Data Quality Notes

**Region 36 (Tuolumne-Stanislaus):** Was erroneously recorded as Region 26 in `planlinks.csv`. Fixed on 2026-04-10 — updated to `36 - Tuolumne-Stanislaus` in planlinks.csv and renamed all PDF/TXT files from `Region_26_` to `Region_36_` prefix.

**Region_NA file:** A file `Region_NA_2012_GLAC_OSHARP_Appendices_Final` exists in both `plan_pdfs/` and `plan_txts_raw/` with no matching entry in `planlinks.csv`. GLAC = Greater Los Angeles County, so this is likely a stray appendix from the 2012 Greater LA plan that was downloaded outside the normal pipeline.

**Placeholder regions:** Regions 3, 39, and 47 appear in `planlinks.csv` with no year and no files. They may be regions where no plan has been published, or where the URL was never identified.
