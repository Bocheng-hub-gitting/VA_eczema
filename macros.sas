/***********************************************************************
 Program : macros.sas
 Purpose : Shared macros for the eczema comorbidity programs
           (cohort building, diagnosis flagging, CDW pulls, risk models).
 Author  : Bocheng Jing
 Requires: config.sas (included first)
***********************************************************************/

/* ===================================================================
   A. Small utilities
   =================================================================== */

/* Print distinct-patient and row counts of a dataset */
%macro qc_count(ds, id=numscrssn);
    proc sql;
        select "&ds" as dataset format=$60.,
               count(distinct &id) as n_patients format=comma15.,
               count(*)            as n_rows     format=comma15.
        from &ds;
    quit;
%mend qc_count;

/* Put the category name of comorbidity number &i into global &category */
%macro get_category(i);
    %global category;
    proc sql noprint;
        select strip(Category) into :category
        from data.index_comorbidity
        where disease_cat = &i;
    quit;
%mend get_category;

/* comorb_1 comorb_2 ... comorb_n */
%macro comorb_vars(n=31);
    %local i;
    %do i=1 %to &n; comorb_&i %end;
%mend comorb_vars;

/* Repeat a %stat_table TYPE code n times */
%macro types(n, t=2);
    %local i;
    %do i=1 %to &n; &t %end;
%mend types;

/* LABEL list for the 31 comorbidity flags: use as   label %comorb_labels; */
%macro comorb_labels;
    comorb_1='ADHD' comorb_2='Alcohol abuse disorder'
    comorb_3='Allergic conjunctivitis' comorb_4='Allergic rhinitis'
    comorb_5='Alopecia Areata' comorb_6='Anxiety'
    comorb_7='Any cutaneous infection' comorb_8='Asthma'
    comorb_9='Autism Spectrum Disorder' comorb_10='Cigarette smoking'
    comorb_11='Congestive Heart Failure' comorb_12='Coronary Artery Disease'
    comorb_13='Depression' comorb_14='Diabetes' comorb_15='Dyslipidemia'
    comorb_16='Eosinophilic esophagitis' comorb_17='Food Allergy'
    comorb_18='Herpes Superinfection' comorb_19='Hypertension'
    comorb_20='Metabolic Syndrome' comorb_21='Myocardial Infarction'
    comorb_22='Obesity' comorb_23='Osteoporosis'
    comorb_24='Peripheral Artery Disease' comorb_25='Staphylococcal'
    comorb_26='Stroke' comorb_27='Suicide' comorb_28='Thrombo-embolic Disease'
    comorb_29='Urticaria' comorb_30='Fracture' comorb_31='Skin Infection'
%mend comorb_labels;

/* ===================================================================
   B. Base cohort: first visit in the index year, demographics,
      DOB cross-check, birth-date restriction
   =================================================================== */
%macro build_base_cohort(visits=, datevar=, index_year=, out=);

    /* 1. index date = first visit in the index year */
    proc sql;
        create table _idx as
        select scrssn, min(&datevar) as index_dt format=mmddyy10.
        from &visits
        where &datevar between mdy(1,1,&index_year) and mdy(12,31,&index_year)
        group by scrssn;
    quit;
    data _idx; set _idx; numscrssn = scrssn*1; run;

    /* 2. DOB / DOD / sex; where a patient has several demographic records
          keep the one with the latest DOD (a DOD before the index year on
          a duplicated patient is treated as unreliable and set missing)   */
    proc sql;
        create table _demo as
        select distinct a.*,
               datepart(b.BirthDateTime) as DOB format=mmddyy10.,
               datepart(b.DeathDateTime) as DOD format=mmddyy10.,
               b.Gender
        from _idx a left join S4016SRC.Spatient_Spatient b
             on a.scrssn = b.scrssn;
    quit;
    proc sort data=_demo; by scrssn DOD; run;
    data _demo;
        set _demo;
        by scrssn DOD;
        if first.scrssn and last.scrssn then output;
        else if last.scrssn then do;
            if year(DOD) < &index_year then DOD = .;
            output;
        end;
    run;

    /* 3. second source of DOB; keep patients whose DOBs agree */
    proc sql;
        create table _dob2 as
        select distinct a.*, datepart(b.DOB) as DOB1 format=mmddyy10.
        from _demo a inner join S4016SRC.MedSAS_outp_SE b
             on a.scrssn = b.scrssn;
    quit;
    data _dob2; set _dob2; if DOB = DOB1; drop DOB1; run;
    proc sort data=_dob2 nodupkey; by scrssn; run;

    /* 4. birth-date restriction */
    data &out;
        set _dob2;
        if DOB > &BIRTH_CUTOFF then delete;
    run;

    proc datasets lib=work nolist; delete _idx _demo _dob2; quit;
%mend build_base_cohort;

/* ===================================================================
   C. Race / ethnicity -> one 'race' value per patient
   =================================================================== */
%macro derive_race(cohort=, out=);
    proc sql;
        create table _race as
        select distinct a.scrssn, c.Race, d.Ethnicity
        from &cohort a
             left join  S4016SRC.Spatient_Spatient        b on a.scrssn=b.scrssn
             inner join S4016SRC.PatSub_PatientRace       c on b.PatientSID=c.PatientSID
             inner join S4016SRC.PatSub_PatientEthnicity  d on c.PatientSID=d.PatientSID;
    quit;
    /* deterministic order so that col1/col2 are reproducible */
    proc sort data=_race; by scrssn Race Ethnicity; run;

    proc transpose data=_race out=_race_t; by scrssn; var Race; run;

    data _race_r;
        set _race_t;
        length race_1 $100;
        race_1 = col1;
        if race_1="DECLINED TO ANSWER" and
           col2 in ("NATIVE HAWAIIAN OR OTHER PACIFIC ISLANDER","UNKNOWN BY PATIENT",
                    "WHITE","WHITE NOT OF HISP ORIG") then race_1 = col2;
        if race_1="UNKNOWN BY PATIENT" and
           col2 in ("NATIVE HAWAIIAN OR OTHER PACIFIC ISLANDER","UNKNOWN BY PATIENT",
                    "WHITE","WHITE NOT OF HISP ORIG") then race_1 = col2;
        if race_1="WHITE NOT OF HISP ORIG" then race_1 = "WHITE";
        keep scrssn race_1;
    run;

    /* Hispanic = any Hispanic/Latino ethnicity record */
    proc sql;
        create table _eth as
        select scrssn, max(Ethnicity="HISPANIC OR LATINO") as hispanic
        from _race group by scrssn;
    quit;

    proc sql;
        create table &out as
        select a.scrssn, a.race_1, b.hispanic
        from _race_r a left join _eth b on a.scrssn = b.scrssn;
    quit;

    data &out;
        set &out;
        length race $100;
        race = race_1;
        if hispanic = 1 then race = "HISPANIC OR LATINO";
        if race in ("UNKNOWN BY PATIENT","DECLINED TO ANSWER") then race = "UNKNOWN";
        keep scrssn race;
    run;

    proc datasets lib=work nolist; delete _race _race_t _race_r _eth; quit;
%mend derive_race;

/* ===================================================================
   D. Medicare diagnosis files (CA / IP / OP) stacked into one table
      suffixes e.g.  12 13 14 ... 22 23Q
   =================================================================== */
%macro build_medicare_dx(suffixes=, out=);
    %local t k s type ncd;
    %do t=1 %to 3;
        %let type = %scan(OP IP CA, &t);
        %if &type=CA %then %let ncd=12; %else %let ncd=25;
        data _mcr_&type;
            set
            %do k=1 %to %sysfunc(countw(&suffixes));
                %let s = %scan(&suffixes, &k);
                SHIP2252.&type.&s._BASE_SHIP2252(keep=scrssn THRU_DT ICD_DGNS_CD1-ICD_DGNS_CD&ncd)
            %end;
            ;
            numscrssn = scrssn*1;
        run;
    %end;
    data &out; set _mcr_OP _mcr_IP _mcr_CA; run;
    proc datasets lib=work nolist; delete _mcr_OP _mcr_IP _mcr_CA; quit;
%mend build_medicare_dx;

/* ===================================================================
   E. CDW pulls (SQL Server pass-through).
      lo_year/hi_year define [Jan 1 lo_year, Jan 1 hi_year)  -- the upper
      bound is EXCLUSIVE, so the final calendar day is included.
   =================================================================== */
%macro pull_cdw_inpatient_dx(lo_year=, hi_year=, out=, principal_only=N);
    %local ord1 ord2;
    %let ord1=; %let ord2=;
    %if &principal_only=Y %then %do;
        %let ord1 = AND b.[OrdinalNumber] = '1';
        %let ord2 = AND b.[OrdinalNumber] = '0';
    %end;
    proc sql;
        connect to sqlsvr as tunnel (datasrc=&SRC_DB. &SQL_OPTIMAL.);

        create table _inp_discharge as
        select * from connection to tunnel (
            SELECT DISTINCT y.[scrssn],
                   CAST(b.[AdmitDateTime] AS date) AS dx_date,
                   REPLACE(c.[icd10code], '.', '') AS icd10
            FROM [&SRC_DB].[Src].[SPatient_SPatient] AS y
              JOIN [&SRC_DB].[Src].[Inpat_InpatDischargeDiagnosis] AS b
                   ON y.[Sta3n]=b.[Sta3n] AND y.[PatientSID]=b.[PatientSID]
              LEFT JOIN [CDWWork].[Dim].[ICD10] AS c
                   ON b.[Sta3n]=c.[Sta3n] AND b.[icd10sid]=c.[icd10sid]
            WHERE b.[AdmitDateTime] >= DATEFROMPARTS(&lo_year,1,1)
              AND b.[AdmitDateTime] <  DATEFROMPARTS(&hi_year,1,1)
              &ord1 );

        create table _inp_fee as
        select * from connection to tunnel (
            SELECT DISTINCT y.[scrssn],
                   CAST(b.[AdmitDateTime] AS date) AS dx_date,
                   REPLACE(c.[icd10code], '.', '') AS icd10
            FROM [&SRC_DB].[Src].[SPatient_SPatient] AS y
              JOIN [&SRC_DB].[Src].[Inpat_InpatientFeeDiagnosis] AS b
                   ON y.[Sta3n]=b.[Sta3n] AND y.[PatientSID]=b.[PatientSID]
              LEFT JOIN [CDWWork].[Dim].[ICD10] AS c
                   ON b.[Sta3n]=c.[Sta3n] AND b.[icd10sid]=c.[icd10sid]
            WHERE b.[AdmitDateTime] >= DATEFROMPARTS(&lo_year,1,1)
              AND b.[AdmitDateTime] <  DATEFROMPARTS(&hi_year,1,1)
              &ord2 );

        disconnect from tunnel;
    quit;
    data &out; set _inp_discharge _inp_fee; run;
    proc datasets lib=work nolist; delete _inp_discharge _inp_fee; quit;
%mend pull_cdw_inpatient_dx;

%macro pull_cdw_outpatient_dx(lo_year=, hi_year=, out=, stopcode=N);
    proc sql;
        connect to sqlsvr as tunnel (datasrc=&SRC_DB. &SQL_OPTIMAL.);
        create table &out as
        select * from connection to tunnel (
            SELECT DISTINCT y.[scrssn],
                   CAST(b.[VisitDateTime] AS date) AS dx_date,
                   REPLACE(c.[icd10code], '.', '') AS icd10
                   %if &stopcode=Y %then %do;
                       , h.[StopCode], h.[StopCodeName]
                   %end;
            FROM [&SRC_DB].[Src].[SPatient_SPatient] AS y
              JOIN [&SRC_DB].[Src].[Outpat_VDiagnosis] AS b
                   ON y.[Sta3n]=b.[Sta3n] AND y.[PatientSID]=b.[PatientSID]
              %if &stopcode=Y %then %do;
              LEFT JOIN [&SRC_DB].[Src].[Outpat_Visit] AS g
                   ON b.[Sta3n]=g.[Sta3n] AND b.[VisitSID]=g.[VisitSID]
              LEFT JOIN [CDWWork].[Dim].[StopCode] AS h
                   ON g.[Sta3n]=h.[Sta3n] AND g.[PrimaryStopCodeSID]=h.[StopCodeSID]
              %end;
              LEFT JOIN [CDWWork].[Dim].[ICD10] AS c
                   ON b.[Sta3n]=c.[Sta3n] AND b.[icd10sid]=c.[icd10sid]
            WHERE b.[VisitDateTime] >= DATEFROMPARTS(&lo_year,1,1)
              AND b.[VisitDateTime] <  DATEFROMPARTS(&hi_year,1,1) );
        disconnect from tunnel;
    quit;
%mend pull_cdw_outpatient_dx;

/* CPT/HCPCS procedures in the index year (severity definition) */
%macro pull_cpt(cohort=, index_year=, out_inp=, out_outp=);
    %local next_year;
    %let next_year = %eval(&index_year + 1);

    proc sql;
        connect to sqlsvr as tunnel (datasrc=&SRC_DB. &SQL_OPTIMAL.);
        create table &out_inp as
        select * from connection to tunnel (
            SELECT DISTINCT y.[scrssn],
                   CAST(b.[CPTProcedureDateTime] AS date) AS dx_date,
                   c.[CPTCode], c.[CPTName]
            FROM [&SRC_DB].[Src].[SPatient_SPatient] AS y
              JOIN [&SRC_DB].[Src].[Inpat_InpatientCPTProcedure] AS b
                   ON y.[Sta3n]=b.[Sta3n] AND y.[PatientSID]=b.[PatientSID]
              LEFT JOIN [CDWWork].[Dim].[CPT] AS c
                   ON b.[Sta3n]=c.[Sta3n] AND b.[CPTSID]=c.[CPTSID]
            WHERE b.[CPTProcedureDateTime] >= DATEFROMPARTS(&index_year,1,1)
              AND b.[CPTProcedureDateTime] <  DATEFROMPARTS(&next_year,1,1) );
        disconnect from tunnel;
    quit;

    /* outpatient: restrict to the cohort through a SQL Server temp table */
    data cdw.'#eczema_cohort'N;
        set &cohort(keep=scrssn eczema);
    run;
    proc sql;
        connect to sqlsvr as tunnel (datasrc=&SRC_DB. &SQL_OPTIMAL.);
        create table &out_outp as
        select * from connection to tunnel (
            SELECT DISTINCT y.[scrssn], y.[eczema],
                   CAST(b.[VProcedureDateTime] AS date) AS dx_date,
                   c.[CPTCode], c.[CPTName]
            FROM #eczema_cohort y
              JOIN [&SRC_DB].[Src].[SPatient_SPatient] AS x
                   ON y.[scrssn]=x.[scrssn]
              JOIN [&SRC_DB].[Src].[Outpat_VProcedure] AS b
                   ON x.[Sta3n]=b.[Sta3n] AND x.[PatientSID]=b.[PatientSID]
              LEFT JOIN [CDWWork].[Dim].[CPT] AS c
                   ON b.[Sta3n]=c.[Sta3n] AND b.[CPTSID]=c.[CPTSID]
            WHERE b.[VProcedureDateTime] >= DATEFROMPARTS(&index_year,1,1)
              AND b.[VProcedureDateTime] <  DATEFROMPARTS(&next_year,1,1) );
        disconnect from tunnel;
    quit;
%mend pull_cpt;

/* ===================================================================
   F. any_dx : patients with >=1 matching diagnosis code
      - up to 3 sources (VA / Medicare / CDW), each with its own date var
      - codes given EITHER as a macro-variable NAME holding a quoted,
        comma-separated list (codes_mv=)  OR as a dataset with variable
        CODE (codes_ds=, used when the list is too long for a macro var)
      - op= in:  prefix match   |  in  exact match
      - scope= ALL | FIRST  (see config.sas)
      Output: &out with &id and &flag=1, one row per patient, sorted.
   =================================================================== */
%macro any_dx(out=, flag=, codes_mv=, codes_ds=, op=in:, scope=&DX_SCOPE,
              id=numscrssn, lo=, hi=,
              s1_ds=&SRC1_DS, s1_vars=&SRC1_VARS, s1_date=&SRC1_DATE,
              s2_ds=&SRC2_DS, s2_vars=&SRC2_VARS, s2_date=&SRC2_DATE,
              s3_ds=&SRC3_DS, s3_vars=&SRC3_VARS, s3_date=&SRC3_DATE);
    %local k hits hi_idx;
    %let hits=;
    %let hi_idx = dim(DX);
    %if %upcase(&scope)=FIRST %then %let hi_idx = 1;

    %do k=1 %to 3;
        %if %superq(s&k._ds) ne %then %do;
            %let hits = &hits _hit&k;
            data _hit&k(keep=&id);
                %if %superq(codes_ds) ne %then %do;
                    length code $10;
                    if _n_=1 then do;
                        declare hash h(dataset:"&codes_ds");
                        h.defineKey('code');
                        h.defineDone();
                    end;
                %end;
                set &&s&k._ds(keep=&id &&s&k._date &&s&k._vars
                              where=(&&s&k._date between &lo and &hi));
                array DX[*] &&s&k._vars;
                do i = 1 to &hi_idx;
                    %if %superq(codes_ds) ne %then %do;
                        code = DX[i];
                        if code ne ' ' and h.check()=0 then do; output; leave; end;
                    %end;
                    %else %do;
                        if DX[i] &op (&&&codes_mv) then do; output; leave; end;
                    %end;
                end;
            run;
        %end;
    %end;

    data _hits; set &hits; run;
    proc sort data=_hits out=&out nodupkey; by &id; run;
    data &out; set &out; &flag = 1; run;
    proc datasets lib=work nolist; delete _hit: _hits; quit;
%mend any_dx;

/* patient-level 0/1 comorbidity dataset: comorb_&n  (cohort needs numscrssn, eczema) */
%macro make_comorb(n=, cohort=, pt=, flag=);
    proc sql;
        create table comorb_&n as
        select a.numscrssn, a.eczema, coalesce(b.&flag, 0) as comorb_&n
        from &cohort a left join &pt b on a.numscrssn = b.numscrssn
        order by a.numscrssn;
    quit;
%mend make_comorb;

/* Comorbidities defined directly from the code-list categories
   (disease_cat 1-29; #20 Metabolic Syndrome is derived separately) */
%macro comorb_flags(cohort=, lo=, hi=, from=1, to=29, skip=20);
    %local i;
    %do i=&from %to &to;
        %if &i ne &skip %then %do;
            proc sql noprint;
                select distinct quote(strip(ICD10)) into :ICD10_list separated by ","
                from data.target_index_ICD10
                where disease_cat = &i;
            quit;
            %any_dx(out=_pt, flag=_f, codes_mv=ICD10_list, lo=&lo, hi=&hi);
            %make_comorb(n=&i, cohort=&cohort, pt=_pt, flag=_f);
        %end;
    %end;
    proc datasets lib=work nolist; delete _pt; quit;
%mend comorb_flags;

/* Metabolic syndrome (#20), Fracture (#30), Skin infection (#31)
   Metabolic syndrome = E88.81 code, OR >=2 of {dyslipidemia, hypertension,
   obesity, insulin resistance}. Needs comorb_15, comorb_19, comorb_22. */
%macro derived_comorbidities(cohort=, lo=, hi=);

    %let MS_codes = "E8881";
    %let IR_codes = "E88811","E88818","E88819";
    %any_dx(out=_ms, flag=ms, codes_mv=MS_codes, op=in,  scope=ALL, lo=&lo, hi=&hi);
    %any_dx(out=_ir, flag=ir, codes_mv=IR_codes, op=in:, scope=ALL, lo=&lo, hi=&hi);

    data comorb_20(keep=numscrssn eczema comorb_20);
        merge comorb_15(in=a keep=numscrssn eczema comorb_15)
              comorb_19(keep=numscrssn comorb_19)
              comorb_22(keep=numscrssn comorb_22)
              _ms(in=in_ms keep=numscrssn)
              _ir(in=in_ir keep=numscrssn);
        by numscrssn;
        if a;
        combo    = sum(comorb_15, comorb_19, comorb_22, in_ir);
        comorb_20 = (in_ms=1 or combo >= 2);
        label comorb_20 = "Metabolic Syndrome";
    run;

    /* Fracture: code list too long for a macro variable -> hash lookup */
    data _fx_codes;
        length code $10;
        set data.target_index_ICD10(where=(disease_cat in (30,31)));
        code = strip(ICD10);
        keep code;
    run;
    proc sort data=_fx_codes nodupkey; by code; run;
    %any_dx(out=_fx, flag=fx, codes_ds=_fx_codes, scope=ALL, lo=&lo, hi=&hi);
    %make_comorb(n=30, cohort=&cohort, pt=_fx, flag=fx);

    /* Skin infection (separate code list) */
    proc sql noprint;
        select distinct quote(strip(ICD10)) into :SI_codes separated by ","
        from data.skin_infection_ICD10
        where Category1 = "Skin Infection";
    quit;
    %any_dx(out=_si, flag=si, codes_mv=SI_codes, scope=ALL, lo=&lo, hi=&hi);
    %make_comorb(n=31, cohort=&cohort, pt=_si, flag=si);

    proc datasets lib=work nolist; delete _ms _ir _fx _fx_codes _si; quit;
%mend derived_comorbidities;

/* ===================================================================
   G. ADI: take the index-year value (highest national rank if several);
      if none, the highest national rank among the other years.
   =================================================================== */
%macro get_adi(cohort=, year_lo=, year_hi=, index_year=, out=);
    proc sql;
        create table _adi as
        select distinct a.numscrssn, b.year, b.ADI_NATRANK
        from &cohort a inner join adi.COHORT4_ADI_PAT_PSSG b
             on a.scrssn = b.scrssn
        where input(b.year,4.) between &year_lo and &year_hi
          and b.ADI_NATRANK is not null;

        create table _adi_idx as
        select numscrssn, max(ADI_NATRANK) as ADI
        from _adi where year = "&index_year" group by numscrssn;

        create table _adi_oth as
        select numscrssn, max(ADI_NATRANK) as ADI
        from _adi
        where numscrssn not in (select numscrssn from _adi_idx)
        group by numscrssn;

        create table &out as
        select a.*, b.ADI
        from &cohort a left join
             (select * from _adi_idx union all select * from _adi_oth) b
             on a.numscrssn = b.numscrssn;
    quit;
    proc datasets lib=work nolist; delete _adi _adi_idx _adi_oth; quit;
%mend get_adi;

/* ===================================================================
   H. Severity: eczema_severe = phototherapy/procedure CPT OR any of five
      systemic drugs in the index year, among eczema=1.
   =================================================================== */
%macro severity_flags(cohort=, year=, cpt_inp=, cpt_outp=, meds=, out=, tx_out=);
    %local k d;
    %let drugs = METHOTREXATE MYCOPHENOLATE AZATHIOPRINE CYCLOSPORINE DUPILUMAB;

    data _cpt_hit(keep=scrssn);
        set &cpt_outp(in=o) &cpt_inp;
        if year(dx_date)=&year and CPTCode in: (&SEV_CPT_CODES);
    run;

    proc sql;
        create table _meds_y as
        select scrssn, generic from &meds where year(svc_dte)=&year;

        create table &tx_out as
        select c.scrssn, c.eczema,
          case when c.eczema=1 and c.scrssn in (select scrssn from _cpt_hit)
               then 1 else 0 end as phototherapy_cpt
          %do k=1 %to 5;
              %let d = %scan(&drugs, &k);
              , case when c.eczema=1 and
                     c.scrssn in (select scrssn from _meds_y where generic="&d")
                then 1 else 0 end as &d
          %end;
        from &cohort c;
    quit;

    data &tx_out;
        set &tx_out;
        eczema_severe = (max(phototherapy_cpt, METHOTREXATE, MYCOPHENOLATE,
                             AZATHIOPRINE, CYCLOSPORINE, DUPILUMAB) = 1);
    run;

    proc sql;
        create table &out as
        select a.*, b.eczema_severe
        from &cohort a left join &tx_out b on a.scrssn = b.scrssn;
    quit;

    data &out;
        set &out;
        if eczema=0 then eczema1=0;
        else if eczema_severe=0 then eczema1=1;
        else eczema1=2;
        label eczema1 = "Eczema exposure: 0 none, 1 eczema (not severe), 2 severe";
    run;

    proc datasets lib=work nolist; delete _cpt_hit _meds_y; quit;
%mend severity_flags;

/* ===================================================================
   I. Effect-estimate macros (loop over comorb_1 .. comorb_n)
   =================================================================== */

/* Unadjusted 2x2 counts, RR (Wald CI) and risk difference */
%macro risk_2x2(data=, out=, n=31);
    %local i;
    %do i=1 %to &n;
        %get_category(&i)
        proc sql;
            create table _r&i as
            select &i as cat_num, "&category" as category length=40,
                   sum(eczema=1 and comorb_&i=1) as a label="eczema, outcome",
                   sum(eczema=0 and comorb_&i=1) as b label="no eczema, outcome",
                   sum(eczema=1 and comorb_&i=0) as c label="eczema, no outcome",
                   sum(eczema=0 and comorb_&i=0) as d label="no eczema, no outcome"
            from &data;
        quit;
    %end;
    data &out;
        set _r1-_r&n;
        AR_exposed   = a/(a+c);
        AR_unexposed = b/(b+d);
        RR       = AR_exposed/AR_unexposed;
        SE_logrr = sqrt(1/a - 1/(a+c) + 1/b - 1/(b+d));
        RR_lower = exp(log(RR) - 1.96*SE_logrr);
        RR_upper = exp(log(RR) + 1.96*SE_logrr);
        Risk_diff = AR_exposed - AR_unexposed;
    run;
    proc datasets lib=work nolist; delete _r1-_r&n; quit;
%mend risk_2x2;

/* Adjusted RR, binary exposure (log-binomial) */
%macro rr_binary_adj(data=, out=, n=31);
    %local i;
    proc datasets lib=work nolist; delete _rr: ; quit;
    %do i=1 %to &n;
        %get_category(&i)
        proc genmod data=&data descending;
            class eczema Gender race / param=reference ref=first;
            model comorb_&i = eczema age Gender race ADI
                  / dist=binomial link=log &GENMOD_OPTS;
            estimate 'RR Eczema vs. non-Eczema' eczema 1 / exp;
            ods output Estimates=_rr&i;
        run;
        %if %sysfunc(exist(_rr&i)) %then %do;
            proc sql;
                create table _rrs&i as
                select &i as cat_num, "&category" as category length=40,
                       MeanEstimate as RR, StdErr,
                       MeanLowerCL as RR_lower, MeanUpperCL as RR_upper
                from _rr&i
                where Label = 'RR Eczema vs. non-Eczema';
            quit;
        %end;
        %else %put WARNING: GENMOD produced no estimate for comorb_&i (check convergence);
    %end;
    data &out; set _rrs: ; run;
    proc datasets lib=work nolist; delete _rr: ; quit;
%mend rr_binary_adj;

/* RR for the 3-level exposure eczema1 (level 1 and level 2 vs none) */
%macro rr_multilevel(data=, out=, adjust=Y, n=31);
    %local i;
    proc datasets lib=work nolist; delete _rr: ; quit;
    %do i=1 %to &n;
        %get_category(&i)
        proc genmod data=&data descending;
            class eczema1 %if &adjust=Y %then %do; Gender race %end;
                  / param=reference ref=first;
            model comorb_&i = eczema1 %if &adjust=Y %then %do; age Gender race ADI %end;
                  / dist=binomial link=log &GENMOD_OPTS;
            estimate "RR Eczema &LEVEL1_LABEL vs. none" eczema1 1 0 / exp;
            estimate "RR Eczema &LEVEL2_LABEL vs. none" eczema1 0 1 / exp;
            ods output Estimates=_rr&i;
        run;
        %if %sysfunc(exist(_rr&i)) %then %do;
            proc sql;
                create table _rrs&i as
                select &i as cat_num, "&category" as category length=40, label,
                       MeanEstimate as RR, MeanLowerCL as Lower, MeanUpperCL as Upper
                from _rr&i
                where label like 'RR Eczema%';
            quit;
        %end;
        %else %put WARNING: GENMOD produced no estimate for comorb_&i (check convergence);
    %end;
    data &out; set _rrs: ; run;
    proc datasets lib=work nolist; delete _rr: ; quit;
%mend rr_multilevel;

/* OR for the 3-level exposure (logistic) */
%macro or_multilevel(data=, out=, adjust=Y, n=31);
    %local i;
    proc datasets lib=work nolist; delete _or: ; quit;
    %do i=1 %to &n;
        %get_category(&i)
        proc logistic data=&data;
            class eczema1(ref="0") %if &adjust=Y %then %do; Gender race %end;
                  / param=reference;
            model comorb_&i(event="1") = eczema1
                  %if &adjust=Y %then %do; age Gender race ADI %end;;
            ods output OddsRatios=_or&i;
        run;
        proc sql;
            create table _ors&i as
            select &i as cat_num, "&category" as category length=40,
                   case when Effect='eczema1 1 vs 0' then "&LEVEL1_LABEL vs. none"
                        else "&LEVEL2_LABEL vs. none" end as reference length=30,
                   OddsRatioEst as OR, LowerCL as Lower, UpperCL as Upper
            from _or&i
            where Effect in ('eczema1 1 vs 0','eczema1 2 vs 0');
        quit;
    %end;
    data &out; set _ors: ; run;
    proc datasets lib=work nolist; delete _or: ; quit;
%mend or_multilevel;

/* Prevalence (%) by exposure level, absolute difference and ratio */
%macro attrib_risk(data=, out=, n=31);
    %local i;
    %do i=1 %to &n;
        %get_category(&i)
        proc sql;
            create table _g as
            select eczema1, count(*) as n,
                   sum(comorb_&i=1) as n_outcome,
                   100*calculated n_outcome/calculated n as pct
            from &data group by eczema1;

            create table _ar&i as
            select &i as cat_num, "&category" as category length=40,
                   "&LEVEL1_LABEL vs none" as reference length=30,
                   a.pct as ref_pct, b.pct as pct,
                   a.n_outcome as no_eczema_n, b.n_outcome as eczema_n,
                   round(b.pct-a.pct, 0.001) as AR, round(b.pct/a.pct, 0.001) as RR
            from _g a, _g b where a.eczema1=0 and b.eczema1=1
            union all
            select &i, "&category", "&LEVEL2_LABEL vs none",
                   a.pct, b.pct, a.n_outcome, b.n_outcome,
                   round(b.pct-a.pct, 0.001), round(b.pct/a.pct, 0.001)
            from _g a, _g b where a.eczema1=0 and b.eczema1=2;
        quit;
    %end;
    data &out; set _ar1-_ar&n; run;
    proc datasets lib=work nolist; delete _g _ar1-_ar&n; quit;
%mend attrib_risk;
