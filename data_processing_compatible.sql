-- 数据预处理和风险分析 SQL 实现（兼容多种数据库）
-- 替代 Python pandas 数据处理逻辑

-- ============== MySQL 版本 ==============
-- 1. 数据预处理 - 提取日期和月份
WITH preprocessed_data AS (
    SELECT *,
           DATE(LEFT(risk_time, 10)) AS apply_date,
           DATE_FORMAT(DATE(LEFT(risk_time, 10)), '%Y-%m') AS apply_month
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

-- 3. 计算十分位数边界（MySQL 8.0+）
quantiles AS (
    SELECT 
        MIN(pred_score) AS min_score,
        MAX(pred_score) AS max_score,
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

-- 其余逻辑同上...

-- ============== PostgreSQL 版本 ==============
/*
WITH preprocessed_data AS (
    SELECT *,
           DATE(SUBSTRING(risk_time, 1, 10)) AS apply_date,
           TO_CHAR(DATE(SUBSTRING(risk_time, 1, 10)), 'YYYY-MM') AS apply_month
    FROM your_table_name
),

date_range AS (
    SELECT MIN(apply_date) AS earliest_date,
           MIN(apply_date) + INTERVAL '5 days' AS end_date_
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

quantiles AS (
    SELECT 
        MIN(pred_score) AS min_score,
        MAX(pred_score) AS max_score,
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

recent_data AS (
    SELECT p.*
    FROM preprocessed_data p
    WHERE p.apply_date >= CURRENT_DATE - INTERVAL '100 days'
      AND p.apply_date <= CURRENT_DATE
),
*/

-- ============== 兼容老版本MySQL的分位数计算 ==============
/*
-- 如果数据库不支持PERCENTILE_CONT，可以使用以下方法：
quantiles_manual AS (
    SELECT 
        MIN(pred_score) AS min_score,
        MAX(pred_score) AS max_score,
        (SELECT pred_score FROM (
            SELECT pred_score, ROW_NUMBER() OVER (ORDER BY pred_score) as rn,
                   COUNT(*) OVER() as total_count
            FROM base_data
        ) t WHERE rn = CEIL(0.1 * total_count)) AS q1,
        
        (SELECT pred_score FROM (
            SELECT pred_score, ROW_NUMBER() OVER (ORDER BY pred_score) as rn,
                   COUNT(*) OVER() as total_count
            FROM base_data
        ) t WHERE rn = CEIL(0.2 * total_count)) AS q2,
        
        -- 继续其他分位数...
        
    FROM base_data
),
*/

-- 完整的分箱和统计逻辑
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

daily_counts AS (
    SELECT apply_date,
           risk_bin,
           COUNT(*) AS count_per_bin
    FROM binned_data
    GROUP BY apply_date, risk_bin
),

daily_totals AS (
    SELECT apply_date,
           SUM(count_per_bin) AS total_per_day
    FROM daily_counts
    GROUP BY apply_date
),

daily_percentages AS (
    SELECT dc.apply_date,
           dc.risk_bin,
           dc.count_per_bin,
           dt.total_per_day,
           ROUND((dc.count_per_bin * 100.0 / dt.total_per_day), 2) AS percentage
    FROM daily_counts dc
    JOIN daily_totals dt ON dc.apply_date = dt.apply_date
)

-- 最终结果
SELECT apply_date,
       risk_bin,
       percentage
FROM daily_percentages
ORDER BY apply_date, risk_bin;

-- ============== 使用说明 ==============
/*
使用前需要：
1. 将 'your_table_name' 替换为实际的表名
2. 根据您的数据库类型选择相应的SQL版本
3. 确保 risk_time 字段格式为 'YYYY-MM-DD HH:MM:SS' 或类似格式
4. 确保 pred_score 字段为数值类型

主要功能对照：
- df['apply_date'] = df['risk_time'].apply(lambda x:str(x).split(' ')[0]) 
  → DATE(LEFT(risk_time, 10))
  
- pd.to_datetime() 
  → DATE()
  
- pd.Timedelta(days=5) 
  → DATE_ADD(date, INTERVAL 5 DAY)
  
- pd.qcut(base_data['pred_score'], q=10) 
  → PERCENTILE_CONT(0.1 到 0.9)
  
- pd.cut() 
  → CASE WHEN 语句
  
- groupby().size().unstack() 
  → GROUP BY + COUNT() + 透视逻辑
  
- div(daily_dist.sum(axis=1), axis=0) * 100 
  → (count_per_bin * 100.0 / total_per_day)
*/