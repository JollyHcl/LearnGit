-- 数据预处理和风险分析 SQL 实现
-- 替代 Python pandas 数据处理逻辑

-- 1. 数据预处理 - 提取日期和月份
WITH preprocessed_data AS (
    SELECT *,
           DATE(SUBSTRING(risk_time, 1, 10)) AS apply_date,
           DATE_FORMAT(DATE(SUBSTRING(risk_time, 1, 10)), '%Y-%m') AS apply_month
    FROM your_table_name  -- 请替换为实际表名
),

-- 2. 获取最早日期和基础数据（前6天，排除-9999异常值）
date_range AS (
    SELECT MIN(apply_date) AS earliest_date,
           DATE_ADD(MIN(apply_date), INTERVAL 5 DAY) AS end_date_
    FROM preprocessed_data
),

base_data AS (
    SELECT p.*
    FROM preprocessed_data p
    CROSS JOIN date_range d
    WHERE p.apply_date >= d.earliest_date
      AND p.apply_date <= d.end_date_
      AND p.pred_score != -9999
),

-- 3. 计算十分位数边界（基于基础数据）
quantiles AS (
    SELECT 
        MIN(pred_score) AS min_score,
        MAX(pred_score) AS max_score,
        -- 计算十分位数
        PERCENTILE_CONT(0.1) WITHIN GROUP (ORDER BY pred_score) AS q1,
        PERCENTILE_CONT(0.2) WITHIN GROUP (ORDER BY pred_score) AS q2,
        PERCENTILE_CONT(0.3) WITHIN GROUP (ORDER BY pred_score) AS q3,
        PERCENTILE_CONT(0.4) WITHIN GROUP (ORDER BY pred_score) AS q4,
        PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY pred_score) AS q5,
        PERCENTILE_CONT(0.6) WITHIN GROUP (ORDER BY pred_score) AS q6,
        PERCENTILE_CONT(0.7) WITHIN GROUP (ORDER BY pred_score) AS q7,
        PERCENTILE_CONT(0.8) WITHIN GROUP (ORDER BY pred_score) AS q8,
        PERCENTILE_CONT(0.9) WITHIN GROUP (ORDER BY pred_score) AS q9
    FROM base_data
),

-- 4. 筛选近100天数据
recent_data AS (
    SELECT p.*
    FROM preprocessed_data p
    WHERE p.apply_date >= DATE_SUB(CURDATE(), INTERVAL 100 DAY)
      AND p.apply_date <= CURDATE()
),

-- 5. 应用分箱逻辑（包含-9999特殊分箱）
binned_data AS (
    SELECT r.*,
           CASE 
               WHEN r.pred_score = -9999 THEN '[-9999]'
               WHEN r.pred_score <= q.q1 THEN CONCAT('(', FLOOR(q.min_score), ',', FLOOR(q.q1), ']')
               WHEN r.pred_score <= q.q2 THEN CONCAT('(', FLOOR(q.q1), ',', FLOOR(q.q2), ']')
               WHEN r.pred_score <= q.q3 THEN CONCAT('(', FLOOR(q.q2), ',', FLOOR(q.q3), ']')
               WHEN r.pred_score <= q.q4 THEN CONCAT('(', FLOOR(q.q3), ',', FLOOR(q.q4), ']')
               WHEN r.pred_score <= q.q5 THEN CONCAT('(', FLOOR(q.q4), ',', FLOOR(q.q5), ']')
               WHEN r.pred_score <= q.q6 THEN CONCAT('(', FLOOR(q.q5), ',', FLOOR(q.q6), ']')
               WHEN r.pred_score <= q.q7 THEN CONCAT('(', FLOOR(q.q6), ',', FLOOR(q.q7), ']')
               WHEN r.pred_score <= q.q8 THEN CONCAT('(', FLOOR(q.q7), ',', FLOOR(q.q8), ']')
               WHEN r.pred_score <= q.q9 THEN CONCAT('(', FLOOR(q.q8), ',', FLOOR(q.q9), ']')
               ELSE CONCAT('(', FLOOR(q.q9), ',', FLOOR(q.max_score), ']')
           END AS risk_bin
    FROM recent_data r
    CROSS JOIN quantiles q
),

-- 6. 按日期和分箱统计计数
daily_counts AS (
    SELECT apply_date,
           risk_bin,
           COUNT(*) AS count_per_bin
    FROM binned_data
    GROUP BY apply_date, risk_bin
),

-- 7. 计算每日总数
daily_totals AS (
    SELECT apply_date,
           SUM(count_per_bin) AS total_per_day
    FROM daily_counts
    GROUP BY apply_date
),

-- 8. 计算百分比分布
daily_percentages AS (
    SELECT dc.apply_date,
           dc.risk_bin,
           dc.count_per_bin,
           dt.total_per_day,
           ROUND((dc.count_per_bin * 100.0 / dt.total_per_day), 2) AS percentage
    FROM daily_counts dc
    JOIN daily_totals dt ON dc.apply_date = dt.apply_date
)

-- 最终结果：按日期和风险分箱的百分比分布
SELECT apply_date,
       risk_bin,
       percentage
FROM daily_percentages
ORDER BY apply_date, risk_bin;

-- 可选：如果需要透视表格式（类似pandas的unstack）
-- 请根据实际的分箱数量调整列名
/*
SELECT apply_date,
       MAX(CASE WHEN risk_bin = '[-9999]' THEN percentage END) AS bin_negative_9999,
       MAX(CASE WHEN risk_bin LIKE '%(0,%' THEN percentage END) AS bin_1,
       MAX(CASE WHEN risk_bin LIKE '%(10,%' THEN percentage END) AS bin_2,
       -- 继续添加其他分箱列...
FROM daily_percentages
GROUP BY apply_date
ORDER BY apply_date;
*/