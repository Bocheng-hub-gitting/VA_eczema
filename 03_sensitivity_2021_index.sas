/***********************************************************************
 Program : 03_sensitivity_2021_index.sas
 Purpose : Sensitivity analysis - rebuild the cohort with index year 2021
           (>=1 VA visit in 2021) to evaluate a possible temporal trend.
           Eczema window 2019-2023, comorbidity window 2020-2022.
 Author  : Bocheng Jing
 Date    : 2024/12/27 (original); cleaned for release
 Input   : From program 01: DATA.target_index_ICD10, DATA.index_comorbidity,
           DATA.skin_infection_ICD10, DATA.dsspha_eczema
 Output  : DATA.sen_cohort_1 ... sen_cohort_6, DATA.sen_res_*
 Note    : Diagnoses come from CDW for VA (single ICD-10 code per row) and
           from Medicare. All sensitivity datasets use the prefix "sen_" so
           nothing from program 01 is overwritten.
***********************************************************************/

%include "config.sas";
%include "macros.sas";

%let INDEX_YEAR = 2021;
%let ECZ_LO = '01JAN2019'd;   %let ECZ_HI = '31DEC2023'd;
%let CMB_LO = '01JAN2020'd;   %let CMB_HI = '31DEC2022'd;


/*=====================================================================
  1. Pull data
=====================================================================*/
/* VA outpatient diagnoses + primary stop code, 2019-2023 */
%pull_cdw_outpatient_dx(lo_year=2019, hi_year=2024, out=data.sen_va_outpatient_dx,
                        stopcode=Y);
/* VA inpatient diagnoses (all positions), 2020-2021: hospitalization in the
   365 days before the index date                                          */
%pull_cdw_inpatient_dx(lo_year=2020, hi_year=2022, out=data.sen_va_inpatient_dx,
                       principal_only=N);
/* Medicare 2012-2023 (2023 = quarterly file) */
%build_medicare_dx(suffixes=12 13 14 15 16 17 18 19 20 21 22 23Q,
                   out=data.sen_medicare_diag);


/*=====================================================================
  2. Base cohort (first visit in 2021)
=====================================================================*/
%build_base_cohort(visits=data.sen_va_outpatient_dx, datevar=dx_date,
                   index_year=&INDEX_YEAR, out=data.sen_cohort_1);
%qc_count(data.sen_cohort_1, id=scrssn);


/*=====================================================================
  3. Eczema (L20 / L30) from VA (CDW) and Medicare; age
=====================================================================*/
%macro eczema_ids(code=);
    %let &code._codes = "&code";
    %any_dx(out=_va_&code,  flag=va_&code,  codes_mv=&code._codes, id=scrssn,
            lo=&ECZ_LO, hi=&ECZ_HI,
            s1_ds=data.sen_va_outpatient_dx, s1_vars=icd10, s1_date=dx_date,
            s2_ds=, s2_vars=, s2_date=, s3_ds=, s3_vars=, s3_date=);
    %any_dx(out=_mcr_&code, flag=mcr_&code, codes_mv=&code._codes, id=scrssn,
            lo=&ECZ_LO, hi=&ECZ_HI,
            s1_ds=data.sen_medicare_diag, s1_vars=&MCR_DX_VARS, s1_date=thru_dt,
            s2_ds=, s2_vars=, s2_date=, s3_ds=, s3_vars=, s3_date=);
%mend eczema_ids;
%eczema_ids(code=L20);
%eczema_ids(code=L30);

proc sql;
    create table _c2 as
    select a.*,
        case when a.scrssn in (select scrssn from _va_L20)  then 1 else 0 end as VA_L20,
        case when a.scrssn in (select scrssn from _va_L30)  then 1 else 0 end as VA_L30,
        case when a.scrssn in (select scrssn from _mcr_L20) then 1 else 0 end as Medicare_L20,
        case when a.scrssn in (select scrssn from _mcr_L30) then 1 else 0 end as Medicare_L30
    from data.sen_cohort_1 a;
quit;

data data.sen_cohort_2;
    set _c2;
    L20    = (VA_L20=1 or Medicare_L20=1);
    L30    = (VA_L30=1 or Medicare_L30=1);
    eczema = (L20=1 or L30=1);
    age    = floor((index_dt - DOB)/365.25);
run;
proc freq data=data.sen_cohort_2; table eczema; run;
proc means data=data.sen_cohort_2 n min p1 p10 q1 mean median std q3 p90 p99 max maxdec=1;
    var age;
run;


/*=====================================================================
  4. Race / ethnicity
=====================================================================*/
%derive_race(cohort=data.sen_cohort_2, out=_race_final);
proc sql;
    create table data.sen_cohort_3 as
    select a.*, coalesce(b.race, "&RACE_IF_MISSING") as race length=100
    from data.sen_cohort_2 a left join _race_final b on a.scrssn = b.scrssn;
quit;
proc freq data=data.sen_cohort_3; table race; run;


/*=====================================================================
  5. Health-care use in the 365 days before the index date
=====================================================================*/
proc sql;
    create table _stop as
    select distinct a.scrssn, b.StopCode
    from data.sen_cohort_3 a inner join data.sen_va_outpatient_dx b on a.scrssn = b.scrssn
    where a.index_dt-365 <= b.dx_date < a.index_dt
      and b.StopCode in (&STOPCODE_ED, &STOPCODE_PC, &STOPCODE_DERM);

    create table _hosp as
    select distinct a.scrssn
    from data.sen_cohort_3 a inner join data.sen_va_inpatient_dx b on a.scrssn = b.scrssn
    where a.index_dt-365 <= b.dx_date < a.index_dt;

    create table data.sen_cohort_4 as
    select a.*,
        case when a.scrssn in (select scrssn from _stop where StopCode=&STOPCODE_ED)
             then 1 else 0 end as emergency,
        case when a.scrssn in (select scrssn from _stop where StopCode in (&STOPCODE_PC))
             then 1 else 0 end as primary_care,
        case when a.scrssn in (select scrssn from _stop where StopCode=&STOPCODE_DERM)
             then 1 else 0 end as dermatology,
        case when a.scrssn in (select scrssn from _hosp)
             then 1 else 0 end as hospitalization
    from data.sen_cohort_3 a;
quit;
proc freq data=data.sen_cohort_4; table emergency primary_care dermatology hospitalization; run;


/*=====================================================================
  6. Comorbidities (2020-2022; VA CDW + Medicare)
=====================================================================*/
proc sort data=data.sen_cohort_4 out=eczema_cohort(keep=scrssn numscrssn eczema);
    by numscrssn;
run;

proc sql;
    create table data.sen_va_dx_comorb as
    select b.numscrssn, a.scrssn, a.dx_date, a.icd10
    from data.sen_va_outpatient_dx a   /* outpatient diagnoses only, as in the original analysis */
         inner join eczema_cohort b on a.scrssn = b.scrssn
    where a.dx_date between &CMB_LO and &CMB_HI;

    create table data.sen_mcr_dx_comorb as
    select a.* from data.sen_medicare_diag a
         inner join eczema_cohort b on a.numscrssn = b.numscrssn
    where a.thru_dt between &CMB_LO and &CMB_HI;
quit;

%let SRC1_DS=data.sen_va_dx_comorb;  %let SRC1_VARS=icd10;        %let SRC1_DATE=dx_date;
%let SRC2_DS=data.sen_mcr_dx_comorb; %let SRC2_VARS=&MCR_DX_VARS; %let SRC2_DATE=thru_dt;
%let SRC3_DS=;                       %let SRC3_VARS=;             %let SRC3_DATE=;

%comorb_flags(cohort=eczema_cohort, lo=&CMB_LO, hi=&CMB_HI);
%derived_comorbidities(cohort=eczema_cohort, lo=&CMB_LO, hi=&CMB_HI);

data data.sen_comorb_flag;
    merge comorb_1-comorb_31;
    by numscrssn;
    label %comorb_labels;
run;


/*=====================================================================
  7. ADI (2019-2023; index-year 2021) and single imputation
=====================================================================*/
%get_adi(cohort=data.sen_cohort_4, year_lo=2019, year_hi=2023,
         index_year=&INDEX_YEAR, out=_adi_cohort);

/* NOTE: unlike program 01, comorbidity flags are not in this imputation model */
proc mi data=_adi_cohort nimpute=1 out=_adi_imp seed=314156 minimum=1 maximum=100 noprint;
    class Gender race dermatology hospitalization primary_care eczema;
    monotone reg(ADI = age Gender race dermatology hospitalization primary_care eczema);
    var age Gender race dermatology hospitalization primary_care eczema ADI;
run;

proc sort data=_adi_imp(keep=numscrssn ADI) out=_adi_only; by numscrssn; run;
proc sort data=data.sen_cohort_4 out=_c4; by numscrssn; run;
data data.sen_cohort_5;
    merge _c4(in=a) data.sen_comorb_flag(drop=eczema) _adi_only;
    by numscrssn;
    if a;
run;
%qc_count(data.sen_cohort_5, id=scrssn);

%risk_2x2(data=data.sen_cohort_5, out=data.sen_res_rr_unadj_binary);


/*=====================================================================
  8. Severity (index year 2021)
=====================================================================*/
%pull_cpt(cohort=data.sen_cohort_5, index_year=&INDEX_YEAR,
          out_inp=data.sen_cpt_inpatient, out_outp=data.sen_cpt_outpatient);

%severity_flags(cohort=data.sen_cohort_5, year=&INDEX_YEAR,
                cpt_inp=data.sen_cpt_inpatient, cpt_outp=data.sen_cpt_outpatient,
                meds=data.dsspha_eczema, out=data.sen_cohort_6,
                tx_out=data.sen_severity_tx);

proc freq data=data.sen_cohort_6; table eczema1 eczema*eczema_severe; run;


/*=====================================================================
  9. Effect estimates
=====================================================================*/
%rr_binary_adj(data=data.sen_cohort_6, out=data.sen_res_rr_adj_binary);
%rr_multilevel(data=data.sen_cohort_6, out=data.sen_res_rr_multi_adj,   adjust=Y);
%rr_multilevel(data=data.sen_cohort_6, out=data.sen_res_rr_multi_unadj, adjust=N);
%or_multilevel(data=data.sen_cohort_6, out=data.sen_res_or_multi_adj,   adjust=Y);
%or_multilevel(data=data.sen_cohort_6, out=data.sen_res_or_multi_unadj, adjust=N);
%attrib_risk  (data=data.sen_cohort_6, out=data.sen_res_attrib_risk);
