# Dictionary Sources

Source codes used in the `source` column of the three textNet NER dictionaries.
Each entry in a dictionary carries one or more pipe-separated source codes indicating
the authoritative sources used to compile and verify that type of entry.

---

## Source Code Reference

| Code | Full Name | URL | Notes |
|------|-----------|-----|-------|
| `DWR-IRWM` | California Department of Water Resources — Integrated Regional Water Management Program | https://water.ca.gov/Programs/Integrated-Regional-Water-Management | Primary source for IRWM region definitions, participating agencies, and collaborative bodies. Includes the IRWM Plan database and grant recipient lists. |
| `DWR-SWP` | California Department of Water Resources — State Water Project | https://water.ca.gov/Programs/State-Water-Project | Authoritative for SWP facilities (dams, aqueducts, pumping plants, treatment plants), SWP contractors, and SWP Bulletin 132 (annual operations report). |
| `DWR-B118` | California Department of Water Resources — Groundwater Bulletin 118 | https://water.ca.gov/Programs/Groundwater-Management/Bulletin-118 | Authoritative for groundwater basin names, IDs, and boundaries. All 515 basins; designates "high" and "medium" priority basins under SGMA. |
| `DWR-SGMA` | California Department of Water Resources — Sustainable Groundwater Management Act Program | https://water.ca.gov/Programs/Groundwater-Management/SGMA-Groundwater-Management | Source for Groundwater Sustainability Agencies (GSAs), GSP submissions, and critically overdrafted basin designations. |
| `DWR-Delta` | California Department of Water Resources — Delta Stewardship Council / Delta context | https://deltacouncil.ca.gov/ | Sacramento-San Joaquin Delta feature names, levee system, conveyance alternatives. |
| `DWR-FloodMgmt` | California Department of Water Resources — Flood Management Program | https://water.ca.gov/Programs/Flood-Management | Sacramento Valley flood infrastructure; CVFPB (Central Valley Flood Protection Board). |
| `SWRCB` | State Water Resources Control Board | https://www.waterboards.ca.gov/ | Authoritative for water rights, NPDES permits, 303(d) impaired water bodies, and water quality objectives. Also source for Regional Water Quality Control Board (RWQCB) names and jurisdictions. |
| `USBR-CVP` | U.S. Bureau of Reclamation — Central Valley Project | https://www.usbr.gov/mp/cvp/ | Authoritative for CVP facilities (dams, canals, pumping plants), CVP contractors, and CVP water allocations. Also see CVPIA (1992) implementation. |
| `USACE` | U.S. Army Corps of Engineers — Sacramento District | https://www.spk.usace.army.mil/ | Authoritative for federal flood control dams, channels, and levee projects in California. |
| `USGS-NHD` | U.S. Geological Survey — National Hydrography Dataset | https://www.usgs.gov/national-hydrography/national-hydrography-dataset | Authoritative for river, stream, lake, reservoir, bay, and wetland names and IDs. NHDPlus HR is the high-resolution version used for CA. |
| `USFWS-NWI` | U.S. Fish & Wildlife Service — National Wetlands Inventory | https://www.fws.gov/program/national-wetlands-inventory | Authoritative for wetland and marsh feature names and extents. |
| `SDWIS` | U.S. EPA — Safe Drinking Water Information System | https://sdwis.epa.gov/ | Federal registry of public water systems; source for water utility names, service area PWS IDs, and operator details. California data also available via SWRCB DDW. |
| `DPH` | California Department of Public Health — Drinking Water Program (now SWRCB DDW) | https://www.waterboards.ca.gov/drinking_water/programs/ | CA-specific registry of public water systems; utility names, service areas, and compliance status. |
| `CPUC` | California Public Utilities Commission — Water Division | https://www.cpuc.ca.gov/industries-and-topics/water | Authoritative for investor-owned water utilities (Class A, B, C, D). Utility names, service territories, and rate cases. |
| `BIA-Tribal` | Bureau of Indian Affairs — Tribal Leaders Directory | https://www.bia.gov/service/tribal-leaders-directory | Authoritative for federally recognized (FR) California tribes; official tribal names, addresses, and contact information. |
| `NAHC` | California Native American Heritage Commission | https://nahc.ca.gov/tribal-consultation/ab-52/tribal-contact-list/ | Source for non-federally recognized (NFR) California tribes; used for AB 52 / SB 18 tribal consultation. Entries marked NFR in dictionary notes. |
| `NRCS-RCD` | USDA Natural Resources Conservation Service — Resource Conservation Districts | https://www.nrcs.usda.gov/getting-assistance/other-soil-disturbance/resource-conservation-districts | National NRCS directory of RCDs. California-specific directory maintained by California Association of Resource Conservation Districts (CARCD): https://carcd.org/find-your-rcd/ |
| `FERC` | Federal Energy Regulatory Commission — Hydroelectric Licensing | https://www.ferc.gov/industries-data/hydropower | Authoritative for hydropower facility names, license holders, and project numbers (FERC P-numbers). |
| `CA-GOV` | General California State Government Sources | https://www.ca.gov/ | Used for state agencies, departments, and boards without a more specific source. Includes legislature, Governor's Office, and cross-agency directories. |
| `FED-GOV` | General Federal Government Sources | https://www.usa.gov/ | Used for federal agencies without a more specific source (e.g., USFWS, BLM, EPA regions). |
| `CA-LAW` | California Legislative Information | https://leginfo.legislature.ca.gov/ | Source for statutory/regulatory frameworks cited as named entities (e.g., SGMA, CVPIA, Delta Reform Act). |
| `CCC` | California Coastal Commission | https://www.coastal.ca.gov/ | Source for coastal development permits and desalination project review. |
| `OEHHA` | California Office of Environmental Health Hazard Assessment — CalEnviroScreen | https://oehha.ca.gov/calenviroscreen | Source for environmental justice community designations; used for EJ NGO coverage. |
| `MWD` | Metropolitan Water District of Southern California | https://www.mwdh2o.com/ | Member agency lists, facility descriptions, and SWP/CVP contract data for Southern California. |
| `LADWP` | Los Angeles Department of Water and Power | https://www.ladwp.com/ | Facility names, aqueduct system, and service area for LADWP. |
| `SFPUC` | San Francisco Public Utilities Commission | https://www.sfpuc.gov/ | Hetch Hetchy system, Bay Division, and SFPUC regional customer agency names. |
| `NGO` | Organizational websites and IRS Form 990 filings | https://projects.propublica.org/nonprofits/ | Used for environmental and EJ NGO names and aliases. ProPublica Nonprofit Explorer provides 990 data for name verification. |
| `LOCAL` | Local agency documentation | — | Used where primary documentation comes from individual agency websites, LAFCO filings, or IRWM plan stakeholder lists without a single authoritative registry. |
| `CalSim3` | DWR/USBR CalSim 3 Water Resources Model | https://github.com/CentralValleyModeling/calsim3-example | Used as a cross-reference to identify SWP Table A contractors, CVP exchange/refuge contractors, and Sacramento Valley service area entities. Key files: `Run/DeliveryLogic/SWP/Allocation/swp_contractor_perdel_A.wresl` (30 SWP Table A contractors), `Run/DeliveryLogic/CVP/MonthlyContractDefs.wresl` (CVP exchange and refuge limits). CalSim3 is a derived cross-reference source; authoritative sources for contractor names are DWR-SWP and USBR-CVP. |

---

## Coverage Notes

### What these sources do NOT cover
- **Historical/defunct agencies**: Names of agencies that merged, dissolved, or renamed were drawn from knowledge of CA water history and may not appear in current registries. Check DWR water rights database for historical water rights holders.
- **Private wells and small systems**: Systems serving fewer than 25 people are not in SDWIS and are not covered.
- **Informal place names**: Common informal names for features (e.g., "the Delta," "the Met") are included as aliases but won't appear in any official registry.

### Verification workflow (recommended)
For each dictionary entry, the canonical verification path is:

| Entity Type | Verify Via |
|------------|------------|
| Water utility (public) | SWRCB DDW public water system search |
| Water utility (IOU) | CPUC utility filings |
| Tribal entity (FR) | BIA Tribal Leaders Directory |
| Tribal entity (NFR) | NAHC Tribal Contact List |
| RCD | CARCD "Find your RCD" |
| GSA | DWR SGMA portal (GSA viewer) |
| River / stream name | USGS NHD (NHDPlus HR) |
| Groundwater basin name | DWR Bulletin 118 basin viewer |
| Dam | USACE National Inventory of Dams (NID): https://nid.sec.usace.army.mil/ |
| Aqueduct / canal | USBR or DWR project pages |
| SWP/CVP contractor | DWR-SWP Bulletin 132; USBR-CVP contract database; CalSim3 WRESL files |
| Treatment plant | SWRCB DDW or NPDES permit database |

---

*Dictionaries compiled for use with textNet (R package for event-based network extraction from IRWM plans). Last updated: April 2026.*
