# Atopic eczema and comorbidities in VA + Medicare data (SAS code)

SAS programs used to build the cohort and run the analyses for the manuscript
*[title / citation to be added]*.

**No data are included.** The analyses use VA Corporate Data Warehouse and Medicare data that cannot be shared.

## Programs

| File | Purpose |
|---|---|
| `config.sas` | Paths, data-source names, and analysis switches (edit this only) |
| `macros.sas` | Shared macros: cohort building, diagnosis flagging, CDW pulls, risk models |
| `01_cohort_and_main_analysis.sas` | Cohort (VA visit in 2018), eczema definition, covariates, comorbidities, ADI, severity, main RR/OR analyses |
| `02_sensitivity_age65plus.sas` | Main analyses restricted to age 65+ |
| `03_sensitivity_2021_index.sas` | Cohort rebuilt with a 2021 index year |

Run in order 01 -> 02 -> 03. Programs 02 and 03 read datasets written by 01.

## Study definitions (summary)
- **Cohort:** adults born on/before 1 Jan 1970 with >=1 VA visit in the index year (2018; 2021 in sensitivity). Index date is the first visit.
- **Eczema:** ICD-10 L20 or L30 in VA, Medicare, or CDW data within +/-2 years of the index year.
- **Comorbidities:** 31 conditions from ICD-10 code lists in the year before and after the index year.
- **Severity:** phototherapy/procedure CPT codes or systemic drugs (methotrexate, mycophenolate, azathioprine,
  cyclosporine, dupilumab) in the index year.
- **Effect measures:** unadjusted and adjusted risk ratios (log-binomial), odds ratios (logistic), and risk differences.

## Requirements
SAS 9.4 with SAS/STAT and SAS/ACCESS to SQL Server, access to the data sources named in `config.sas`,
and the ICD-10 code-list spreadsheets (`ICD_FILE_*` in `config.sas`).
`%stat_table` (Table-1 macro) is [included / not included].

## Key options (`config.sas`)
- `DX_SCOPE` - search all diagnosis fields (`ALL`) or only the first field (`FIRST`)
- `GENMOD_OPTS` - extra GENMOD options for the log-binomial models
- `BIRTH_CUTOFF`, `RACE_IF_MISSING`, `LEVEL1_LABEL` / `LEVEL2_LABEL`

## Contact
[Name, email]
