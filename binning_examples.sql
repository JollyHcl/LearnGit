-- 数据驱动分箱的实用示例
-- 包含完整的使用流程和不同场景的选择建议

-- =====================================================
-- 示例1: 快速开始 - 基本等频分箱
-- =====================================================

-- 第一步：查看数据基本情况
SELECT 
    MIN(DATE(SUBSTRING(risk_time, 1, 10))) AS earliest_date,
    MAX(DATE(SUBSTRING(risk_time, 1, 10))) AS latest_date,
    COUNT(*) AS total_records,
    COUNT(CASE WHEN pred_score != -9999 THEN 1 END) AS valid_scores,
    COUNT(CASE WHEN pred_score = -9999 THEN 1 END) AS missing_scores,
    MIN(CASE WHEN pred_score != -9999 THEN pred_score END) AS min_score,
    MAX(CASE WHEN pred_score != -9999 THEN pred_score END) AS max_score,
    AVG(CASE WHEN pred_score != -9999 THEN pred_score END) AS avg_score
FROM your_table_name;

-- 第二步：查看基准期（前6天）的数据分布
WITH base_data AS (
    SELECT pred_score,
           DATE(SUBSTRING(risk_time, 1, 10)) AS apply_date
    FROM your_table_name
    WHERE DATE(SUBSTRING(risk_time, 1, 10)) >= (
        SELECT MIN(DATE(SUBSTRING(risk_time, 1, 10))) 
        FROM your_table_name
    )
    AND DATE(SUBSTRING(risk_time, 1, 10)) <= (
        SELECT DATE_ADD(MIN(DATE(SUBSTRING(risk_time, 1, 10))), INTERVAL 5 DAY)
        FROM your_table_name
    )
    AND pred_score != -9999
)
SELECT 
    COUNT(*) AS base_period_records,
    MIN(pred_score) AS min_score,
    MAX(pred_score) AS max_score,
    ROUND(AVG(pred_score), 2) AS avg_score,
    ROUND(STDDEV(pred_score), 2) AS std_score
FROM base_data;

-- 第三步：计算等频分箱边界
WITH base_data AS (
    SELECT pred_score
    FROM your_table_name
    WHERE DATE(SUBSTRING(risk_time, 1, 10)) >= (
        SELECT MIN(DATE(SUBSTRING(risk_time, 1, 10))) 
        FROM your_table_name
    )
    AND DATE(SUBSTRING(risk_time, 1, 10)) <= (
        SELECT DATE_ADD(MIN(DATE(SUBSTRING(risk_time, 1, 10))), INTERVAL 5 DAY)
        FROM your_table_name
    )
    AND pred_score != -9999
),
quantile_bins AS (
    SELECT DISTINCT
           ntile_group,
           MIN(pred_score) OVER (PARTITION BY ntile_group) AS bin_min,
           MAX(pred_score) OVER (PARTITION BY ntile_group) AS bin_max,
           LAG(MAX(pred_score)) OVER (ORDER BY ntile_group) AS prev_max,
           COUNT(*) OVER (PARTITION BY ntile_group) AS count_in_bin
    FROM (
        SELECT pred_score,
               NTILE(10) OVER (ORDER BY pred_score) AS ntile_group
        FROM base_data
    ) t
)
SELECT 
    ntile_group AS bin_id,
    COALESCE(prev_max, (SELECT MIN(pred_score) FROM base_data)) AS left_bound,
    bin_max AS right_bound,
    CONCAT('Bin_', ntile_group, ':(', 
           ROUND(COALESCE(prev_max, (SELECT MIN(pred_score) FROM base_data)), 2), 
           ',', 
           ROUND(bin_max, 2), 
           ']') AS bin_label,
    count_in_bin,
    ROUND(count_in_bin * 100.0 / (SELECT COUNT(*) FROM base_data), 2) AS percentage
FROM quantile_bins
ORDER BY ntile_group;

-- =====================================================
-- 示例2: 完整的数据分析流程
-- =====================================================

WITH 
-- 配置参数
config AS (
    SELECT 10 AS bin_count,
           6 AS base_days,
           100 AS analysis_days
),

-- 数据预处理
preprocessed_data AS (
    SELECT *,
           DATE(SUBSTRING(risk_time, 1, 10)) AS apply_date
    FROM your_table_name
),

-- 基准期定义
base_period AS (
    SELECT MIN(apply_date) AS start_date,
           DATE_ADD(MIN(apply_date), INTERVAL (SELECT base_days - 1 FROM config) DAY) AS end_date
    FROM preprocessed_data
),

-- 基准期数据（排除异常值）
base_data_clean AS (
    SELECT p.pred_score
    FROM preprocessed_data p
    CROSS JOIN base_period bp
    WHERE p.apply_date >= bp.start_date
      AND p.apply_date <= bp.end_date
      AND p.pred_score != -9999
),

-- 等频分箱计算
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

-- 分箱定义
bin_definitions AS (
    SELECT ntile_group AS bin_id,
           COALESCE(prev_max, (SELECT MIN(pred_score) FROM base_data_clean)) AS left_bound,
           bin_max AS right_bound,
           CONCAT('Bin_', ntile_group, ':(', 
                  ROUND(COALESCE(prev_max, (SELECT MIN(pred_score) FROM base_data_clean)), 2), 
                  ',', 
                  ROUND(bin_max, 2), 
                  ']') AS bin_label,
           samples_in_bin
    FROM equal_frequency_bins
),

-- 近期数据
recent_data AS (
    SELECT *
    FROM preprocessed_data
    WHERE apply_date >= DATE_SUB(CURDATE(), INTERVAL (SELECT analysis_days FROM config) DAY)
      AND apply_date <= CURDATE()
),

-- 应用分箱
binned_recent_data AS (
    SELECT r.*,
           CASE 
               WHEN r.pred_score = -9999 THEN '[-9999]'
               ELSE (
                   SELECT bd.bin_label
                   FROM bin_definitions bd
                   WHERE r.pred_score > bd.left_bound 
                     AND r.pred_score <= bd.right_bound
                   ORDER BY bd.bin_id
                   LIMIT 1
               )
           END AS risk_bin,
           CASE 
               WHEN r.pred_score = -9999 THEN 0
               ELSE (
                   SELECT bd.bin_id
                   FROM bin_definitions bd
                   WHERE r.pred_score > bd.left_bound 
                     AND r.pred_score <= bd.right_bound
                   ORDER BY bd.bin_id
                   LIMIT 1
               )
           END AS bin_order
    FROM recent_data r
),

-- 每日分布统计
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
-- 示例3: 不同分箱方法的对比分析
-- =====================================================

-- 比较等频分箱 vs 等宽分箱的效果
WITH base_data AS (
    SELECT pred_score
    FROM your_table_name
    WHERE DATE(SUBSTRING(risk_time, 1, 10)) >= (
        SELECT MIN(DATE(SUBSTRING(risk_time, 1, 10))) FROM your_table_name
    )
    AND DATE(SUBSTRING(risk_time, 1, 10)) <= (
        SELECT DATE_ADD(MIN(DATE(SUBSTRING(risk_time, 1, 10))), INTERVAL 5 DAY) FROM your_table_name
    )
    AND pred_score != -9999
),

-- 等频分箱统计
equal_freq_stats AS (
    SELECT 'Equal Frequency' AS method,
           ntile_group AS bin_id,
           COUNT(*) AS count_in_bin,
           MIN(pred_score) AS min_score,
           MAX(pred_score) AS max_score,
           ROUND(AVG(pred_score), 2) AS avg_score
    FROM (
        SELECT pred_score,
               NTILE(10) OVER (ORDER BY pred_score) AS ntile_group
        FROM base_data
    ) t
    GROUP BY ntile_group
),

-- 等宽分箱统计
data_range AS (
    SELECT MIN(pred_score) AS min_val,
           MAX(pred_score) AS max_val,
           (MAX(pred_score) - MIN(pred_score)) / 10 AS bin_width
    FROM base_data
),

equal_width_stats AS (
    SELECT 'Equal Width' AS method,
           FLOOR((pred_score - dr.min_val) / dr.bin_width) + 1 AS bin_id,
           COUNT(*) AS count_in_bin,
           MIN(pred_score) AS min_score,
           MAX(pred_score) AS max_score,
           ROUND(AVG(pred_score), 2) AS avg_score
    FROM base_data b
    CROSS JOIN data_range dr
    WHERE FLOOR((pred_score - dr.min_val) / dr.bin_width) + 1 <= 10
    GROUP BY FLOOR((pred_score - dr.min_val) / dr.bin_width) + 1
)

-- 对比结果
SELECT method, bin_id, count_in_bin, min_score, max_score, avg_score,
       ROUND(count_in_bin * 100.0 / SUM(count_in_bin) OVER (PARTITION BY method), 2) AS percentage
FROM (
    SELECT * FROM equal_freq_stats
    UNION ALL
    SELECT * FROM equal_width_stats
) combined
ORDER BY method, bin_id;

-- =====================================================
-- 示例4: 业务场景定制化分箱
-- =====================================================

-- 风险管理场景：关注极值分位数
WITH risk_focused_percentiles AS (
    SELECT percentile, 
           ROW_NUMBER() OVER (ORDER BY percentile) AS bin_id,
           CASE 
               WHEN percentile = 0.01 THEN 'Extremely Low Risk'
               WHEN percentile = 0.05 THEN 'Very Low Risk'
               WHEN percentile = 0.10 THEN 'Low Risk'
               WHEN percentile = 0.25 THEN 'Below Average Risk'
               WHEN percentile = 0.50 THEN 'Average Risk'
               WHEN percentile = 0.75 THEN 'Above Average Risk'
               WHEN percentile = 0.90 THEN 'High Risk'
               WHEN percentile = 0.95 THEN 'Very High Risk'
               WHEN percentile = 0.99 THEN 'Extremely High Risk'
           END AS risk_description
    FROM (
        SELECT 0.01 AS percentile UNION ALL SELECT 0.05 UNION ALL SELECT 0.10 
        UNION ALL SELECT 0.25 UNION ALL SELECT 0.50 UNION ALL SELECT 0.75 
        UNION ALL SELECT 0.90 UNION ALL SELECT 0.95 UNION ALL SELECT 0.99
    ) p
),

base_data AS (
    SELECT pred_score
    FROM your_table_name
    WHERE DATE(SUBSTRING(risk_time, 1, 10)) >= (
        SELECT MIN(DATE(SUBSTRING(risk_time, 1, 10))) FROM your_table_name
    )
    AND DATE(SUBSTRING(risk_time, 1, 10)) <= (
        SELECT DATE_ADD(MIN(DATE(SUBSTRING(risk_time, 1, 10))), INTERVAL 5 DAY) FROM your_table_name
    )
    AND pred_score != -9999
),

custom_quantiles AS (
    SELECT rp.bin_id,
           rp.percentile,
           rp.risk_description,
           (SELECT pred_score 
            FROM (SELECT pred_score, 
                         ROW_NUMBER() OVER (ORDER BY pred_score) AS rn,
                         COUNT(*) OVER () AS total
                  FROM base_data) ranked
            WHERE rn = CEIL(rp.percentile * total)
            LIMIT 1) AS quantile_value
    FROM risk_focused_percentiles rp
)

SELECT bin_id,
       CONCAT(ROUND(percentile * 100, 1), '%') AS percentile_label,
       risk_description,
       ROUND(quantile_value, 2) AS score_threshold,
       LAG(ROUND(quantile_value, 2)) OVER (ORDER BY bin_id) AS prev_threshold
FROM custom_quantiles
ORDER BY bin_id;

-- =====================================================
-- 使用指南和最佳实践
-- =====================================================
/*
选择分箱方法的建议：

1. **等频分箱 (Equal Frequency)**:
   适用场景：
   - 数据分布不均匀或有偏斜
   - 需要确保每个分箱有足够的样本进行分析
   - 关注相对排名而非绝对数值
   
   优点：每个分箱样本量相等，统计稳定性好
   缺点：分箱边界可能不够直观

2. **等宽分箱 (Equal Width)**:
   适用场景：
   - 数据分布相对均匀
   - 分箱边界需要易于解释和理解
   - 业务规则基于具体的数值范围
   
   优点：分箱边界直观，易于解释
   缺点：可能导致某些分箱样本过少

3. **自定义分位数分箱**:
   适用场景：
   - 业务关注特定的风险等级
   - 需要与现有的风险管理体系对接
   - 监管要求特定的分位数分析
   
   优点：完全契合业务需求
   缺点：需要领域专家知识设计

实施步骤：
1. 运行示例1了解数据基本情况
2. 选择合适的分箱方法
3. 运行示例2获取完整分析结果
4. 使用示例3对比不同方法效果
5. 根据业务需求使用示例4定制分箱

性能优化：
- 为date字段和score字段创建复合索引
- 对于超大数据集，考虑抽样计算分箱边界
- 将分箱定义保存到专门的配置表中
- 定期重新计算和更新分箱边界

质量检查：
- 确保每个分箱包含足够的样本（建议>100）
- 检查分箱边界的业务合理性
- 监控分箱分布的稳定性
- 验证异常值处理的正确性
*/