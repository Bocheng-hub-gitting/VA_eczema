# Review of the three eczema SAS programs

Reviewed: `1. Cohort.sas`, `2. Sensitivity_analysis.sas`, `3. Sensitivity_analysis1.sas`.
Cleaned versions are in this folder (`01_`, `02_`, `03_`, plus `config.sas`, `macros.sas`).

**Important caveat:** I could not run SAS here. The review comes from reading the code, and the cleaned
code is untested. Run it, then compare the counts against `qc_expected_counts_PRIVATE.txt`.
Expect differences wherever a fix below changes the logic.

---

## A. Problems that change results (fix before submission)

1. **Medicare diagnoses were never used for comorbidities 1-29** (cohort + both sensitivity programs).
   The Medicare patient table creates the variable `mediare_&disease_cat` (typo), but the merge tests
   `medicare_&disease_cat`. That variable does not exist, so it is always missing. Comorbidity flags 1-29 came from
   VA (and CDW in the main program) only. Because comorb_15/19/22 feed Metabolic Syndrome, #20 is affected too.
   Fracture, skin infection, and the MS/insulin-resistance codes did use Medicare.
   *Fixed* in `%any_dx` / `%comorb_flags`.

2. **Only the first diagnosis field was searched** (`do i=1 to 1`) for eczema, rhinitis, and comorbidities 1-29.
   For VA this is DXF2, which is not the primary diagnosis (DXPRIME). For Medicare it is ICD_DGNS_CD1.
   The metabolic-syndrome, insulin-resistance, skin-infection, and fracture code used `dim(DX)` (all fields),
   so the definitions were inconsistent. Eczema is partly rescued in the main analysis because CDW is added, but not in program 3 (Medicare part).
   *Handled with the switch* `DX_SCOPE` in `config.sas` (default `ALL`; set `FIRST` to reproduce the old behavior).

3. **GENMOD `intercept=-4`** is used on every log-binomial model. Check in the output whether the Intercept row is
   exactly -4.0000 with a standard error of 0 or missing. If so, the intercept was fixed rather than used as a
   starting value, and all adjusted RRs are biased. Kept as-run in `GENMOD_OPTS` (config) so you can test it.
   If convergence is the issue, a modified Poisson (`dist=poisson link=log` with `repeated subject=`) is the usual alternative.

4. **Wrong ESTIMATE statement for the 2-level exposure**: `Estimate ... Eczema 1 -1`. With `param=reference` there is
   one eczema parameter, so the contrast should be `Eczema 1`. The `1 -1` form can give the wrong sign or an inverted RR.
   (The 3-level macros correctly use `1 0` and `0 1`.) The comment "some of the RR<1 for moderate eczema" in
   program 3 may be related. *Fixed.*

5. **Age filter looks wrong or not meaningful in program 2.** 2,371,556 of 2,372,820 people (99.9%) are "65+".
   The cohort includes anyone born on or before 1970 (age 48+ in 2018), so a large share should be under 65.
   Check `age` and the N printed by the QC step. The same N is printed in both places in the original, which suggests a copy-paste.

6. **Birth-year rule contradicts the header.** The code deletes `DOB > 01Jan1970`, which keeps people born *on or before* 1970.
   The header says "born after 1970". The paper says "over age 50", and someone born in 1970 is 48 at index.
   Decide which is intended. It is now `BIRTH_CUTOFF` in config.

7. **Date upper bounds drop the last day.** SQL pulls use `< '2018-12-31'` / `< '2020-12-31'` / `< '2021-12-31'`,
   which excludes Dec 31 (severity CPT in 2018 and 2021, CDW diagnoses in 2020). The inpatient `in2` pull
   uses 2022 while the others use 2020. *Fixed*: `[Jan 1 lo, Jan 1 hi)`.

8. **Inconsistent CDW inpatient diagnoses.** Main program: principal diagnosis only (`OrdinalNumber` 1 / 0). Program 3: all diagnoses.
   Now an explicit option `principal_only` (Y in program 01, N in program 03). Decide whether that is intended.

9. **Race handling.**
   - Missing race is set to WHITE. Please justify this or use "Unknown".
   - The race x ethnicity inner joins drop patients missing either record and multiply rows, so `col1/col2`
     depended on arbitrary row order. Now sorted deterministically. Hispanic = any Hispanic record.
   - The first race alphabetically wins when several are recorded.

10. **ADI "other years" rule**: the code sorts by `numscrssn index_yymm` (index date, constant within a patient) and takes the last row.
    So it returns the highest ADI rank across years, not the most recent year. Preserved and documented. Confirm it is the intent.
    Single imputation (`nimpute=1`) understates uncertainty; program 01 includes the comorbidity flags in the
    imputation model, program 03 does not.

11. **Metabolic syndrome / insulin resistance codes.** `E88811/E88818/E88819` did not exist before Oct 2023,
    yet the log shows 8,621 Medicare patients flagged for 2017-2019 (and 0 in VA/CDW). Look at what codes
    matched (possible `in:` prefix match against 5-character `E8881`). Metabolic syndrome uses exact match, insulin resistance uses prefix match.

12. **"phototherapy" flag** uses CPT/HCPCS codes that include methotrexate, cyclosporine, and azathioprine HCPCS,
    unclassified drug codes (C9399, J3590), and 96372 (therapeutic injection). That is why ~66,000 patients matched.
    Renamed `phototherapy_cpt`. Confirm the severity definition matches the protocol.

13. **Label inconsistency**: `eczema1` is labelled "mild" in the data and "Moderate" in the outputs. Set `LEVEL1_LABEL`.

14. **comorb_sum** excludes #18 and #25 but includes both #7 (any cutaneous infection) and #31 (skin infection),
    and includes #20 (derived from #15/#19/#22, so partly double counted). Confirm.

---

## B. Errors that would stop or silently corrupt a fresh run (all fixed)

- Race section reads `cohort_9`, which is never created.
- `PROC TRANSPOSE ... BY scrssn` on an unsorted table; several `MERGE ... BY` on unsorted data
  (`data.cohort_2`, `data.cohort_3`, `sen_cohort_5`). Replaced with SQL joins or explicit sorts.
- `data.CDW_diagnosis` and `data.targeted_ICD10` are used before they are created (worked only because
  of an earlier session). Reordered.
- `data.risk` first version uses `exposed_cnt` / `unexposed_cnt` (do not exist) and hard-coded denominators (164249, 2208517).
- `rr_eczema_31` referenced where `rr_eczema_9` was meant; `ods output =rr_eczema_1` (syntax error); `proc logistic ... estimate` test code.
- Fracture hash lookups: `length` of key/DX variables was set inconsistently between programs.
- Category recode compares `"Zfracture1"` but another line uses `'ZFracture2'` (case). If the spreadsheet casing differs,
  the recode silently does nothing. Now compared with `upcase`.
- `risk_20` labels reference `&category`, which holds whatever the last loop iteration left there.
- The ACI (category 7) breakdown block at the end of program 1 is unfinished and refers to datasets from the last loop pass. Removed.
- The CDW eczema `numscrssn` join re-read the full table three times. Simplified.
- File 3 **overwrote** program 1 outputs (`data.race`, `data.in1`, `data.in2`, `data.out_CPT_procedure`, `data.medicare_diag`, `data.CA_diag` ...).
  Sensitivity outputs now use the `sen_` prefix.
- "Expected count" comments in program 3 are copy-pasted from program 1 (e.g. `**2372820//2372820`, `**48449//62772`).

## C. Items I removed
- Unused code: `vaop_race` query, stop-code crosswalk import, `MS_diagnosis` import, ICD-9 joins, rhinitis "size check",
  fracture/ICD exploration, early `data.risk` version, the first (VA + Medicare only) comorbidity run that was overwritten,
  duplicated macros (OR / RR / AR loops appeared 2-3 times).
- `proc export ... sen_cohort.csv`: that writes **patient-level data with SCRSSN**. Never put it in the repo.
- All real paths, the CDW data-source name, library names, and the names of colleagues in comments ("Per Maddy/Katrina").
  Replaced with config placeholders.
- Numeric count comments (`**2,374,661//...`). They are aggregate, but check with your facility's disclosure rules.
  They are kept in `qc_expected_counts_PRIVATE.txt` (do not upload).

## D. Things to do before uploading
1. Run the cleaned programs; check logs for `uninitialized`, `not sorted`, and `GENMOD did not converge` messages.
2. Resolve section A items with your co-authors; re-run and update the manuscript tables if numbers move.
3. Confirm `%stat_table` (Table-1 macro) can be shared, or document it in the README.
4. Scan every file for facility names, user IDs, and paths; add a `.gitignore` (`*.sas7bdat`, `*.log`, `*.lst`, `*.csv`, `*.xlsx`).
5. Check that your VA research office allows the code to be posted publicly.
