/* ============================================================
   DEMOGRAPHIC BURDEN ANALYSIS (AGE & GENDER)
   Schema: global_health_dataset_main
   Purpose: determine which age/gender groups are most affected
            by major diseases; provide both %-based and
            population-weighted analyses and time trends.
   NOTE: run this script step-by-step; comments explain each part.
   ============================================================ */

-- ------------------------------------------------------------
-- STEP 0: Use the correct schema
-- ------------------------------------------------------------
USE global_health_dataset_main;

-- ------------------------------------------------------------
-- STEP 1: Quick sanity checks (what's in the disease table?)
-- ------------------------------------------------------------
/* Count total rows, distinct diseases, and gender values so we know
   what we're working with. This helps identify empty or malformed data. */
-- total rows in disease_statistics
SELECT COUNT(*) AS total_disease_records FROM disease_statistics;

-- how many distinct diseases are present
SELECT COUNT(DISTINCT disease_id) AS num_distinct_diseases FROM disease_statistics;

-- disease names (human readable) and count per disease
SELECT d.disease_name, COUNT(*) AS records_per_disease
FROM disease_statistics ds
JOIN diseases d USING(disease_id)
GROUP BY d.disease_name
ORDER BY records_per_disease DESC
LIMIT 20;

-- distinct genders used in the data
SELECT DISTINCT gender FROM disease_statistics;

-- Which years are present in disease_statistics (note: year is in country_year_stats; we join)
SELECT DISTINCT cys.year
FROM disease_statistics ds
JOIN country_year_stats cys ON ds.cy_id = cys.cy_id
ORDER BY cys.year;

-- ------------------------------------------------------------
-- STEP 2: Check missingness for key demographic columns
-- ------------------------------------------------------------
/* Check how many rows lack age breakdowns or population affected.
   If many rows are NULL for ages_... or pop_affected, we should impute
   or exclude these rows from certain analyses. */
SELECT 
  SUM(ages_0_18_pct IS NULL) AS miss_0_18,
  SUM(ages_19_35_pct IS NULL) AS miss_19_35,
  SUM(ages_36_60_pct IS NULL) AS miss_36_60,
  SUM(ages_61_plus_pct IS NULL) AS miss_61_plus,
  SUM(pop_affected IS NULL) AS miss_pop_affected
FROM disease_statistics;

-- ------------------------------------------------------------
-- STEP 3: Validate age percentage sums (should normally ~100)
-- ------------------------------------------------------------
/* For each record, compute the sum of the age-percentage columns.
   If the sum deviates strongly from 100 it indicates data quality issues. */
SELECT 
  COUNT(*) AS total_records,
  ROUND(AVG(sum_ages),3) AS avg_sum_ages,
  ROUND(MIN(sum_ages),3) AS min_sum_ages,
  ROUND(MAX(sum_ages),3) AS max_sum_ages,
  SUM(ABS(sum_ages - 100) > 5) AS num_records_off_by_more_than_5_pct,
  SUM(ABS(sum_ages - 100) > 1) AS num_records_off_by_more_than_1_pct
FROM (
  SELECT 
    (COALESCE(ages_0_18_pct,0) 
     + COALESCE(ages_19_35_pct,0) 
     + COALESCE(ages_36_60_pct,0) 
     + COALESCE(ages_61_plus_pct,0)
    ) AS sum_ages
  FROM disease_statistics
) t;

-- If many rows are off by >5, you'll want to inspect examples:
SELECT ds.stat_id, d.disease_name, cys.country_id, cys.year,
       ages_0_18_pct, ages_19_35_pct, ages_36_60_pct, ages_61_plus_pct,
       (COALESCE(ages_0_18_pct,0)+COALESCE(ages_19_35_pct,0)+COALESCE(ages_36_60_pct,0)+COALESCE(ages_61_plus_pct,0)) AS sum_ages
FROM disease_statistics ds
JOIN country_year_stats cys ON ds.cy_id = cys.cy_id
JOIN diseases d USING(disease_id)
WHERE ABS(
      COALESCE(ages_0_18_pct,0)
    + COALESCE(ages_19_35_pct,0)
    + COALESCE(ages_36_60_pct,0)
    + COALESCE(ages_61_plus_pct,0)
  - 100) > 5
LIMIT 50;

-- ------------------------------------------------------------
-- STEP 4: Create helper summaries for imputation (if needed)
-- ------------------------------------------------------------
/* Many records may have NULLs in age percentage columns. We'll compute:
   1) disease+gender averages for the chosen year-range (2010-2020)
   2) disease overall averages (across genders) as fallback
   We'll use these averages to impute missing values later.
   Change the BETWEEN (...) years to your target range if needed. */

-- 4A: disease + gender average age distribution (2010-2020)
CREATE OR REPLACE VIEW vw_disease_gender_age_avg_2010_2020 AS
SELECT 
  ds.disease_id,
  ds.gender,
  AVG(ds.ages_0_18_pct)  AS avg_0_18_pct,
  AVG(ds.ages_19_35_pct) AS avg_19_35_pct,
  AVG(ds.ages_36_60_pct) AS avg_36_60_pct,
  AVG(ds.ages_61_plus_pct) AS avg_61_plus_pct,
  COUNT(*) AS records_used
FROM disease_statistics ds
JOIN country_year_stats cys ON ds.cy_id = cys.cy_id
WHERE cys.year BETWEEN 2010 AND 2020
GROUP BY ds.disease_id, ds.gender;

-- 4B: disease overall average (all genders combined) as fallback
CREATE OR REPLACE VIEW vw_disease_overall_age_avg_2010_2020 AS
SELECT 
  ds.disease_id,
  AVG(ds.ages_0_18_pct)  AS avg_0_18_pct,
  AVG(ds.ages_19_35_pct) AS avg_19_35_pct,
  AVG(ds.ages_36_60_pct) AS avg_36_60_pct,
  AVG(ds.ages_61_plus_pct) AS avg_61_plus_pct,
  COUNT(*) AS records_used
FROM disease_statistics ds
JOIN country_year_stats cys ON ds.cy_id = cys.cy_id
WHERE cys.year BETWEEN 2010 AND 2020
GROUP BY ds.disease_id;

-- Inspect a few disease+gender averages
SELECT d.disease_name, vg.gender, vg.avg_0_18_pct, vg.avg_19_35_pct, vg.avg_36_60_pct, vg.avg_61_plus_pct, vg.records_used
FROM vw_disease_gender_age_avg_2010_2020 vg
JOIN diseases d USING(disease_id)
ORDER BY vg.records_used DESC
LIMIT 20;

-- ------------------------------------------------------------
-- STEP 5: Build a normalized / imputed view of demographic shares
-- ------------------------------------------------------------
/* This view:
   - restricts records to the year range 2010-2020 (change if needed)
   - fills NULL age percentages using disease+gender average, then disease overall average,
     then 0 (last resort)
   - normalizes the resulting age values so they sum to 100 (this avoids
     minor inconsistencies in raw sums)
   The resulting view gives reliable `norm_*` columns you can use for
   both %-based averages and population-weighted estimates.
*/

CREATE OR REPLACE VIEW vw_disease_age_normalized_2010_2020 AS
SELECT 
  t.stat_id,
  t.disease_id,
  t.disease_name,
  t.gender,
  t.country_id,
  t.year,
  t.pop_affected,
  -- original raw columns are preserved for traceability
  t.orig_0_18_pct,
  t.orig_19_35_pct,
  t.orig_36_60_pct,
  t.orig_61_plus_pct,
  -- imputed (pre-normalization) values
  t.a0, t.a19, t.a36, t.a61,
  -- sum of imputed values (pre-normalization)
  (t.a0 + t.a19 + t.a36 + t.a61) AS sum_imputed,
  -- normalized percentages (guaranteed to sum to ~100 unless sum_imputed = 0)
  CASE WHEN (t.a0 + t.a19 + t.a36 + t.a61) > 0 THEN (t.a0 / (t.a0 + t.a19 + t.a36 + t.a61)) * 100 ELSE NULL END AS norm_0_18_pct,
  CASE WHEN (t.a0 + t.a19 + t.a36 + t.a61) > 0 THEN (t.a19 / (t.a0 + t.a19 + t.a36 + t.a61)) * 100 ELSE NULL END AS norm_19_35_pct,
  CASE WHEN (t.a0 + t.a19 + t.a36 + t.a61) > 0 THEN (t.a36 / (t.a0 + t.a19 + t.a36 + t.a61)) * 100 ELSE NULL END AS norm_36_60_pct,
  CASE WHEN (t.a0 + t.a19 + t.a36 + t.a61) > 0 THEN (t.a61 / (t.a0 + t.a19 + t.a36 + t.a61)) * 100 ELSE NULL END AS norm_61_plus_pct
FROM (
  /* inner: compute imputed a0,a19,a36,a61 using disease+gender avg -> disease avg -> 0 */
  SELECT
    ds.stat_id,
    ds.disease_id,
    d.disease_name,
    ds.gender,
    cys.country_id,
    cys.year,
    ds.pop_affected,
    ds.ages_0_18_pct  AS orig_0_18_pct,
    ds.ages_19_35_pct AS orig_19_35_pct,
    ds.ages_36_60_pct AS orig_36_60_pct,
    ds.ages_61_plus_pct AS orig_61_plus_pct,
    -- a0: choose ds value if present, else disease+gender avg, else disease overall avg, else 0
    COALESCE(
      ds.ages_0_18_pct,
      (SELECT avg_0_18_pct FROM vw_disease_gender_age_avg_2010_2020 dg WHERE dg.disease_id = ds.disease_id AND dg.gender = ds.gender LIMIT 1),
      (SELECT avg_0_18_pct FROM vw_disease_overall_age_avg_2010_2020 doag WHERE doag.disease_id = ds.disease_id LIMIT 1),
      0
    ) AS a0,
    COALESCE(
      ds.ages_19_35_pct,
      (SELECT avg_19_35_pct FROM vw_disease_gender_age_avg_2010_2020 dg WHERE dg.disease_id = ds.disease_id AND dg.gender = ds.gender LIMIT 1),
      (SELECT avg_19_35_pct FROM vw_disease_overall_age_avg_2010_2020 doag WHERE doag.disease_id = ds.disease_id LIMIT 1),
      0
    ) AS a19,
    COALESCE(
      ds.ages_36_60_pct,
      (SELECT avg_36_60_pct FROM vw_disease_gender_age_avg_2010_2020 dg WHERE dg.disease_id = ds.disease_id AND dg.gender = ds.gender LIMIT 1),
      (SELECT avg_36_60_pct FROM vw_disease_overall_age_avg_2010_2020 doag WHERE doag.disease_id = ds.disease_id LIMIT 1),
      0
    ) AS a36,
    COALESCE(
      ds.ages_61_plus_pct,
      (SELECT avg_61_plus_pct FROM vw_disease_gender_age_avg_2010_2020 dg WHERE dg.disease_id = ds.disease_id AND dg.gender = ds.gender LIMIT 1),
      (SELECT avg_61_plus_pct FROM vw_disease_overall_age_avg_2010_2020 doag WHERE doag.disease_id = ds.disease_id LIMIT 1),
      0
    ) AS a61
  FROM disease_statistics ds
  JOIN country_year_stats cys ON ds.cy_id = cys.cy_id
  JOIN diseases d USING(disease_id)
  WHERE cys.year BETWEEN 2010 AND 2020
) t;

-- Quick sanity: check normalized columns sum ~100
SELECT 
  COUNT(*) AS rows_checked,
  ROUND(AVG(norm_0_18_pct + norm_19_35_pct + norm_36_60_pct + norm_61_plus_pct),3) AS avg_norm_sum,
  ROUND(MIN(norm_0_18_pct + norm_19_35_pct + norm_36_60_pct + norm_61_plus_pct),3) AS min_norm_sum,
  ROUND(MAX(norm_0_18_pct + norm_19_35_pct + norm_36_60_pct + norm_61_plus_pct),3) AS max_norm_sum
FROM vw_disease_age_normalized_2010_2020;

-- ------------------------------------------------------------
-- STEP 6: Core analysis 1 — Average age-share by disease & gender
-- ------------------------------------------------------------
/* We present:
   - unweighted averages of normalized age shares (simple AVG)
   - population-weighted averages (using pop_affected)
   The weighted averages are stronger: they reflect where most of the
   affected people are concentrated, not just the average of records.
   Focus on a subset of major diseases — change list as you like.
*/

-- Define diseases of interest (example set); you can expand this list
SET @disease_list = "'Malaria','Diabetes','HIV/AIDS','Tuberculosis','COVID-19'";

-- 6A: Unweighted average of normalized age shares by disease & gender
SELECT 
  d.disease_name,
  v.gender,
  ROUND(AVG(v.norm_0_18_pct),2)  AS avg_pct_0_18_unweighted,
  ROUND(AVG(v.norm_19_35_pct),2) AS avg_pct_19_35_unweighted,
  ROUND(AVG(v.norm_36_60_pct),2) AS avg_pct_36_60_unweighted,
  ROUND(AVG(v.norm_61_plus_pct),2) AS avg_pct_61_plus_unweighted,
  COUNT(*) AS records_used
FROM vw_disease_age_normalized_2010_2020 v
JOIN diseases d USING(disease_id)
WHERE d.disease_name IN ('Malaria','Diabetes','HIV/AIDS','Tuberculosis','COVID-19')
GROUP BY d.disease_name, v.gender
ORDER BY d.disease_name, v.gender;

-- 6B: Population-weighted age-share by disease & gender
/* Weighted share: (sum over records of pop_affected * norm_x_pct/100) 
   divided by total pop_affected. This answers: "Of the people affected,
   what percent are in each age group?" */
SELECT 
  d.disease_name,
  v.gender,
  ROUND(SUM(v.pop_affected * v.norm_0_18_pct / 100) / NULLIF(SUM(v.pop_affected),0) * 100,2)  AS weighted_pct_0_18,
  ROUND(SUM(v.pop_affected * v.norm_19_35_pct / 100) / NULLIF(SUM(v.pop_affected),0) * 100,2) AS weighted_pct_19_35,
  ROUND(SUM(v.pop_affected * v.norm_36_60_pct / 100) / NULLIF(SUM(v.pop_affected),0) * 100,2) AS weighted_pct_36_60,
  ROUND(SUM(v.pop_affected * v.norm_61_plus_pct / 100) / NULLIF(SUM(v.pop_affected),0) * 100,2) AS weighted_pct_61_plus,
  SUM(v.pop_affected) AS total_pop_affected_in_group
FROM vw_disease_age_normalized_2010_2020 v
JOIN diseases d USING(disease_id)
WHERE d.disease_name IN ('Malaria','Diabetes','HIV/AIDS','Tuberculosis','COVID-19')
  AND v.pop_affected IS NOT NULL
GROUP BY d.disease_name, v.gender
ORDER BY d.disease_name, v.gender;

-- ------------------------------------------------------------
-- STEP 7: Core analysis 2 — Absolute burden per age group (counts)
-- ------------------------------------------------------------
/* Compute estimated affected counts per age bracket:
   estimated_affected_age0 = pop_affected * norm_0_18_pct / 100
   Then sum across records to get global (2010-2020) totals per disease & gender.
   This gives the absolute counts and relative shares.
*/
SELECT 
  d.disease_name,
  v.gender,
  ROUND(SUM(v.pop_affected * v.norm_0_18_pct / 100)) AS affected_0_18,
  ROUND(SUM(v.pop_affected * v.norm_19_35_pct / 100)) AS affected_19_35,
  ROUND(SUM(v.pop_affected * v.norm_36_60_pct / 100)) AS affected_36_60,
  ROUND(SUM(v.pop_affected * v.norm_61_plus_pct / 100)) AS affected_61_plus,
  ROUND(SUM(v.pop_affected)) AS total_estimated_affected
FROM vw_disease_age_normalized_2010_2020 v
JOIN diseases d USING(disease_id)
WHERE d.disease_name IN ('Malaria','Diabetes','HIV/AIDS','Tuberculosis','COVID-19')
  AND v.pop_affected IS NOT NULL
GROUP BY d.disease_name, v.gender
ORDER BY d.disease_name, v.gender;

-- ------------------------------------------------------------
-- STEP 8: Identify diseases disproportionately affecting children (0–18)
-- ------------------------------------------------------------
/* We compute the share of total affected (all genders combined) that are 0–18.
   Then list diseases where children account for a large share (e.g., > 50%).
*/
SELECT 
  d.disease_name,
  ROUND(SUM(v.pop_affected * v.norm_0_18_pct / 100) / NULLIF(SUM(v.pop_affected),0) * 100,2) AS pct_children_weighted,
  ROUND(SUM(v.pop_affected)) AS total_affected
FROM vw_disease_age_normalized_2010_2020 v
JOIN diseases d USING(disease_id)
WHERE v.pop_affected IS NOT NULL
GROUP BY d.disease_name
HAVING pct_children_weighted IS NOT NULL
ORDER BY pct_children_weighted DESC
LIMIT 20;

-- ------------------------------------------------------------
-- STEP 9: Male vs Female comparison (prevalence & age-share)
-- ------------------------------------------------------------
/* For each disease, compute:
   - population-weighted age share for males and females
   - mean prevalence_pct by gender (unweighted)
   - an approximate t-statistic for difference in mean prevalence between genders
     (NOTE: this t-statistic is computed in SQL for exploratory purposes only.
      P-value computation is not included here; use statistical tools if you need
      a formal test.)
*/

-- 9A: Weighted age-shares side-by-side for male vs female
SELECT
  d.disease_name,
  ROUND(SUM(CASE WHEN v.gender='Male' THEN v.pop_affected * v.norm_0_18_pct / 100 ELSE 0 END) / NULLIF(SUM(CASE WHEN v.gender='Male' THEN v.pop_affected ELSE 0 END),0) * 100, 2) AS male_pct_0_18,
  ROUND(SUM(CASE WHEN v.gender='Female' THEN v.pop_affected * v.norm_0_18_pct / 100 ELSE 0 END) / NULLIF(SUM(CASE WHEN v.gender='Female' THEN v.pop_affected ELSE 0 END),0) * 100, 2) AS female_pct_0_18,
  -- repeat for other age groups if desired
  SUM(CASE WHEN v.gender='Male' THEN v.pop_affected ELSE 0 END) AS male_total_affected,
  SUM(CASE WHEN v.gender='Female' THEN v.pop_affected ELSE 0 END) AS female_total_affected
FROM vw_disease_age_normalized_2010_2020 v
JOIN diseases d USING(disease_id)
WHERE v.pop_affected IS NOT NULL
GROUP BY d.disease_name
ORDER BY d.disease_name;

-- 9B: Difference in mean prevalence (approx t-statistic) by gender
/* We compute mean_prevalence, sd_prevalence and counts by gender per disease, then compute
   t_stat = (mean_male - mean_female) / sqrt(sd_male^2/n_male + sd_female^2/n_female).
   This gives a measure of how separated male/female prevalence values are.
*/
WITH per_gender_stats AS (
  SELECT 
    d.disease_id,
    d.disease_name,
    ds.gender,
    AVG(ds.prevalence_pct) AS mean_prev,
    STDDEV_SAMP(ds.prevalence_pct) AS sd_prev,
    COUNT(*) AS n_records
  FROM disease_statistics ds
  JOIN country_year_stats cys ON ds.cy_id = cys.cy_id
  JOIN diseases d USING(disease_id)
  WHERE cys.year BETWEEN 2010 AND 2020
    AND ds.prevalence_pct IS NOT NULL
  GROUP BY d.disease_id, d.disease_name, ds.gender
)
SELECT 
  m.disease_name,
  m.mean_prev AS mean_prev_male,
  f.mean_prev AS mean_prev_female,
  m.sd_prev    AS sd_prev_male,
  f.sd_prev    AS sd_prev_female,
  m.n_records  AS n_male,
  f.n_records  AS n_female,
  CASE
    WHEN m.n_records > 0 AND f.n_records > 0 THEN
      (m.mean_prev - f.mean_prev) / 
      SQRT( (POWER(m.sd_prev,2) / m.n_records) + (POWER(f.sd_prev,2) / f.n_records) )
    ELSE NULL
  END AS approx_t_stat
FROM 
  (SELECT * FROM per_gender_stats WHERE gender='Male') m
  JOIN (SELECT * FROM per_gender_stats WHERE gender='Female') f
    ON m.disease_id = f.disease_id
ORDER BY ABS(approx_t_stat) DESC
LIMIT 30;

-- NOTE: approximate_t_stat is for exploratory evidence. For a formal p-value / CI, export results to R/Python.

-- ------------------------------------------------------------
-- STEP 10: Time trends: Are age-shares shifting over time?
-- ------------------------------------------------------------
/* Example: for Malaria show year-by-year population-weighted % of cases in 0-18.
   Replace 'Malaria' with disease(s) of interest.
*/
SELECT 
  cys.year,
  ROUND(SUM(v.pop_affected * v.norm_0_18_pct / 100) / NULLIF(SUM(v.pop_affected),0) * 100,2) AS pct_0_18_weighted,
  ROUND(SUM(v.pop_affected),0) AS total_affected
FROM vw_disease_age_normalized_2010_2020 v
JOIN country_year_stats cys ON v.country_id = cys.country_id AND v.year = cys.year
JOIN diseases d USING(disease_id)
WHERE d.disease_name = 'Malaria'
GROUP BY cys.year
ORDER BY cys.year;

-- You can use the previous query to plot a time series (year vs pct_0_18_weighted).
-- Repeat for other age groups and diseases as needed.

-- ------------------------------------------------------------
-- STEP 11: Create a summary table for reporting / export
-- ------------------------------------------------------------
/* Save a compact summary per disease & gender so you can export to CSV or embed in a dashboard.
   This summary contains weighted shares and totals. */
DROP TABLE IF EXISTS summary_disease_demographics;
CREATE TABLE summary_disease_demographics AS
SELECT 
  d.disease_name,
  v.gender,
  ROUND(SUM(v.pop_affected * v.norm_0_18_pct / 100) / NULLIF(SUM(v.pop_affected),0) * 100,2)  AS pct_0_18_weighted,
  ROUND(SUM(v.pop_affected * v.norm_19_35_pct / 100) / NULLIF(SUM(v.pop_affected),0) * 100,2) AS pct_19_35_weighted,
  ROUND(SUM(v.pop_affected * v.norm_36_60_pct / 100) / NULLIF(SUM(v.pop_affected),0) * 100,2) AS pct_36_60_weighted,
  ROUND(SUM(v.pop_affected * v.norm_61_plus_pct / 100) / NULLIF(SUM(v.pop_affected),0) * 100,2) AS pct_61_plus_weighted,
  ROUND(SUM(v.pop_affected)) AS total_estimated_affected
FROM vw_disease_age_normalized_2010_2020 v
JOIN diseases d USING(disease_id)
WHERE v.pop_affected IS NOT NULL
GROUP BY d.disease_name, v.gender;

-- Quick look at the summary table
SELECT * FROM summary_disease_demographics ORDER BY total_estimated_affected DESC LIMIT 50;

-- ------------------------------------------------------------
-- STEP 12: Export tips
-- ------------------------------------------------------------
/* If you have FILE privilege on the DB server, you can create a CSV:
   (change the path to a server-writable location). If not, run the summary query
   in MySQL Workbench and use its export facility.
*/
-- Example (may fail if you lack FILE privilege or server write access):
/*
SELECT * 
INTO OUTFILE '/tmp/summary_disease_demographics.csv'
FIELDS TERMINATED BY ',' 
ENCLOSED BY '"' 
LINES TERMINATED BY '\n'
FROM summary_disease_demographics;
*/

-- ------------------------------------------------------------
-- STEP 13: Interpretation guidance & next steps (comments)
-- ------------------------------------------------------------
/* Interpret results carefully:
   - Weighted shares (by pop_affected) better reflect the absolute burden.
   - Unweighted averages reflect the "typical" record but may be dominated by
     small-country or sparse reporting.
   - If many records had missing pop_affected, weighted metrics will ignore them.
   - Age buckets may be reported differently across sources — normalization helps,
     but definitions may still vary.
   - Gender field here is binary ('Male'/'Female'). If your data contains other values,
     adapt queries accordingly.

   Suggested next steps:
   1) Visualize top diseases by child burden (bar chart) and year trends (line chart).
   2) Drill down by country/region: compute country-level child burden for Malaria, etc.
   3) Combine with healthcare infrastructure (doctors_per_1000) to see if countries with
      more doctors have lower child shares for certain diseases.
   4) Export results for statistical testing in R/Python if you need formal hypothesis tests.
*/
