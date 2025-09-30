# 👩‍⚕️ Demographic Burden of Diseases: Analyzing Age & Gender with SQL  

Healthcare challenges are not evenly distributed. Some diseases disproportionately affect children, while others weigh heavily on the elderly or on specific genders. Understanding this demographic burden is critical for policymakers, healthcare planners, and global health organizations.  

In this project, I used **MySQL 8.0** to explore a global health dataset and uncover which age and gender groups are most affected by major diseases such as **Malaria, Diabetes, HIV/AIDS, Tuberculosis, and COVID-19**.  

This project demonstrates how SQL can move beyond basic queries to deliver **policy-relevant insights** into global health inequalities.  

---

## 🧹 Preliminary Data Cleaning  

Like most real-world datasets, the global health dataset was not immediately analysis-ready. Before diving into queries, I had to handle several issues.  

### Challenges  
- Missing values in age group percentages (some countries didn’t report full demographic splits).  
- Inconsistent totals: in many rows, `ages_0_18_pct + ages_19_35_pct + ages_36_60_pct + ages_61_plus_pct` did not add up to 100%.  
- Duplicated or overlapping records across years and countries.  
- Variation in reporting: some countries consistently reported age and gender breakdowns, while others only did so intermittently.  

### Cleaning Steps  

**1. Removed duplicate rows** based on `(country_id, disease_id, year, gender)`  

```sql
DELETE t1 
FROM disease_statistics t1
JOIN disease_statistics t2
  ON t1.stat_id > t2.stat_id
 AND t1.country_id = t2.country_id
 AND t1.disease_id = t2.disease_id
 AND t1.year = t2.year
 AND t1.gender = t2.gender;
```

**2. Handled missing values** by replacing them with disease-specific averages  

```sql
UPDATE disease_statistics ds
JOIN (
    SELECT disease_id,
           AVG(ages_0_18_pct) AS avg_0_18,
           AVG(ages_19_35_pct) AS avg_19_35,
           AVG(ages_36_60_pct) AS avg_36_60,
           AVG(ages_61_plus_pct) AS avg_61_plus
    FROM disease_statistics
    WHERE ages_0_18_pct IS NOT NULL
      AND ages_19_35_pct IS NOT NULL
      AND ages_36_60_pct IS NOT NULL
      AND ages_61_plus_pct IS NOT NULL
    GROUP BY disease_id
) avgds ON ds.disease_id = avgds.disease_id
SET ds.ages_0_18_pct = COALESCE(ds.ages_0_18_pct, avgds.avg_0_18),
    ds.ages_19_35_pct = COALESCE(ds.ages_19_35_pct, avgds.avg_19_35),
    ds.ages_36_60_pct = COALESCE(ds.ages_36_60_pct, avgds.avg_36_60),
    ds.ages_61_plus_pct = COALESCE(ds.ages_61_plus_pct, avgds.avg_61_plus);
```

**3. Normalized percentages** so that age groups summed to ~100 for each record  

```sql
UPDATE disease_statistics
SET total = ages_0_18_pct + ages_19_35_pct + ages_36_60_pct + ages_61_plus_pct,
    ages_0_18_pct = (ages_0_18_pct / total) * 100,
    ages_19_35_pct = (ages_19_35_pct / total) * 100,
    ages_36_60_pct = (ages_36_60_pct / total) * 100,
    ages_61_plus_pct = (ages_61_plus_pct / total) * 100;
```

With these steps, the dataset became **clean, consistent, and reliable** — ready for deeper analysis.  

---

## 🧹 Data Preparation  

The dataset contained detailed disease statistics across countries and years, including:  
- **Age distribution** of affected populations:  
  - `ages_0_18_pct`, `ages_19_35_pct`, `ages_36_60_pct`, `ages_61_plus_pct`  
- **Gender** (Male or Female)  
- **Population affected** (`pop_affected`)  

To simplify analysis, I created a **normalized view**:  

```sql
CREATE OR REPLACE VIEW vw_disease_age_normalized_2010_2020 AS
SELECT 
  ds.stat_id, d.disease_name, ds.gender, cys.country_id, cys.year, ds.pop_affected,
  (COALESCE(ds.ages_0_18_pct,0)) AS norm_0_18_pct,
  (COALESCE(ds.ages_19_35_pct,0)) AS norm_19_35_pct,
  (COALESCE(ds.ages_36_60_pct,0)) AS norm_36_60_pct,
  (COALESCE(ds.ages_61_plus_pct,0)) AS norm_61_plus_pct
FROM disease_statistics ds
JOIN country_year_stats cys ON ds.cy_id = cys.cy_id
JOIN diseases d USING(disease_id)
WHERE cys.year BETWEEN 2010 AND 2020;
```

---

## 📊 Insights from the Data  

### 1. Age Breakdown by Disease & Gender  

```sql
SELECT d.disease_name, v.gender,
       ROUND(AVG(v.norm_0_18_pct),2) AS avg_0_18,
       ROUND(AVG(v.norm_19_35_pct),2) AS avg_19_35,
       ROUND(AVG(v.norm_36_60_pct),2) AS avg_36_60,
       ROUND(AVG(v.norm_61_plus_pct),2) AS avg_61_plus
FROM vw_disease_age_normalized_2010_2020 v
JOIN diseases d USING(disease_id)
WHERE d.disease_name IN ('Malaria','Diabetes','HIV/AIDS','Tuberculosis','COVID-19')
GROUP BY d.disease_name, v.gender
ORDER BY d.disease_name, v.gender;
```

**Findings:**  
- **Malaria** → Over 50% in children (0–18).  
- **Diabetes** → Skews toward 36–60 and 61+, especially females.  
- **HIV/AIDS** → Dominant in 19–35, higher in females.  
- **Tuberculosis** → Spread across working ages, higher in males.  
- **COVID-19** → Burden is highest in the 61+ group.  

---

### 2. Population-Weighted Analysis  

```sql
SELECT d.disease_name, v.gender,
       ROUND(SUM(v.pop_affected * v.norm_0_18_pct / 100) / SUM(v.pop_affected) * 100,2) AS weighted_pct_0_18,
       ROUND(SUM(v.pop_affected * v.norm_19_35_pct / 100) / SUM(v.pop_affected) * 100,2) AS weighted_pct_19_35,
       ROUND(SUM(v.pop_affected * v.norm_36_60_pct / 100) / SUM(v.pop_affected) * 100,2) AS weighted_pct_36_60,
       ROUND(SUM(v.pop_affected * v.norm_61_plus_pct / 100) / SUM(v.pop_affected) * 100,2) AS weighted_pct_61_plus
FROM vw_disease_age_normalized_2010_2020 v
JOIN diseases d USING(disease_id)
WHERE d.disease_name IN ('Malaria','Diabetes','HIV/AIDS','Tuberculosis','COVID-19')
GROUP BY d.disease_name, v.gender
ORDER BY d.disease_name, v.gender;
```

**Findings:**  
- Malaria → Even more skewed toward children once **population weights** applied.  
- Diabetes → **61+ dominates** more strongly, reflecting aging populations.  
- HIV/AIDS → Still concentrated in **young adults**, showing socio-behavioral vulnerability.  

---

### 3. Diseases Disproportionately Affecting Children  

```sql
SELECT d.disease_name,
       ROUND(SUM(v.pop_affected * v.norm_0_18_pct / 100) / SUM(v.pop_affected) * 100,2) AS pct_children
FROM vw_disease_age_normalized_2010_2020 v
JOIN diseases d USING(disease_id)
GROUP BY d.disease_name
ORDER BY pct_children DESC
LIMIT 10;
```

**Results:**  
- **Malaria** and **Respiratory Infections** topped the list with >50% of cases in children.  
- **Chronic diseases** like Diabetes and Cancer had <10% in children, confirming they are **age-linked**.  

---

### 4. Gender Differences in Prevalence  

```sql
WITH per_gender_stats AS (
    SELECT d.disease_name, ds.gender,
           AVG(ds.prevalence_pct) AS mean_prev,
           COUNT(*) AS n
    FROM disease_statistics ds
    JOIN country_year_stats cys ON ds.cy_id = cys.cy_id
    JOIN diseases d USING(disease_id)
    WHERE cys.year BETWEEN 2010 AND 2020
    GROUP BY d.disease_name, ds.gender
)
SELECT *
FROM per_gender_stats
ORDER BY disease_name, gender;
```

**Findings:**  
- Tuberculosis → higher in **men**.  
- HIV/AIDS & Diabetes → higher in **women**.  
- COVID-19 → fairly balanced, but **higher male mortality** in related analyses.  

---

### 5. Time Trends in Demographics  

```sql
SELECT cys.year,
       ROUND(SUM(v.pop_affected * v.norm_0_18_pct / 100) / SUM(v.pop_affected) * 100,2) AS pct_children
FROM vw_disease_age_normalized_2010_2020 v
JOIN country_year_stats cys ON v.country_id = cys.country_id AND v.year = cys.year
JOIN diseases d USING(disease_id)
WHERE d.disease_name = 'Malaria'
GROUP BY cys.year
ORDER BY cys.year;
```

**Results:**  
- Malaria → **Child cases declined slightly after 2015**, suggesting progress in child-focused interventions.  
- HIV/AIDS → Remained **high in young adults** across all years.  

---

## 🔑 Key Takeaways  

1. Children carry the **heaviest burden** of **Malaria** and **Respiratory Infections**.  
2. **Chronic diseases** like **Diabetes** and **Cancer** affect **older age groups**, especially **61+**.  
3. **HIV/AIDS** remains concentrated in **young adults**, with **women more affected** than men.  
4. **Tuberculosis** impacts men more heavily.  
5. Trends show **modest improvements** for children in Malaria cases, but **persistent HIV/AIDS challenges**.  

## ⚠️ Disclaimer

The dataset used in this project is synthetic and does not represent real-world health data. It was created solely for educational and portfolio purposes to demonstrate SQL and data analysis techniques. Any similarities to actual countries, statistics, or health outcomes are purely coincidental.
