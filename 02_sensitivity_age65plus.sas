/***********************************************************************
 Program : 02_sensitivity_age65plus.sas
 Purpose : Sensitivity analysis - repeat the main comorbidity analyses
           restricted to participants aged 65+ (potential age-related bias).
 Author  : Bocheng Jing
 Date    : 2024/12/14 (original); cleaned for release
 Input   : DATA.cohort_8 and DATA.index_comorbidity (from program 01)
 Output  : DATA.res65_*
***********************************************************************/

%include "config.sas";
%include "macros.sas";

data senior;
    set data.cohort_8;
    where age >= 65;
run;
/* QC: confirm this is a meaningful subset of the main cohort */
%qc_count(data.cohort_8, id=scrssn);
%qc_count(senior,        id=scrssn);

%risk_2x2      (data=senior, out=data.res65_rr_unadj_binary);
%rr_binary_adj (data=senior, out=data.res65_rr_adj_binary);

%rr_multilevel (data=senior, out=data.res65_rr_multi_adj,   adjust=Y);
%rr_multilevel (data=senior, out=data.res65_rr_multi_unadj, adjust=N);
%or_multilevel (data=senior, out=data.res65_or_multi_adj,   adjust=Y);
%or_multilevel (data=senior, out=data.res65_or_multi_unadj, adjust=N);
%attrib_risk   (data=senior, out=data.res65_attrib_risk);
