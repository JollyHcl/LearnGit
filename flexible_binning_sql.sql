-- 灵活的数据驱动分箱SQL实现
-- 支持多种分箱策略：等频、等宽、自定义分位数

-- =====================================================
-- 配置参数（可根据需要调整）
-- =====================================================
-- 在实际使用时，可以将这些参数设置为变量或存储在配置表中

-- SET @bin_count = 10;                    -- 分箱数量
-- SET @binning_method = 'equal_frequency'; -- 分箱方法：'equal_frequency', 'equal_width', 'custom_percentiles'
-- SET @base_days = 6;                     -- 基准期天数
-- SET @analysis_days = 100;               -- 分析期天数

-- =====================================================
-- 方案A: 等频分箱（Equal Frequency Binning）
-- =====================================================

WITH config AS (
    -- 配置参数
    SELECT 10 AS bin_count,
           6 AS base_days,
           100 AS analysis_days
),

preprocessed_data AS (
    SELECT *,
           DATE(SUBSTRING(risk_time, 1, 10)) AS apply_date
    FROM your_table_name  -- 替换为实际表名
),

base_period AS (
    SELECT MIN(apply_date) AS start_date,
           DATE_ADD(MIN(apply_date), INTERVAL (SELECT base_days - 1 FROM config) DAY) AS end_date
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

equal_frequency_bins AS (
    SELECT DISTINCT
           ntile_group,
           MIN(pred_score) OVER (PARTITION BY ntile_group) AS bin_min,
           MAX(pred_score) OVER (PARTITION BY ntile_group) AS bin_max,
           LAG(MAX(pred_score)) OVER (ORDER BY ntile_group) AS prev_max,
           COUNT(*) OVER (PARTITION BY ntile_group) AS samples_in_bin
    FROM (
        SELECT pred_score,
               NTILE((SELECT bin_count FROM config)) OVER (ORDER BY pred_score) AS ntile_group
        FROM base_data_clean
    ) t
    WHERE ntile_group IS NOT NULL
),

bin_definitions_eq_freq AS (
    SELECT ntile_group AS bin_id,
           'equal_frequency' AS method,
           COALESCE(prev_max, (SELECT MIN(pred_score) FROM base_data_clean)) AS left_bound,
           bin_max AS right_bound,
           CONCAT('EQ_FREQ_', ntile_group, ':(', 
                  ROUND(COALESCE(prev_max, (SELECT MIN(pred_score) FROM base_data_clean)), 2), 
                  ',', 
                  ROUND(bin_max, 2), 
                  ']') AS bin_label,
           samples_in_bin
    FROM equal_frequency_bins
),

-- =====================================================
-- 方案B: 等宽分箱（Equal Width Binning）
-- =====================================================

data_range AS (
    SELECT MIN(pred_score) AS min_score,
           MAX(pred_score) AS max_score,
           (MAX(pred_score) - MIN(pred_score)) / (SELECT bin_count FROM config) AS bin_width
    FROM base_data_clean
),

equal_width_bins AS (
    SELECT bin_id,
           'equal_width' AS method,
           dr.min_score + (bin_id - 1) * dr.bin_width AS left_bound,
           dr.min_score + bin_id * dr.bin_width AS right_bound,
           CONCAT('EQ_WIDTH_', bin_id, ':(', 
                  ROUND(dr.min_score + (bin_id - 1) * dr.bin_width, 2), 
                  ',', 
                  ROUND(dr.min_score + bin_id * dr.bin_width, 2), 
                  ']') AS bin_label
    FROM (
        SELECT 1 AS bin_id UNION ALL SELECT 2 UNION ALL SELECT 3 UNION ALL SELECT 4 UNION ALL SELECT 5
        UNION ALL SELECT 6 UNION ALL SELECT 7 UNION ALL SELECT 8 UNION ALL SELECT 9 UNION ALL SELECT 10
        -- 可以根据需要扩展更多分箱
    ) bins
    CROSS JOIN data_range dr
    CROSS JOIN config c
    WHERE bin_id <= c.bin_count
),

-- =====================================================
-- 方案C: 自定义分位数分箱
-- =====================================================

custom_percentiles AS (
    -- 可以自定义分位数，例如：5%, 10%, 25%, 50%, 75%, 90%, 95%, 99%
    SELECT percentile, 
           ROW_NUMBER() OVER (ORDER BY percentile) AS bin_id
    FROM (
        SELECT 0.05 AS percentile UNION ALL
        SELECT 0.10 UNION ALL
        SELECT 0.25 UNION ALL
        SELECT 0.50 UNION ALL
        SELECT 0.75 UNION ALL
        SELECT 0.90 UNION ALL
        SELECT 0.95 UNION ALL
        SELECT 0.99
    ) p
),

custom_quantile_values AS (
    SELECT cp.bin_id,
           cp.percentile,
           (SELECT pred_score 
            FROM (SELECT pred_score, 
                         ROW_NUMBER() OVER (ORDER BY pred_score) AS rn,
                         COUNT(*) OVER () AS total
                  FROM base_data_clean) ranked
            WHERE rn = CEIL(cp.percentile * total)
            LIMIT 1) AS quantile_value
    FROM custom_percentiles cp
),

custom_bins AS (
    SELECT bin_id,
           'custom_percentiles' AS method,
           LAG(quantile_value, 1, (SELECT MIN(pred_score) FROM base_data_clean)) 
               OVER (ORDER BY bin_id) AS left_bound,
           quantile_value AS right_bound,
           CONCAT('CUSTOM_', ROUND(percentile * 100, 0), '%:(', 
                  ROUND(LAG(quantile_value, 1, (SELECT MIN(pred_score) FROM base_data_clean)) 
                        OVER (ORDER BY bin_id), 2),
                  ',', 
                  ROUND(quantile_value, 2), 
                  ']') AS bin_label
    FROM custom_quantile_values
),

-- =====================================================
-- 选择分箱方法并应用到近期数据
-- =====================================================

chosen_bins AS (
    -- 在这里选择使用哪种分箱方法
    -- 方法1: 等频分箱
    SELECT bin_id, method, left_bound, right_bound, bin_label, samples_in_bin
    FROM bin_definitions_eq_freq
    
    -- 方法2: 等宽分箱（注释掉上面的，取消注释下面的）
    /*
    SELECT bin_id, method, left_bound, right_bound, bin_label, 
           NULL AS samples_in_bin
    FROM equal_width_bins
    */
    
    -- 方法3: 自定义分位数（注释掉上面的，取消注释下面的）
    /*
    SELECT bin_id, method, left_bound, right_bound, bin_label,
           NULL AS samples_in_bin
    FROM custom_bins
    */
),

recent_data AS (
    SELECT *
    FROM preprocessed_data
    WHERE apply_date >= DATE_SUB(CURDATE(), INTERVAL (SELECT analysis_days FROM config) DAY)
      AND apply_date <= CURDATE()
),

binned_recent_data AS (
    SELECT r.*,
           CASE 
               WHEN r.pred_score = -9999 THEN '[-9999]'
               ELSE (
                   SELECT cb.bin_label
                   FROM chosen_bins cb
                   WHERE r.pred_score > cb.left_bound 
                     AND r.pred_score <= cb.right_bound
                   ORDER BY cb.bin_id
                   LIMIT 1
               )
           END AS risk_bin,
           -- 同时记录分箱ID用于排序
           CASE 
               WHEN r.pred_score = -9999 THEN 0
               ELSE (
                   SELECT cb.bin_id
                   FROM chosen_bins cb
                   WHERE r.pred_score > cb.left_bound 
                     AND r.pred_score <= cb.right_bound
                   ORDER BY cb.bin_id
                   LIMIT 1
               )
           END AS bin_order
    FROM recent_data r
),

daily_distribution AS (
    SELECT apply_date,
           risk_bin,
           bin_order,
           COUNT(*) AS count_per_bin,
           SUM(COUNT(*)) OVER (PARTITION BY apply_date) AS total_per_day
    FROM binned_recent_data
    WHERE risk_bin IS NOT NULL
    GROUP BY apply_date, risk_bin, bin_order
)

-- 最终结果
SELECT apply_date,
       risk_bin,
       count_per_bin,
       total_per_day,
       ROUND(count_per_bin * 100.0 / total_per_day, 2) AS percentage
FROM daily_distribution
ORDER BY apply_date, bin_order;

-- =====================================================
-- 辅助查询：查看分箱定义和统计
-- =====================================================

-- 查询1: 查看当前选择的分箱边界
/*
WITH config AS (SELECT 10 AS bin_count, 6 AS base_days),
preprocessed_data AS (
    SELECT *, DATE(SUBSTRING(risk_time, 1, 10)) AS apply_date
    FROM your_table_name
),
base_period AS (
    SELECT MIN(apply_date) AS start_date,
           DATE_ADD(MIN(apply_date), INTERVAL (SELECT base_days - 1 FROM config) DAY) AS end_date
    FROM preprocessed_data
),
base_data_clean AS (
    SELECT p.pred_score FROM preprocessed_data p
    CROSS JOIN base_period bp
    WHERE p.apply_date >= bp.start_date AND p.apply_date <= bp.end_date AND p.pred_score != -9999
),
-- ... (重复上面的分箱逻辑)

SELECT bin_id,
       method,
       left_bound,
       right_bound,
       bin_label,
       samples_in_bin,
       ROUND(samples_in_bin * 100.0 / (SELECT COUNT(*) FROM base_data_clean), 2) AS percentage_of_base
FROM chosen_bins
ORDER BY bin_id;
*/

-- 查询2: 比较不同分箱方法的效果
/*
SELECT 'Equal Frequency' AS method, 
       COUNT(DISTINCT bin_id) AS num_bins,
       MIN(samples_in_bin) AS min_samples,
       MAX(samples_in_bin) AS max_samples,
       AVG(samples_in_bin) AS avg_samples
FROM bin_definitions_eq_freq

UNION ALL

SELECT 'Equal Width' AS method,
       COUNT(*) AS num_bins,
       NULL, NULL, NULL
FROM equal_width_bins

UNION ALL

SELECT 'Custom Percentiles' AS method,
       COUNT(*) AS num_bins,
       NULL, NULL, NULL
FROM custom_bins;
*/

-- =====================================================
-- 使用说明
-- =====================================================
/*
这个灵活的分箱SQL提供了三种分箱策略：

1. **等频分箱 (Equal Frequency)**:
   - 每个分箱包含大致相同数量的样本
   - 适用于数据分布不均匀的情况
   - 分箱边界自动调整以平衡样本数量

2. **等宽分箱 (Equal Width)**:
   - 每个分箱的数值范围相等
   - 适用于数值均匀分布的数据
   - 分箱边界固定，便于解释

3. **自定义分位数分箱**:
   - 基于特定的分位数点进行分箱
   - 适用于需要关注特定分位数的业务场景
   - 可以自定义关键的分位数点

使用方法：
1. 替换 'your_table_name' 为实际表名
2. 在 chosen_bins CTE 中选择要使用的分箱方法
3. 根据需要调整配置参数（bin_count, base_days, analysis_days）
4. 运行查询获取结果

优势：
- ✅ 完全基于数据自动计算分箱边界
- ✅ 支持多种分箱策略
- ✅ 灵活的配置参数
- ✅ 清晰的分箱标签命名
- ✅ 包含分箱质量统计信息

性能优化：
- 建议在 pred_score 和 apply_date 字段上创建索引
- 对于大数据集，可以考虑采样计算分箱边界
- 可以将计算好的分箱边界保存到配置表中重复使用
*/