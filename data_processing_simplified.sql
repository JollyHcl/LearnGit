-- 简化版数据处理SQL - 风险分析
-- 适用于MySQL 5.7+, PostgreSQL, SQL Server

-- ====================
-- 步骤1: 创建视图 - 数据预处理
-- ====================
CREATE OR REPLACE VIEW v_preprocessed_data AS
SELECT *,
       -- 提取日期（适配不同数据库）
       CASE 
           WHEN risk_time LIKE '%-%-%' THEN DATE(SUBSTRING(risk_time, 1, 10))
           ELSE DATE(risk_time)
       END AS apply_date
FROM your_table_name;  -- 替换为实际表名

-- ====================
-- 步骤2: 获取分位数边界（基于前6天数据）
-- ====================
-- 先运行这个查询来获取分位数
SELECT 
    MIN(apply_date) as earliest_date,
    DATE_ADD(MIN(apply_date), INTERVAL 5 DAY) as end_date_base,
    MIN(pred_score) as min_score,
    MAX(pred_score) as max_score,
    
    -- 手动计算十分位数（兼容老版本MySQL）
    (SELECT pred_score FROM (
        SELECT pred_score, 
               @row_number := @row_number + 1 as row_num,
               @total_rows := @total_rows
        FROM (SELECT pred_score FROM v_preprocessed_data 
              WHERE apply_date >= (SELECT MIN(apply_date) FROM v_preprocessed_data)
                AND apply_date <= (SELECT DATE_ADD(MIN(apply_date), INTERVAL 5 DAY) FROM v_preprocessed_data)
                AND pred_score != -9999
              ORDER BY pred_score) t1
        CROSS JOIN (SELECT @row_number := 0, @total_rows := (
            SELECT COUNT(*) FROM v_preprocessed_data 
            WHERE apply_date >= (SELECT MIN(apply_date) FROM v_preprocessed_data)
              AND apply_date <= (SELECT DATE_ADD(MIN(apply_date), INTERVAL 5 DAY) FROM v_preprocessed_data)
              AND pred_score != -9999
        )) t2
    ) ranked WHERE row_num = CEIL(0.1 * @total_rows)) as q1_score,
    
    (SELECT pred_score FROM (
        SELECT pred_score, 
               @row_number2 := @row_number2 + 1 as row_num,
               @total_rows2 := @total_rows2
        FROM (SELECT pred_score FROM v_preprocessed_data 
              WHERE apply_date >= (SELECT MIN(apply_date) FROM v_preprocessed_data)
                AND apply_date <= (SELECT DATE_ADD(MIN(apply_date), INTERVAL 5 DAY) FROM v_preprocessed_data)
                AND pred_score != -9999
              ORDER BY pred_score) t1
        CROSS JOIN (SELECT @row_number2 := 0, @total_rows2 := (
            SELECT COUNT(*) FROM v_preprocessed_data 
            WHERE apply_date >= (SELECT MIN(apply_date) FROM v_preprocessed_data)
              AND apply_date <= (SELECT DATE_ADD(MIN(apply_date), INTERVAL 5 DAY) FROM v_preprocessed_data)
              AND pred_score != -9999
        )) t2
    ) ranked WHERE row_num = CEIL(0.2 * @total_rows2)) as q2_score
    
    -- 可以继续添加q3到q9，或者使用下面的简化版本
    
FROM v_preprocessed_data
LIMIT 1;

-- ====================
-- 步骤3: 简化版 - 使用固定分位数值
-- ====================
-- 首先手动运行上面的查询获取分位数值，然后在下面的查询中替换具体数值

WITH recent_data AS (
    -- 获取近100天数据
    SELECT *
    FROM v_preprocessed_data
    WHERE apply_date >= DATE_SUB(CURDATE(), INTERVAL 100 DAY)
      AND apply_date <= CURDATE()
),

binned_data AS (
    SELECT *,
           CASE 
               WHEN pred_score = -9999 THEN '[-9999]'
               WHEN pred_score <= 100 THEN '(0,100]'        -- 替换为实际q1值
               WHEN pred_score <= 200 THEN '(100,200]'      -- 替换为实际q2值
               WHEN pred_score <= 300 THEN '(200,300]'      -- 替换为实际q3值
               WHEN pred_score <= 400 THEN '(300,400]'      -- 替换为实际q4值
               WHEN pred_score <= 500 THEN '(400,500]'      -- 替换为实际q5值
               WHEN pred_score <= 600 THEN '(500,600]'      -- 替换为实际q6值
               WHEN pred_score <= 700 THEN '(600,700]'      -- 替换为实际q7值
               WHEN pred_score <= 800 THEN '(700,800]'      -- 替换为实际q8值
               WHEN pred_score <= 900 THEN '(800,900]'      -- 替换为实际q9值
               ELSE '(900,1000]'                            -- 替换为实际最大值
           END AS risk_bin
    FROM recent_data
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

-- ====================
-- 步骤4: 透视表格式输出（可选）
-- ====================
SELECT apply_date,
       SUM(CASE WHEN risk_bin = '[-9999]' THEN percentage ELSE 0 END) as bin_negative_9999,
       SUM(CASE WHEN risk_bin = '(0,100]' THEN percentage ELSE 0 END) as bin_1,
       SUM(CASE WHEN risk_bin = '(100,200]' THEN percentage ELSE 0 END) as bin_2,
       SUM(CASE WHEN risk_bin = '(200,300]' THEN percentage ELSE 0 END) as bin_3,
       SUM(CASE WHEN risk_bin = '(300,400]' THEN percentage ELSE 0 END) as bin_4,
       SUM(CASE WHEN risk_bin = '(400,500]' THEN percentage ELSE 0 END) as bin_5,
       SUM(CASE WHEN risk_bin = '(500,600]' THEN percentage ELSE 0 END) as bin_6,
       SUM(CASE WHEN risk_bin = '(600,700]' THEN percentage ELSE 0 END) as bin_7,
       SUM(CASE WHEN risk_bin = '(700,800]' THEN percentage ELSE 0 END) as bin_8,
       SUM(CASE WHEN risk_bin = '(800,900]' THEN percentage ELSE 0 END) as bin_9,
       SUM(CASE WHEN risk_bin = '(900,1000]' THEN percentage ELSE 0 END) as bin_10
FROM (
    -- 这里粘贴上面的完整查询
    WITH recent_data AS (
        SELECT *
        FROM v_preprocessed_data
        WHERE apply_date >= DATE_SUB(CURDATE(), INTERVAL 100 DAY)
          AND apply_date <= CURDATE()
    ),
    binned_data AS (
        SELECT *,
               CASE 
                   WHEN pred_score = -9999 THEN '[-9999]'
                   WHEN pred_score <= 100 THEN '(0,100]'        
                   WHEN pred_score <= 200 THEN '(100,200]'      
                   WHEN pred_score <= 300 THEN '(200,300]'      
                   WHEN pred_score <= 400 THEN '(300,400]'      
                   WHEN pred_score <= 500 THEN '(400,500]'      
                   WHEN pred_score <= 600 THEN '(500,600]'      
                   WHEN pred_score <= 700 THEN '(600,700]'      
                   WHEN pred_score <= 800 THEN '(700,800]'      
                   WHEN pred_score <= 900 THEN '(800,900]'      
                   ELSE '(900,1000]'                            
               END AS risk_bin
        FROM recent_data
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
           ROUND(count_per_bin * 100.0 / total_per_day, 2) as percentage
    FROM daily_stats
) pivot_data
GROUP BY apply_date
ORDER BY apply_date;

-- ====================
-- 使用说明和注意事项
-- ====================
/*
使用步骤：
1. 将 'your_table_name' 替换为实际表名
2. 运行步骤2的查询获取实际的分位数值
3. 将步骤3中的数值（100, 200, 300等）替换为实际的分位数值
4. 运行完整查询获取结果

数据库兼容性：
- MySQL 5.7+: 使用上述代码
- PostgreSQL: 将DATE_SUB改为CURRENT_DATE - INTERVAL '100 days'
- SQL Server: 将DATE_SUB改为DATEADD(day, -100, GETDATE())

性能优化建议：
- 在apply_date和pred_score字段上创建索引
- 如果数据量很大，考虑分批处理
- 可以将分位数值保存到配置表中避免重复计算

输出格式：
- 长格式：apply_date, risk_bin, percentage
- 宽格式：apply_date, bin_1, bin_2, ..., bin_10 (透视表格式)
*/