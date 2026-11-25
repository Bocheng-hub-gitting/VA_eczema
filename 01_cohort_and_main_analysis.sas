/***********************************************************************
 Program : 01_cohort_and_main_analysis.sas
 Purpose : Build the atopic-eczema cohort from VA + Medicare + CDW data and
           run the main comorbidity analyses.
 Design  : Adults (born on/before &BIRTH_CUTOFF) with >=1 VA visit in 2018
           (index date = first 2018 visit). Study window 2016-2020.
           Eczema = ICD-10 L20 or L30 (VA, Medicare, CDW), 2016-2020.
           Comorbidities = diagnoses 2017-2019.
 Author  : Bocheng Jing
 Date    : 2024/05/22 (original); cleaned for release

 Run order: config.sas and macros.sas are included below. This program must
            be run BEFORE 02_ and 03_ (they read its output datasets).

 Output datasets (library DATA)
   cohort_1  base cohort (index date, DOB, sex)
   cohort_2  + eczema (VA/Medicare), age
   cohort_3  + race
   cohort_4  + health-care use (ED, primary care, derm, hospitalization),
               final eczema flag (adds CDW)
   cohort_5  + 31 comorbidity flags
   cohort_6  + area deprivation index (ADI; missing values imputed)
   cohort_7  + eczema severity, 3-level exposure eczema1
   cohort_8  + comorbidity count (comorb_sum)
   res_*     result tables
***********************************************************************/

%include "config.sas";
%include "macros.sas";

%let INDEX_YEAR = 2018;
%let ECZ_LO = '01JAN2016'd;   %let ECZ_HI = '31DEC2020'd;   /* eczema window       */
%let CMB_LO = '01JAN2017'd;   %let CMB_HI = '31DEC2019'd;   /* comorbidity window  */


/*=====================================================================
  1. Base cohort
=====================================================================*/
%build_base_cohort(visits=data1.va_diagnosis, datevar=vizday1,
                   index_year=&INDEX_YEAR, out=data.cohort_1);
%qc_count(data.cohort_1);


/*=====================================================================
  2. Pull diagnoses from CDW (2016-2020) and Medicare (2012-2020)
=====================================================================*/
%pull_cdw_inpatient_dx(lo_year=2016, hi_year=2021, out=data.cdw_inpatient_dx,
                       principal_only=Y);   /* NOTE: principal diagnosis only */
%pull_cdw_outpatient_dx(lo_year=2016, hi_year=2021, out=data.cdw_outpatient_dx);

data data.cdw_dx;
    set data.cdw_inpatient_dx data.cdw_outpatient_dx;
    numscrssn = scrssn*1;
run;

%build_medicare_dx(suffixes=12 13 14 15 16 17 18 19 20, out=data.medicare_diag);


/*=====================================================================
  3. Eczema (L20, L30) from VA and Medicare
=====================================================================*/
%macro eczema_ids(code=);
    %let &code._codes = "&code";
    %any_dx(out=_va_&code,  flag=va_&code,  codes_mv=&code._codes, lo=&ECZ_LO, hi=&ECZ_HI,
            s1_ds=data1.va_diagnosis, s1_vars=&VA_DX_VARS,  s1_date=vizday1,
            s2_ds=, s2_vars=, s2_date=, s3_ds=, s3_vars=, s3_date=);
    %any_dx(out=_mcr_&code, flag=mcr_&code, codes_mv=&code._codes, lo=&ECZ_LO, hi=&ECZ_HI,
            s1_ds=data.medicare_diag, s1_vars=&MCR_DX_VARS, s1_date=thru_dt,
            s2_ds=, s2_vars=, s2_date=, s3_ds=, s3_vars=, s3_date=);
%mend eczema_ids;
%eczema_ids(code=L20);
%eczema_ids(code=L30);

proc sql;
    create table _c2 as
    select a.*,
        case when a.numscrssn in (select numscrssn from _va_L20)  then 1 else 0 end as VA_L20,
        case when a.numscrssn in (select numscrssn from _va_L30)  then 1 else 0 end as VA_L30,
        case when a.numscrssn in (select numscrssn from _mcr_L20) then 1 else 0 end as Medicare_L20,
        case when a.numscrssn in (select numscrssn from _mcr_L30) then 1 else 0 end as Medicare_L30
    from data.cohort_1 a;
quit;

data data.cohort_2;
    set _c2;
    L20    = (VA_L20=1 or Medicare_L20=1);
    L30    = (VA_L30=1 or Medicare_L30=1);
    eczema = (L20=1 or L30=1);   /* VA + Medicare definition; CDW added in step 5 */
    age    = floor((index_dt - DOB)/365.25);
run;
proc freq data=data.cohort_2; table L20 L30 eczema; run;


/*=====================================================================
  4. Race / ethnicity
=====================================================================*/
%derive_race(cohort=data.cohort_2, out=_race_final);

proc sql;
    create table data.cohort_3 as
    select a.*, coalesce(b.race, "&RACE_IF_MISSING") as race length=100
    from data.cohort_2 a left join _race_final b on a.scrssn = b.scrssn;
quit;
proc freq data=data.cohort_3; table race; run;


/*=====================================================================
  5. Health-care use in the 365 days before the index date,
     and eczema from CDW
=====================================================================*/
proc sql;
    create table _stop as
    select distinct a.scrssn, b.CL
    from data.cohort_3 a inner join data1.vaop b on a.scrssn = b.scrssn
    where a.index_dt-365 <= b.vizday1 < a.index_dt
      and b.CL in (&STOPCODE_ED, &STOPCODE_PC, &STOPCODE_DERM);

    create table _hosp as
    select distinct a.scrssn
    from data.cohort_3 a inner join data1.vaip b on a.scrssn = b.scrssn
    where a.index_dt-365 <= b.admitday1 < a.index_dt;
quit;

%let ECZ_ALL = "L20","L30";
%any_dx(out=_cdw_ecz, flag=eczema_cdw, codes_mv=ECZ_ALL, lo=&ECZ_LO, hi=&ECZ_HI,
        s1_ds=data.cdw_dx, s1_vars=icd10, s1_date=dx_date,
        s2_ds=, s2_vars=, s2_date=, s3_ds=, s3_vars=, s3_date=);

proc sql;
    create table data.cohort_4 as
    select a.*,
        case when a.scrssn in (select scrssn from _stop where CL=&STOPCODE_ED)
             then 1 else 0 end as emergency,
        case when a.scrssn in (select scrssn from _stop where CL in (&STOPCODE_PC))
             then 1 else 0 end as primary_care,
        case when a.scrssn in (select scrssn from _stop where CL=&STOPCODE_DERM)
             then 1 else 0 end as dermatology,
        case when a.scrssn in (select scrssn from _hosp)
             then 1 else 0 end as hospitalization,
        a.eczema as eczema_medsas_medicare,
        case when a.numscrssn in (select numscrssn from _cdw_ecz)
             then 1 else 0 end as eczema_cdw
    from data.cohort_3 a;
quit;

data data.cohort_4;
    set data.cohort_4;
    eczema = (eczema_medsas_medicare=1 or eczema_cdw=1);   /* final eczema definition */
run;
proc freq data=data.cohort_4;
    table emergency primary_care dermatology hospitalization
          eczema_medsas_medicare*eczema_cdw eczema;
run;


/*=====================================================================
  6. Comorbidities (diagnoses 2017-2019; VA + Medicare + CDW)
=====================================================================*/
/* 6a. code lists */
proc import datafile="&ICD_DIR/&ICD_FILE_TARGETED" out=data.targeted_ICD10
    dbms=xlsx replace; run;
proc import datafile="&ICD_DIR/&ICD_FILE_SKIN" out=data.skin_infection_ICD10
    dbms=xlsx replace; run;

proc sql;
    create table index_comorb1 as
    select distinct Category from data.targeted_ICD10
    where Category ne 'CV Death' order by Category;
quit;
data index_comorb1; set index_comorb1; disease_cat = _n_; run;

proc sql;
    create table data.target_index_ICD10 as
    select a.ICD10, a.Code_desc, a.CCSR_Category, a.CCSR_cat_desc,
           a.Category, a.Category1, b.disease_cat
    from data.targeted_ICD10 a inner join index_comorb1 b on a.Category = b.Category
    order by b.disease_cat;
quit;

/* Categories 30 and 31 are the two halves of the (long) fracture list;
   #31 is re-used below for 'Skin Infection'.                          */
data data.index_comorbidity;
    set index_comorb1;
    if upcase(Category)="ZFRACTURE1" then Category="Fracture";
    if upcase(Category)="ZFRACTURE2" then Category="Skin Infection";
run;
title "CHECK: category numbers must match the label list in %nrstr(%comorb_labels)";
proc print data=data.index_comorbidity noobs; run;
title;

/* 6b. restrict diagnosis tables to the cohort and comorbidity window */
proc sort data=data.cohort_4 out=eczema_cohort(keep=scrssn numscrssn eczema);
    by numscrssn;
run;

proc sql;
    create table data.va_dx_comorb as
    select a.* from data1.va_diagnosis a
        inner join eczema_cohort b on a.numscrssn = b.numscrssn
    where a.vizday1 between &CMB_LO and &CMB_HI;

    create table data.mcr_dx_comorb as
    select a.* from data.medicare_diag a
        inner join eczema_cohort b on a.numscrssn = b.numscrssn
    where a.thru_dt between &CMB_LO and &CMB_HI;

    create table data.cdw_dx_comorb as
    select a.* from data.cdw_dx a
        inner join eczema_cohort b on a.numscrssn = b.numscrssn
    where a.dx_date between &CMB_LO and &CMB_HI;
quit;

/* 6c. flag comorbidities */
%let SRC1_DS=data.va_dx_comorb;  %let SRC1_VARS=&VA_DX_VARS;  %let SRC1_DATE=vizday1;
%let SRC2_DS=data.mcr_dx_comorb; %let SRC2_VARS=&MCR_DX_VARS; %let SRC2_DATE=thru_dt;
%let SRC3_DS=data.cdw_dx_comorb; %let SRC3_VARS=icd10;        %let SRC3_DATE=dx_date;

%comorb_flags(cohort=eczema_cohort, lo=&CMB_LO, hi=&CMB_HI);        /* 1-29 except 20 */
%derived_comorbidities(cohort=eczema_cohort, lo=&CMB_LO, hi=&CMB_HI); /* 20, 30, 31     */

data data.comorb_flag;
    merge comorb_1-comorb_31;
    by numscrssn;
    label %comorb_labels;
run;

proc sort data=data.cohort_4 out=_c4; by numscrssn; run;
data data.cohort_5;
    merge _c4(in=a) data.comorb_flag(drop=eczema);
    by numscrssn;
    if a;
run;
%qc_count(data.cohort_5);

/* Unadjusted 2x2 risk ratios */
%risk_2x2(data=data.cohort_5, out=data.res_rr_unadj_binary);

/* Table 1 */
%stat_table(DSN=data.cohort_5, BY=eczema,
            VAR=age Gender race emergency primary_care dermatology hospitalization,
            TYPE=1 2 2 2 2 2 2);
%stat_table(DSN=data.cohort_5, BY=eczema, VAR=%comorb_vars(n=31), TYPE=%types(31));


/*=====================================================================
  7. Area Deprivation Index (ADI); single imputation of missing ADI
=====================================================================*/
%get_adi(cohort=data.cohort_5, year_lo=2016, year_hi=2019,
         index_year=&INDEX_YEAR, out=_adi_cohort);
proc freq data=_adi_cohort; table ADI / missing; where ADI=.; run;

proc mi data=_adi_cohort nimpute=1 out=_adi_imp seed=314156 minimum=1 maximum=100 noprint;
    class Gender race comorb_: dermatology hospitalization primary_care eczema;
    monotone reg(ADI = age Gender race comorb_: dermatology hospitalization
                       primary_care eczema);
    var age Gender race comorb_: dermatology hospitalization primary_care eczema ADI;
run;

data data.cohort_6; set _adi_imp(drop=_Imputation_); run;
proc means data=data.cohort_6 n nmiss min p1 p10 q1 mean median q3 p90 p99 max;
    var ADI;
run;
%stat_table(DSN=data.cohort_6, BY=eczema,
            VAR=age Gender race emergency primary_care dermatology hospitalization ADI,
            TYPE=1 2 2 2 2 2 2 1);

/* Adjusted RR, eczema vs none */
%rr_binary_adj(data=data.cohort_6, out=data.res_rr_adj_binary);


/*=====================================================================
  8. Eczema severity (index year): phototherapy/procedure CPT or systemic drug
=====================================================================*/
%pull_cpt(cohort=data.cohort_6, index_year=&INDEX_YEAR,
          out_inp=data.cpt_inpatient, out_outp=data.cpt_outpatient);

proc sql;
    create table data.dsspha_eczema as
    select scrssn, CohortName, svc_dte, inout, day_supply, quantity,
           va_class, drugdesc, scan(drugdesc,1) as generic
    from S4016SRC.DSS_PHA
    where va_class in ('DE890','AN300','IM600','MS190');
quit;

%severity_flags(cohort=data.cohort_6, year=&INDEX_YEAR,
                cpt_inp=data.cpt_inpatient, cpt_outp=data.cpt_outpatient,
                meds=data.dsspha_eczema, out=data.cohort_7, tx_out=data.severity_tx);

proc freq data=data.cohort_7;
    table eczema1 eczema*eczema_severe;
run;
%macro tx_freq(cond=);
    proc freq data=data.severity_tx;
        table phototherapy_cpt METHOTREXATE MYCOPHENOLATE AZATHIOPRINE CYCLOSPORINE DUPILUMAB;
        where &cond;
    run;
%mend tx_freq;
%tx_freq(cond=eczema=1);
%tx_freq(cond=eczema_severe=1);


/*=====================================================================
  9. Three-level exposure analyses (none / eczema / severe eczema)
=====================================================================*/
data data.cohort_8;
    set data.cohort_7;
    /* Count excludes #18 Herpes and #25 Staph (captured in #7/#31) */
    comorb_sum = sum(of comorb_1-comorb_17) + sum(of comorb_19-comorb_24)
               + sum(of comorb_26-comorb_31);
run;
proc freq data=data.cohort_8; table comorb_sum eczema1; run;

%rr_multilevel(data=data.cohort_8, out=data.res_rr_multi_adj,   adjust=Y);
%rr_multilevel(data=data.cohort_8, out=data.res_rr_multi_unadj, adjust=N);
%or_multilevel(data=data.cohort_8, out=data.res_or_multi_adj,   adjust=Y);
%or_multilevel(data=data.cohort_8, out=data.res_or_multi_unadj, adjust=N);
%attrib_risk  (data=data.cohort_8, out=data.res_attrib_risk);


/*=====================================================================
  10. Comorbidity burden: eczema vs no eczema
=====================================================================*/
%stat_table(DSN=data.cohort_8, BY=eczema, VAR=comorb_sum, TYPE=1);
proc ttest data=data.cohort_8 sides=2 alpha=0.05 h0=0;
    class eczema;
    var comorb_sum;
run;
