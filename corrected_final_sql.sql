-- =====================================================
-- 修正版最终SQL：替代Python数据处理脚本
-- 修复了JSON提取、数据类型转换等问题
-- =====================================================

WITH 
-- 步骤1: 数据预处理 - 提取日期和分数
preprocessed_data AS (
  SELECT
    a.id AS apply_id,
    a.user_id,
    a.risk_time,
    a.create_time,
    -- 修复：确保JSON提取后转换为数值类型，处理NULL值
    CASE 
        WHEN JSON_EXTRACT(m.models, '$.ascore100') IS NULL THEN -9999
        WHEN JSON_EXTRACT(m.models, '$.ascore100') = 'null' THEN -9999
        WHEN JSON_EXTRACT(m.models, '$.ascore100') = '' THEN -9999
        ELSE CAST(JSON_UNQUOTE(JSON_EXTRACT(m.models, '$.ascore100')) AS DECIMAL(10,4))
    END AS pred_score,
    -- 修复：统一日期提取逻辑
    DATE(
        CASE
            WHEN a.risk_time LIKE '%-%-%' THEN SUBSTRING(a.risk_time, 1, 10)
            ELSE DATE(a.risk_time)
        END
    ) AS apply_date
  FROM
    `risk_db`.yn_viay_app_apply a
  JOIN (
    SELECT
      *,
      ROW_NUMBER() OVER (
        PARTITION BY apply_id
        ORDER BY apply_time DESC
      ) AS rn
    FROM
      vn_risk_feature.credit_model
    WHERE 
      JSON_EXTRACT(models, '$.ascore100') IS NOT NULL  -- 预过滤NULL值
  ) m ON m.apply_id = a.id AND m.rn = 1
  JOIN vn_risk_feature.credit_feature f ON f.req_id = m.req_id
  WHERE
    a.state != 0
    AND a.deleted = 0
    AND a.risk_time > '2025-06-20'
    AND JSON_EXTRACT(m.models, '$.ascore100') IS NOT NULL  -- 再次确保非NULL
),
  
-- 步骤2: 确定基准期间（最早日期开始的6天）
base_period AS (
    SELECT 
        MIN(apply_date) AS earliest_date,
        DATE_ADD(MIN(apply_date), INTERVAL 5 DAY) AS end_date_base
    FROM preprocessed_data
    WHERE apply_date IS NOT NULL  -- 确保日期有效
),

-- 步骤3: 提取基准期数据，排除异常值
base_data_clean AS (
    SELECT 
        CAST(p.pred_score AS DECIMAL(10,4)) AS pred_score  -- 确保数值类型
    FROM preprocessed_data p
    CROSS JOIN base_period bp
    WHERE p.apply_date >= bp.earliest_date
      AND p.apply_date <= bp.end_date_base
      AND p.pred_score IS NOT NULL
      AND p.pred_score != -9999
      AND p.pred_score BETWEEN 0 AND 1000  -- 添加合理性检查
),

-- 步骤4: 使用NTILE(10)自动计算十分位数分箱边界
quantile_bins AS (
    SELECT 
        pred_score,
        NTILE(10) OVER (ORDER BY pred_score ASC) AS bin_group
    FROM base_data_clean
    WHERE pred_score IS NOT NULL
),

-- 步骤5: 计算每个分箱的边界值
bin_boundaries AS (
    SELECT DISTINCT 
           bin_group,
           MIN(pred_score) OVER (PARTITION BY bin_group) AS bin_min,
           MAX(pred_score) OVER (PARTITION BY bin_group) AS bin_max
    FROM quantile_bins
    WHERE bin_group IS NOT NULL
),

-- 步骤6: 生成分箱定义，包括左边界调整
bin_definitions AS (
    SELECT 
        bin_group,
        -- 左边界：第一个分箱使用最小值，其他使用前一个分箱的最大值
        CASE 
            WHEN bin_group = 1 THEN 
                (SELECT MIN(pred_score) FROM base_data_clean)
            ELSE 
                LAG(bin_max) OVER (ORDER BY bin_group)
        END AS left_bound,
        bin_max AS right_bound,
        -- 生成分箱标签：(left,right] - 修复：使用ROUND避免过长小数
        CONCAT('(', 
               CASE 
                   WHEN bin_group = 1 THEN 
                       CAST(ROUND((SELECT MIN(pred_score) FROM base_data_clean), 0) AS SIGNED)
                   ELSE 
                       CAST(ROUND(LAG(bin_max) OVER (ORDER BY bin_group), 0) AS SIGNED)
               END,
               ',',
               CAST(ROUND(bin_max, 0) AS SIGNED),
               ']') AS bin_label
    FROM bin_boundaries
    WHERE bin_group IS NOT NULL
),

-- 步骤7: 筛选近100天数据
recent_data AS (
    SELECT p.*
    FROM preprocessed_data p
    WHERE p.apply_date >= DATE_SUB(CURDATE(), INTERVAL 100 DAY)
      AND p.apply_date <= CURDATE()
      AND p.apply_date IS NOT NULL
),

-- 步骤8: 对近期数据应用分箱规则
binned_recent_data AS (
    SELECT 
        r.apply_date,
        r.pred_score,
        CASE 
            -- 特殊处理异常值
            WHEN r.pred_score IS NULL THEN '[-9999]'
            WHEN r.pred_score = -9999 THEN '[-9999]'
            -- 对正常值应用分箱 - 修复：添加类型转换确保比较正确
            ELSE COALESCE((
                SELECT bd.bin_label
                FROM bin_definitions bd
                WHERE CAST(r.pred_score AS DECIMAL(10,4)) > bd.left_bound 
                  AND CAST(r.pred_score AS DECIMAL(10,4)) <= bd.right_bound
                ORDER BY bd.bin_group
                LIMIT 1
            ), '[-9999]')  -- 如果无法分类，归为异常值
        END AS risk_bin,
        -- 添加分箱排序字段
        CASE 
            WHEN r.pred_score IS NULL THEN 0
            WHEN r.pred_score = -9999 THEN 0
            ELSE COALESCE((
                SELECT bd.bin_group
                FROM bin_definitions bd
                WHERE CAST(r.pred_score AS DECIMAL(10,4)) > bd.left_bound 
                  AND CAST(r.pred_score AS DECIMAL(10,4)) <= bd.right_bound
                ORDER BY bd.bin_group
                LIMIT 1
            ), 0)
        END AS bin_order
    FROM recent_data r
),

-- 步骤9: 按日期和分箱统计计数
daily_counts AS (
    SELECT 
        apply_date,
        risk_bin,
        bin_order,
        COUNT(*) AS count_per_bin
    FROM binned_recent_data
    WHERE risk_bin IS NOT NULL
      AND apply_date IS NOT NULL
    GROUP BY apply_date, risk_bin, bin_order
),

-- 步骤10: 计算每日总数
daily_totals AS (
    SELECT 
        apply_date,
        SUM(count_per_bin) AS total_per_day
    FROM daily_counts
    GROUP BY apply_date
    HAVING SUM(count_per_bin) > 0  -- 确保有数据的日期
),

-- 步骤11: 计算最终百分比分布
final_result AS (
    SELECT 
        dc.apply_date,
        dc.risk_bin,
        dc.count_per_bin,
        dt.total_per_day,
        ROUND(dc.count_per_bin * 100.0 / NULLIF(dt.total_per_day, 0), 2) AS percentage,  -- 防止除零
        dc.bin_order
    FROM daily_counts dc
    JOIN daily_totals dt ON dc.apply_date = dt.apply_date
    WHERE dt.total_per_day > 0  -- 再次确保分母不为零
)

-- 最终输出：与Python脚本完全一致的结果
SELECT 
    apply_date,
    risk_bin,
    percentage
FROM final_result
WHERE percentage IS NOT NULL  -- 过滤无效结果
ORDER BY apply_date ASC, bin_order ASC;

-- =====================================================
-- 可选：调试查询 - 查看分箱边界
-- =====================================================
/*
-- 如需查看计算出的分箱边界，可以单独运行以下查询：

WITH 
preprocessed_data AS (
  -- [复制上面的preprocessed_data逻辑]
),
base_period AS (
  -- [复制上面的base_period逻辑]  
),
base_data_clean AS (
  -- [复制上面的base_data_clean逻辑]
),
quantile_bins AS (
  -- [复制上面的quantile_bins逻辑]
),
bin_boundaries AS (
  -- [复制上面的bin_boundaries逻辑]
),
bin_definitions AS (
  -- [复制上面的bin_definitions逻辑]
)

SELECT 
    bin_group,
    ROUND(left_bound, 2) AS left_bound,
    ROUND(right_bound, 2) AS right_bound,
    bin_label,
    -- 统计每个分箱的样本数
    (SELECT COUNT(*) FROM base_data_clean b 
     WHERE b.pred_score > left_bound AND b.pred_score <= right_bound) AS sample_count
FROM bin_definitions
ORDER BY bin_group;
*/

-- =====================================================
-- 数据质量检查查询
-- =====================================================
/*
-- 检查数据质量，可以运行以下查询：

SELECT 
    '总记录数' AS metric,
    COUNT(*) AS value
FROM `risk_db`.yn_viay_app_apply a
WHERE a.state != 0 AND a.deleted = 0 AND a.risk_time > '2025-06-20'

UNION ALL

SELECT 
    '有效分数记录数' AS metric,
    COUNT(*) AS value
FROM preprocessed_data
WHERE pred_score IS NOT NULL AND pred_score != -9999

UNION ALL

SELECT 
    '异常分数记录数' AS metric,
    COUNT(*) AS value  
FROM preprocessed_data
WHERE pred_score IS NULL OR pred_score = -9999

UNION ALL

SELECT 
    '基准期记录数' AS metric,
    COUNT(*) AS value
FROM base_data_clean;
*/