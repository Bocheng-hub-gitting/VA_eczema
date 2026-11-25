/***********************************************************************
 Program : config.sas
 Purpose : Site- and study-specific settings for the eczema comorbidity
           project. EDIT THIS FILE ONLY - no paths or data-source names
           are hard-coded anywhere else.
 Author  : Bocheng Jing

 SECURITY: Never commit patient-level data, SCRSSN lists, logs with
           identifiers, or the real values of the placeholders below.
***********************************************************************/

/* ------------------------------------------------------------------ */
/* 1. Locations (replace placeholders)                                 */
/* ------------------------------------------------------------------ */
%let PROGRAM_DIR = /path/to/programs;        /* where these .sas files live       */
%let DATA_DIR    = /path/to/analysis_data;   /* analysis datasets (output)        */
%let PRIOR_DIR   = /path/to/prior_extracts;  /* prior-project VA extracts (below) */
%let ADI_DIR     = /path/to/adi;             /* Area Deprivation Index linkage    */
%let ICD_DIR     = /path/to/code_lists;      /* ICD-10 code list spreadsheets     */

libname data  "&DATA_DIR";
libname data1 "&PRIOR_DIR";   /* must contain: va_diagnosis, vaop, vaip */
libname adi   "&ADI_DIR";     /* must contain: cohort4_adi_pat_pssg     */

/* Pre-assigned libraries expected from the site environment:
     S4016SRC  - CDW source tables (Spatient_Spatient, MedSAS_outp_SE,
                 PatSub_PatientRace, PatSub_PatientEthnicity, DSS_PHA)
     SHIP2252  - Medicare base files (CA/IP/OP yy_BASE_SHIP2252)
   &SQL_OPTIMAL is expected from the site autoexec (SQL Server options). */

%let SRC_DB = YOUR_SQL_DATASOURCE;           /* CDW project data source name */
libname cdw sqlsvr DATASRC=&SRC_DB. &SQL_OPTIMAL.;

/* Table-1 helper macro (%stat_table). Not part of this repository. */
%include "&PROGRAM_DIR/stat_table.sas";

/* Code-list spreadsheets (placed in &ICD_DIR) */
%let ICD_FILE_TARGETED = targeted_ICD10.xlsx;          /* comorbidity code list  */
%let ICD_FILE_SKIN     = targeted_ICD10_skin_infection.xlsx;
%let STOPCODE_DERM = 304;
%let STOPCODE_ED   = 130;
%let STOPCODE_PC   = 322,323,338,348,531;

/* ------------------------------------------------------------------ */
/* 2. Analysis switches                                                */
/* ------------------------------------------------------------------ */
/* Which diagnosis fields are searched for a code:
     ALL   = every diagnosis field on the record (recommended)
     FIRST = only the first field in the array (VA: DXF2; Medicare: CD1).
             The original program looped "do i=1 to 1", i.e. FIRST.        */
%let DX_SCOPE = ALL;

/* Extra options on the GENMOD MODEL statement for log-binomial models.
   Original code used INTERCEPT=-4. Verify in the GENMOD output that the
   intercept is ESTIMATED (non-zero standard error) and not fixed at -4;
   if it is fixed, set this to blank or use a modified-Poisson model.   */
%let GENMOD_OPTS = intercept=-4;

/* Labels for the 3-level exposure eczema1 (0 none / 1 / 2 severe)     */
%let LEVEL1_LABEL = Moderate;   /* eczema, not severe */
%let LEVEL2_LABEL = Severe;

/* Cohort rule: keep persons born ON OR BEFORE this date               */
%let BIRTH_CUTOFF = '01JAN1970'd;

/* Race assigned when no race record exists (original: WHITE)          */
%let RACE_IF_MISSING = WHITE;

/* Dx field lists */
%let VA_DX_VARS  = DXF2-DXF25 DXPRIME DXLSF;
%let MCR_DX_VARS = ICD_DGNS_CD1-ICD_DGNS_CD25;

/* Severity: HCPCS/CPT codes (prefix match). NOTE: includes phototherapy
   codes AND drug-administration/drug HCPCS codes, plus 96372 (generic
   injection) - confirm this matches the protocol definition.          */
%let SEV_CPT_CODES = "E0691","C9399","J3590","J8610","J8611","J8612",
                     "J7502","J7515","J7516","J7517","J7518","J7519",
                     "J7500","J7501","96900","96910","96913","96912","96372";

/* Default diagnosis sources used by %any_dx (set per script before use) */
%let SRC1_DS=; %let SRC1_VARS=; %let SRC1_DATE=;
%let SRC2_DS=; %let SRC2_VARS=; %let SRC2_DATE=;
%let SRC3_DS=; %let SRC3_VARS=; %let SRC3_DATE=;

options mprint nosymbolgen;
