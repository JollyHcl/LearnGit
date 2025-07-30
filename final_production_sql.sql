-- =====================================================
-- 生产环境SQL：完全替代Python数据处理脚本
-- 自动分箱，确保与Python结果一致
-- =====================================================

-- 使用说明：
-- 1. 将 'your_table_name' 替换为实际表名
-- 2. 确保字段名 risk_time 和 pred_score 正确
-- 3. 直接执行即可获得与Python一致的结果

WITH 
-- 步骤1: 数据预处理 - 提取日期
preprocessed_data AS (
    SELECT *,
           DATE(CASE 
               WHEN risk_time LIKE '%-%-%' THEN SUBSTRING(risk_time, 1, 10)
               ELSE risk_time
           END) AS apply_date
    FROM your_table_name  -- 替换为实际表名
),

-- 步骤2: 确定基准期间（最早日期开始的6天）
base_period AS (
    SELECT MIN(apply_date) AS earliest_date,
           DATE_ADD(MIN(apply_date), INTERVAL 5 DAY) AS end_date_base
    FROM preprocessed_data
),

-- 步骤3: 提取基准期数据，排除-9999异常值
base_data_clean AS (
    SELECT p.pred_score
    FROM preprocessed_data p
    CROSS JOIN base_period bp
    WHERE p.apply_date >= bp.earliest_date
      AND p.apply_date <= bp.end_date_base
      AND p.pred_score != -9999
),

-- 步骤4: 使用NTILE(10)自动计算十分位数分箱边界
quantile_bins AS (
    SELECT pred_score,
           NTILE(10) OVER (ORDER BY pred_score) AS bin_group
    FROM base_data_clean
),

-- 步骤5: 计算每个分箱的边界值
bin_boundaries AS (
    SELECT DISTINCT 
           bin_group,
           MIN(pred_score) OVER (PARTITION BY bin_group) AS bin_min,
           MAX(pred_score) OVER (PARTITION BY bin_group) AS bin_max
    FROM quantile_bins
),

-- 步骤6: 生成分箱定义，包括左边界调整
bin_definitions AS (
    SELECT bin_group,
           -- 左边界：第一个分箱使用最小值，其他使用前一个分箱的最大值
           CASE 
               WHEN bin_group = 1 THEN 
                   (SELECT MIN(pred_score) FROM base_data_clean)
               ELSE 
                   LAG(bin_max) OVER (ORDER BY bin_group)
           END AS left_bound,
           bin_max AS right_bound,
           -- 生成分箱标签：(left,right]
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

-- 步骤7: 筛选近100天数据
recent_data AS (
    SELECT p.*
    FROM preprocessed_data p
    WHERE p.apply_date >= DATE_SUB(CURDATE(), INTERVAL 100 DAY)
      AND p.apply_date <= CURDATE()
),

-- 步骤8: 对近期数据应用分箱规则
binned_recent_data AS (
    SELECT r.apply_date,
           r.pred_score,
           CASE 
               -- 特殊处理-9999异常值
               WHEN r.pred_score = -9999 THEN '[-9999]'
               -- 对正常值应用分箱
               ELSE (
                   SELECT bd.bin_label
                   FROM bin_definitions bd
                   WHERE r.pred_score > bd.left_bound 
                     AND r.pred_score <= bd.right_bound
                   ORDER BY bd.bin_group
                   LIMIT 1
               )
           END AS risk_bin,
           -- 添加分箱排序字段
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

-- 步骤9: 按日期和分箱统计计数
daily_counts AS (
    SELECT apply_date,
           risk_bin,
           bin_order,
           COUNT(*) AS count_per_bin
    FROM binned_recent_data
    WHERE risk_bin IS NOT NULL
    GROUP BY apply_date, risk_bin, bin_order
),

-- 步骤10: 计算每日总数
daily_totals AS (
    SELECT apply_date,
           SUM(count_per_bin) AS total_per_day
    FROM daily_counts
    GROUP BY apply_date
),

-- 步骤11: 计算最终百分比分布
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

-- 最终输出：与Python脚本完全一致的结果
SELECT apply_date,
       risk_bin,
       percentage
FROM final_result
ORDER BY apply_date, bin_order;

-- =====================================================
-- 可选：如需透视表格式输出（类似pandas unstack）
-- =====================================================
/*
WITH final_pivot AS (
    -- 在这里粘贴上面的完整CTE查询
    ... [上面的完整查询] ...
)

SELECT apply_date,
       MAX(CASE WHEN risk_bin = '[-9999]' THEN percentage END) AS bin_missing,
       MAX(CASE WHEN bin_order = 1 THEN percentage END) AS bin_1,
       MAX(CASE WHEN bin_order = 2 THEN percentage END) AS bin_2,
       MAX(CASE WHEN bin_order = 3 THEN percentage END) AS bin_3,
       MAX(CASE WHEN bin_order = 4 THEN percentage END) AS bin_4,
       MAX(CASE WHEN bin_order = 5 THEN percentage END) AS bin_5,
       MAX(CASE WHEN bin_order = 6 THEN percentage END) AS bin_6,
       MAX(CASE WHEN bin_order = 7 THEN percentage END) AS bin_7,
       MAX(CASE WHEN bin_order = 8 THEN percentage END) AS bin_8,
       MAX(CASE WHEN bin_order = 9 THEN percentage END) AS bin_9,
       MAX(CASE WHEN bin_order = 10 THEN percentage END) AS bin_10
FROM final_pivot
GROUP BY apply_date
ORDER BY apply_date;
*/

-- =====================================================
-- 调试查询：查看计算出的分箱边界
-- =====================================================
/*
WITH preprocessed_data AS (
    SELECT *, DATE(SUBSTRING(risk_time, 1, 10)) AS apply_date
    FROM your_table_name
),
base_period AS (
    SELECT MIN(apply_date) AS earliest_date,
           DATE_ADD(MIN(apply_date), INTERVAL 5 DAY) AS end_date_base
    FROM preprocessed_data
),
base_data_clean AS (
    SELECT p.pred_score FROM preprocessed_data p
    CROSS JOIN base_period bp
    WHERE p.apply_date >= bp.earliest_date AND p.apply_date <= bp.end_date_base AND p.pred_score != -9999
),
quantile_bins AS (
    SELECT pred_score, NTILE(10) OVER (ORDER BY pred_score) AS bin_group
    FROM base_data_clean
),
bin_boundaries AS (
    SELECT DISTINCT bin_group,
           MIN(pred_score) OVER (PARTITION BY bin_group) AS bin_min,
           MAX(pred_score) OVER (PARTITION BY bin_group) AS bin_max
    FROM quantile_bins
)

-- 查看分箱边界
SELECT bin_group,
       bin_min,
       bin_max,
       CASE 
           WHEN bin_group = 1 THEN (SELECT MIN(pred_score) FROM base_data_clean)
           ELSE LAG(bin_max) OVER (ORDER BY bin_group)
       END AS left_bound,
       bin_max AS right_bound,
       CONCAT('(', 
              CASE WHEN bin_group = 1 THEN CAST((SELECT MIN(pred_score) FROM base_data_clean) AS SIGNED)
                   ELSE CAST(LAG(bin_max) OVER (ORDER BY bin_group) AS SIGNED) END,
              ',', CAST(bin_max AS SIGNED), ']') AS bin_label
FROM bin_boundaries
ORDER BY bin_group;
*/

-- =====================================================
-- 性能优化建议
-- =====================================================
/*
-- 1. 创建索引以提升查询性能
CREATE INDEX idx_risk_time ON your_table_name(risk_time);
CREATE INDEX idx_pred_score ON your_table_name(pred_score);
CREATE INDEX idx_apply_date_score ON your_table_name(
    (DATE(SUBSTRING(risk_time, 1, 10))), pred_score
);

-- 2. 如果数据量很大，可以添加LIMIT进行采样验证
-- 在base_data_clean的最后添加：LIMIT 10000

-- 3. 对于PostgreSQL，将DATE_SUB改为：
-- WHERE p.apply_date >= CURRENT_DATE - INTERVAL '100 days'

-- 4. 对于SQL Server，将DATE_SUB改为：
-- WHERE p.apply_date >= DATEADD(day, -100, GETDATE())
*/