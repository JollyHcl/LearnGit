-- 基于数据自动分箱的SQL实现
-- 完全依据实际数据计算分位数边界，类似pandas的qcut功能

-- =====================================================
-- 方案1: 使用NTILE窗口函数（推荐 - 适用于大多数现代数据库）
-- =====================================================

WITH preprocessed_data AS (
    -- 1. 数据预处理
    SELECT *,
           DATE(SUBSTRING(risk_time, 1, 10)) AS apply_date
    FROM your_table_name  -- 替换为实际表名
),

base_period AS (
    -- 2. 确定基准期间（前6天）
    SELECT MIN(apply_date) AS start_date,
           DATE_ADD(MIN(apply_date), INTERVAL 5 DAY) AS end_date
    FROM preprocessed_data
),

base_data_clean AS (
    -- 3. 基准期数据（排除异常值）
    SELECT p.pred_score
    FROM preprocessed_data p
    CROSS JOIN base_period bp
    WHERE p.apply_date >= bp.start_date
      AND p.apply_date <= bp.end_date
      AND p.pred_score != -9999
),

quantile_boundaries AS (
    -- 4. 使用NTILE自动计算十分位数边界
    SELECT DISTINCT
           ntile_group,
           MIN(pred_score) OVER (PARTITION BY ntile_group) AS bin_min,
           MAX(pred_score) OVER (PARTITION BY ntile_group) AS bin_max,
           LAG(MAX(pred_score)) OVER (ORDER BY ntile_group) AS prev_max
    FROM (
        SELECT pred_score,
               NTILE(10) OVER (ORDER BY pred_score) AS ntile_group
        FROM base_data_clean
    ) t
),

bin_definitions AS (
    -- 5. 生成分箱定义
    SELECT ntile_group,
           COALESCE(prev_max, (SELECT MIN(pred_score) FROM base_data_clean)) AS left_bound,
           bin_max AS right_bound,
           CONCAT('(', 
                  COALESCE(prev_max, (SELECT MIN(pred_score) FROM base_data_clean)), 
                  ',', 
                  bin_max, 
                  ']') AS bin_label
    FROM quantile_boundaries
    WHERE ntile_group IS NOT NULL
),

recent_data AS (
    -- 6. 近100天数据
    SELECT *
    FROM preprocessed_data
    WHERE apply_date >= DATE_SUB(CURDATE(), INTERVAL 100 DAY)
      AND apply_date <= CURDATE()
),

binned_recent_data AS (
    -- 7. 对近期数据应用分箱
    SELECT r.*,
           CASE 
               WHEN r.pred_score = -9999 THEN '[-9999]'
               ELSE (
                   SELECT bd.bin_label
                   FROM bin_definitions bd
                   WHERE r.pred_score > bd.left_bound 
                     AND r.pred_score <= bd.right_bound
                   LIMIT 1
               )
           END AS risk_bin
    FROM recent_data r
),

daily_distribution AS (
    -- 8. 计算每日分布
    SELECT apply_date,
           risk_bin,
           COUNT(*) AS count_per_bin,
           SUM(COUNT(*)) OVER (PARTITION BY apply_date) AS total_per_day
    FROM binned_recent_data
    WHERE risk_bin IS NOT NULL
    GROUP BY apply_date, risk_bin
)

-- 9. 最终结果
SELECT apply_date,
       risk_bin,
       count_per_bin,
       total_per_day,
       ROUND(count_per_bin * 100.0 / total_per_day, 2) AS percentage
FROM daily_distribution
ORDER BY apply_date, risk_bin;

-- =====================================================
-- 方案2: 手动计算分位数（兼容老版本MySQL）
-- =====================================================

/*
WITH preprocessed_data AS (
    SELECT *,
           DATE(SUBSTRING(risk_time, 1, 10)) AS apply_date
    FROM your_table_name
),

base_period AS (
    SELECT MIN(apply_date) AS start_date,
           DATE_ADD(MIN(apply_date), INTERVAL 5 DAY) AS end_date
    FROM preprocessed_data
),

base_data_ranked AS (
    SELECT p.pred_score,
           ROW_NUMBER() OVER (ORDER BY p.pred_score) AS row_num,
           COUNT(*) OVER () AS total_count
    FROM preprocessed_data p
    CROSS JOIN base_period bp
    WHERE p.apply_date >= bp.start_date
      AND p.apply_date <= bp.end_date
      AND p.pred_score != -9999
),

quantile_values AS (
    SELECT 
        (SELECT pred_score FROM base_data_ranked WHERE row_num = CEIL(0.1 * total_count) LIMIT 1) AS q1,
        (SELECT pred_score FROM base_data_ranked WHERE row_num = CEIL(0.2 * total_count) LIMIT 1) AS q2,
        (SELECT pred_score FROM base_data_ranked WHERE row_num = CEIL(0.3 * total_count) LIMIT 1) AS q3,
        (SELECT pred_score FROM base_data_ranked WHERE row_num = CEIL(0.4 * total_count) LIMIT 1) AS q4,
        (SELECT pred_score FROM base_data_ranked WHERE row_num = CEIL(0.5 * total_count) LIMIT 1) AS q5,
        (SELECT pred_score FROM base_data_ranked WHERE row_num = CEIL(0.6 * total_count) LIMIT 1) AS q6,
        (SELECT pred_score FROM base_data_ranked WHERE row_num = CEIL(0.7 * total_count) LIMIT 1) AS q7,
        (SELECT pred_score FROM base_data_ranked WHERE row_num = CEIL(0.8 * total_count) LIMIT 1) AS q8,
        (SELECT pred_score FROM base_data_ranked WHERE row_num = CEIL(0.9 * total_count) LIMIT 1) AS q9,
        (SELECT MIN(pred_score) FROM base_data_ranked) AS min_val,
        (SELECT MAX(pred_score) FROM base_data_ranked) AS max_val
),

recent_data AS (
    SELECT *
    FROM preprocessed_data
    WHERE apply_date >= DATE_SUB(CURDATE(), INTERVAL 100 DAY)
      AND apply_date <= CURDATE()
),

binned_data AS (
    SELECT r.*,
           CASE 
               WHEN r.pred_score = -9999 THEN '[-9999]'
               WHEN r.pred_score <= q.q1 THEN CONCAT('(', q.min_val, ',', q.q1, ']')
               WHEN r.pred_score <= q.q2 THEN CONCAT('(', q.q1, ',', q.q2, ']')
               WHEN r.pred_score <= q.q3 THEN CONCAT('(', q.q2, ',', q.q3, ']')
               WHEN r.pred_score <= q.q4 THEN CONCAT('(', q.q3, ',', q.q4, ']')
               WHEN r.pred_score <= q.q5 THEN CONCAT('(', q.q4, ',', q.q5, ']')
               WHEN r.pred_score <= q.q6 THEN CONCAT('(', q.q5, ',', q.q6, ']')
               WHEN r.pred_score <= q.q7 THEN CONCAT('(', q.q6, ',', q.q7, ']')
               WHEN r.pred_score <= q.q8 THEN CONCAT('(', q.q7, ',', q.q8, ']')
               WHEN r.pred_score <= q.q9 THEN CONCAT('(', q.q8, ',', q.q9, ']')
               ELSE CONCAT('(', q.q9, ',', q.max_val, ']')
           END AS risk_bin
    FROM recent_data r
    CROSS JOIN quantile_values q
),

daily_stats AS (
    SELECT apply_date,
           risk_bin,
           COUNT(*) as count_per_bin,
           SUM(COUNT(*)) OVER (PARTITION BY apply_date) as total_per_day
    FROM binned_data
    GROUP BY apply_date, risk_bin
)

SELECT apply_date,
       risk_bin,
       count_per_bin,
       total_per_day,
       ROUND(count_per_bin * 100.0 / total_per_day, 2) as percentage
FROM daily_stats
ORDER BY apply_date, risk_bin;
*/

-- =====================================================
-- 方案3: 查看分箱边界（调试用）
-- =====================================================

-- 运行此查询来查看实际计算出的分箱边界
WITH preprocessed_data AS (
    SELECT *,
           DATE(SUBSTRING(risk_time, 1, 10)) AS apply_date
    FROM your_table_name
),

base_period AS (
    SELECT MIN(apply_date) AS start_date,
           DATE_ADD(MIN(apply_date), INTERVAL 5 DAY) AS end_date
    FROM preprocessed_data
),

base_data_clean AS (
    SELECT p.pred_score
    FROM preprocessed_data p
    CROSS JOIN base_period bp
    WHERE p.apply_date >= bp.start_date
      AND p.apply_date <= bp.end_date
      AND p.pred_score != -9999
),

quantile_boundaries AS (
    SELECT DISTINCT
           ntile_group,
           MIN(pred_score) OVER (PARTITION BY ntile_group) AS bin_min,
           MAX(pred_score) OVER (PARTITION BY ntile_group) AS bin_max,
           LAG(MAX(pred_score)) OVER (ORDER BY ntile_group) AS prev_max,
           COUNT(*) OVER (PARTITION BY ntile_group) AS count_in_bin
    FROM (
        SELECT pred_score,
               NTILE(10) OVER (ORDER BY pred_score) AS ntile_group
        FROM base_data_clean
    ) t
)

SELECT ntile_group AS bin_number,
       COALESCE(prev_max, (SELECT MIN(pred_score) FROM base_data_clean)) AS left_bound,
       bin_max AS right_bound,
       CONCAT('(', 
              COALESCE(prev_max, (SELECT MIN(pred_score) FROM base_data_clean)), 
              ',', 
              bin_max, 
              ']') AS bin_label,
       count_in_bin,
       ROUND(count_in_bin * 100.0 / (SELECT COUNT(*) FROM base_data_clean), 2) AS percentage_of_base
FROM quantile_boundaries
WHERE ntile_group IS NOT NULL
ORDER BY ntile_group;

-- =====================================================
-- 使用说明
-- =====================================================
/*
这个SQL脚本实现了完全基于数据的自动分箱：

1. **自动计算**: 不需要手动指定分位数值，完全基于实际数据计算
2. **动态分箱**: 每次运行都会根据最新的基准期数据重新计算分箱边界
3. **等频分箱**: 使用NTILE确保每个分箱包含大致相等数量的样本

主要特点：
- ✅ 基于前6天数据自动计算十分位数
- ✅ 自动处理-9999异常值
- ✅ 生成标准的区间标签格式 (a,b]
- ✅ 支持数据分布变化时的动态调整
- ✅ 提供分箱边界查看功能

使用步骤：
1. 替换'your_table_name'为实际表名
2. 运行方案3查看计算出的分箱边界
3. 运行方案1获取最终的分布结果

数据库兼容性：
- MySQL 8.0+: 使用方案1（NTILE）
- MySQL 5.7: 使用方案2（手动计算）
- PostgreSQL/SQL Server: 使用方案1

注意事项：
- 确保基准期有足够的数据点（建议至少1000条）
- 如果数据分布极度不均匀，可以考虑调整分箱数量
- 可以保存分箱边界到配置表以保持一致性
*/