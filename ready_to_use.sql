-- =====================================================
-- 直接可用的SQL脚本：替代Python数据处理
-- 使用说明：只需将 'your_table_name' 替换为实际表名即可执行
-- =====================================================

WITH 
preprocessed_data AS (
    SELECT *,
           DATE(SUBSTRING(risk_time, 1, 10)) AS apply_date
    FROM your_table_name  -- ← 请替换为实际表名
),

base_period AS (
    SELECT MIN(apply_date) AS earliest_date,
           DATE_ADD(MIN(apply_date), INTERVAL 5 DAY) AS end_date_base
    FROM preprocessed_data
),

base_data_clean AS (
    SELECT p.pred_score
    FROM preprocessed_data p
    CROSS JOIN base_period bp
    WHERE p.apply_date >= bp.earliest_date
      AND p.apply_date <= bp.end_date_base
      AND p.pred_score != -9999
),

quantile_bins AS (
    SELECT pred_score,
           NTILE(10) OVER (ORDER BY pred_score) AS bin_group
    FROM base_data_clean
),

bin_boundaries AS (
    SELECT DISTINCT 
           bin_group,
           MIN(pred_score) OVER (PARTITION BY bin_group) AS bin_min,
           MAX(pred_score) OVER (PARTITION BY bin_group) AS bin_max
    FROM quantile_bins
),

bin_definitions AS (
    SELECT bin_group,
           CASE 
               WHEN bin_group = 1 THEN 
                   (SELECT MIN(pred_score) FROM base_data_clean)
               ELSE 
                   LAG(bin_max) OVER (ORDER BY bin_group)
           END AS left_bound,
           bin_max AS right_bound,
           CONCAT('(', 
                  CASE 
                      WHEN bin_group = 1 THEN 
                          CAST((SELECT MIN(pred_score) FROM base_data_clean) AS SIGNED)
                      ELSE 
                          CAST(LAG(bin_max) OVER (ORDER BY bin_group) AS SIGNED)
                  END,
                  ',',
                  CAST(bin_max AS SIGNED),
                  ']') AS bin_label
    FROM bin_boundaries
),

recent_data AS (
    SELECT p.*
    FROM preprocessed_data p
    WHERE p.apply_date >= DATE_SUB(CURDATE(), INTERVAL 100 DAY)
      AND p.apply_date <= CURDATE()
),

binned_recent_data AS (
    SELECT r.apply_date,
           r.pred_score,
           CASE 
               WHEN r.pred_score = -9999 THEN '[-9999]'
               ELSE (
                   SELECT bd.bin_label
                   FROM bin_definitions bd
                   WHERE r.pred_score > bd.left_bound 
                     AND r.pred_score <= bd.right_bound
                   ORDER BY bd.bin_group
                   LIMIT 1
               )
           END AS risk_bin,
           CASE 
               WHEN r.pred_score = -9999 THEN 0
               ELSE (
                   SELECT bd.bin_group
                   FROM bin_definitions bd
                   WHERE r.pred_score > bd.left_bound 
                     AND r.pred_score <= bd.right_bound
                   ORDER BY bd.bin_group
                   LIMIT 1
               )
           END AS bin_order
    FROM recent_data r
),

daily_counts AS (
    SELECT apply_date,
           risk_bin,
           bin_order,
           COUNT(*) AS count_per_bin
    FROM binned_recent_data
    WHERE risk_bin IS NOT NULL
    GROUP BY apply_date, risk_bin, bin_order
),

daily_totals AS (
    SELECT apply_date,
           SUM(count_per_bin) AS total_per_day
    FROM daily_counts
    GROUP BY apply_date
),

final_result AS (
    SELECT dc.apply_date,
           dc.risk_bin,
           dc.count_per_bin,
           dt.total_per_day,
           ROUND(dc.count_per_bin * 100.0 / dt.total_per_day, 2) AS percentage,
           dc.bin_order
    FROM daily_counts dc
    JOIN daily_totals dt ON dc.apply_date = dt.apply_date
)

SELECT apply_date,
       risk_bin,
       percentage
FROM final_result
ORDER BY apply_date, bin_order;