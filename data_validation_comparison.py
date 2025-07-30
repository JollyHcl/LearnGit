#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
数据验证脚本：对比SQL和Python数据处理结果的一致性
用于验证SQL分箱逻辑与原始Python代码的输出是否一致
"""

import pandas as pd
import numpy as np
from datetime import datetime, timedelta
import pymysql
# import psycopg2  # 如果使用PostgreSQL
# import sqlite3   # 如果使用SQLite
import warnings
warnings.filterwarnings('ignore')

class DataValidationComparison:
    def __init__(self, db_config, table_name):
        """
        初始化数据验证类
        
        Args:
            db_config (dict): 数据库连接配置
            table_name (str): 表名
        """
        self.db_config = db_config
        self.table_name = table_name
        self.conn = None
        
    def connect_database(self):
        """建立数据库连接"""
        try:
            self.conn = pymysql.connect(**self.db_config)
            print("✓ 数据库连接成功")
        except Exception as e:
            print(f"✗ 数据库连接失败: {e}")
            raise
    
    def close_connection(self):
        """关闭数据库连接"""
        if self.conn:
            self.conn.close()
            print("✓ 数据库连接已关闭")
    
    def load_data_from_db(self):
        """从数据库加载原始数据"""
        query = f"SELECT * FROM {self.table_name}"
        df = pd.read_sql(query, self.conn)
        print(f"✓ 从数据库加载数据: {len(df)} 条记录")
        return df
    
    def python_data_processing(self, df):
        """
        原始Python数据处理逻辑（复制您提供的代码）
        """
        print("\n=== 执行Python数据处理 ===")
        
        # 1. 数据预处理
        df_python = df.copy()
        df_python['apply_date'] = df_python['risk_time'].apply(lambda x: str(x).split(' ')[0])
        df_python['apply_date'] = pd.to_datetime(df_python['apply_date'])
        df_python['apply_month'] = df_python['apply_date'].dt.strftime('%Y-%m')
        
        print(f"✓ 数据预处理完成，日期范围: {df_python['apply_date'].min()} 到 {df_python['apply_date'].max()}")
        
        # 2. 提取基础数据（前6天，排除-9999异常值）
        earliest_date = df_python['apply_date'].min()
        end_date_ = earliest_date + pd.Timedelta(days=5)
        base_data = df_python[
            (df_python['apply_date'] >= earliest_date) &
            (df_python['apply_date'] <= end_date_) & 
            (df_python['pred_score'] != -9999)
        ].copy()
        
        print(f"✓ 基准期数据: {len(base_data)} 条记录 ({earliest_date} 到 {end_date_})")
        
        # 3. 计算十分位数边界
        bins = pd.qcut(base_data['pred_score'], q=10, duplicates='drop').cat.categories
        bin_labels = [f'({int(b.left)},{int(b.right)}]' for b in bins]
        
        print(f"✓ 计算分箱边界: {len(bins)} 个分箱")
        
        # 4. 添加-9999特殊分箱
        bin_labels = ['[-9999]'] + bin_labels
        bins = pd.IntervalIndex.from_tuples([(-9999, -9999)] + [(b.left, b.right) for b in bins])
        
        # 5. 筛选近100天数据
        end_date = datetime.today()
        start_date = end_date - timedelta(days=100)
        recent_data = df_python[
            (df_python['apply_date'] >= start_date) &
            (df_python['apply_date'] <= end_date)
        ].copy()
        
        print(f"✓ 近期数据: {len(recent_data)} 条记录 ({start_date.date()} 到 {end_date.date()})")
        
        # 6. 应用分箱
        recent_data['risk_bin'] = pd.cut(
            recent_data['pred_score'],
            bins=[-9999] + [b.left for b in bins[1:]] + [bins[-1].right],
            labels=bin_labels,
            include_lowest=True
        )
        
        # 7. 按日期和分箱统计
        daily_dist = recent_data.groupby(['apply_date', 'risk_bin']).size().unstack(fill_value=0)
        daily_pct = daily_dist.div(daily_dist.sum(axis=1), axis=0) * 100
        res_python = daily_pct.stack().reset_index().rename(columns={0: 'Percentage'})
        res_python.columns = ['apply_date', 'risk_bin', 'percentage']
        
        print(f"✓ Python处理完成: {len(res_python)} 条结果记录")
        
        # 返回关键信息用于对比
        return {
            'result_df': res_python,
            'bin_boundaries': bins,
            'bin_labels': bin_labels,
            'base_data_count': len(base_data),
            'recent_data_count': len(recent_data),
            'base_period': (earliest_date, end_date_),
            'analysis_period': (start_date, end_date)
        }
    
    def execute_sql_processing(self):
        """
        执行SQL数据处理并获取结果
        """
        print("\n=== 执行SQL数据处理 ===")
        
        # SQL查询 - 基于auto_binning_sql.sql的逻辑
        sql_query = f"""
        WITH preprocessed_data AS (
            SELECT *,
                   DATE(SUBSTRING(risk_time, 1, 10)) AS apply_date
            FROM {self.table_name}
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
                   LAG(MAX(pred_score)) OVER (ORDER BY ntile_group) AS prev_max
            FROM (
                SELECT pred_score,
                       NTILE(10) OVER (ORDER BY pred_score) AS ntile_group
                FROM base_data_clean
            ) t
        ),
        
        bin_definitions AS (
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
            SELECT *
            FROM preprocessed_data
            WHERE apply_date >= DATE_SUB(CURDATE(), INTERVAL 100 DAY)
              AND apply_date <= CURDATE()
        ),
        
        binned_recent_data AS (
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
            SELECT apply_date,
                   risk_bin,
                   COUNT(*) AS count_per_bin,
                   SUM(COUNT(*)) OVER (PARTITION BY apply_date) AS total_per_day
            FROM binned_recent_data
            WHERE risk_bin IS NOT NULL
            GROUP BY apply_date, risk_bin
        )
        
        SELECT apply_date,
               risk_bin,
               ROUND(count_per_bin * 100.0 / total_per_day, 2) AS percentage
        FROM daily_distribution
        ORDER BY apply_date, risk_bin;
        """
        
        # 执行SQL查询
        res_sql = pd.read_sql(sql_query, self.conn)
        print(f"✓ SQL处理完成: {len(res_sql)} 条结果记录")
        
        # 获取分箱边界信息
        bin_info_query = f"""
        WITH preprocessed_data AS (
            SELECT *, DATE(SUBSTRING(risk_time, 1, 10)) AS apply_date
            FROM {self.table_name}
        ),
        base_period AS (
            SELECT MIN(apply_date) AS start_date,
                   DATE_ADD(MIN(apply_date), INTERVAL 5 DAY) AS end_date
            FROM preprocessed_data
        ),
        base_data_clean AS (
            SELECT p.pred_score FROM preprocessed_data p
            CROSS JOIN base_period bp
            WHERE p.apply_date >= bp.start_date AND p.apply_date <= bp.end_date AND p.pred_score != -9999
        ),
        quantile_boundaries AS (
            SELECT DISTINCT ntile_group,
                   MIN(pred_score) OVER (PARTITION BY ntile_group) AS bin_min,
                   MAX(pred_score) OVER (PARTITION BY ntile_group) AS bin_max,
                   LAG(MAX(pred_score)) OVER (ORDER BY ntile_group) AS prev_max
            FROM (SELECT pred_score, NTILE(10) OVER (ORDER BY pred_score) AS ntile_group FROM base_data_clean) t
        )
        
        SELECT ntile_group AS bin_id,
               COALESCE(prev_max, (SELECT MIN(pred_score) FROM base_data_clean)) AS left_bound,
               bin_max AS right_bound,
               CONCAT('(', COALESCE(prev_max, (SELECT MIN(pred_score) FROM base_data_clean)), ',', bin_max, ']') AS bin_label
        FROM quantile_boundaries
        WHERE ntile_group IS NOT NULL
        ORDER BY ntile_group;
        """
        
        bin_info_sql = pd.read_sql(bin_info_query, self.conn)
        
        return {
            'result_df': res_sql,
            'bin_info': bin_info_sql
        }
    
    def compare_results(self, python_results, sql_results):
        """
        对比Python和SQL处理结果
        """
        print("\n=== 结果对比分析 ===")
        
        python_df = python_results['result_df'].copy()
        sql_df = sql_results['result_df'].copy()
        
        # 1. 基本统计对比
        print(f"Python结果记录数: {len(python_df)}")
        print(f"SQL结果记录数: {len(sql_df)}")
        
        # 2. 数据类型标准化
        python_df['apply_date'] = pd.to_datetime(python_df['apply_date'])
        sql_df['apply_date'] = pd.to_datetime(sql_df['apply_date'])
        
        # 3. 排序以便对比
        python_df = python_df.sort_values(['apply_date', 'risk_bin']).reset_index(drop=True)
        sql_df = sql_df.sort_values(['apply_date', 'risk_bin']).reset_index(drop=True)
        
        # 4. 检查日期范围
        print(f"\nPython日期范围: {python_df['apply_date'].min()} 到 {python_df['apply_date'].max()}")
        print(f"SQL日期范围: {sql_df['apply_date'].min()} 到 {sql_df['apply_date'].max()}")
        
        # 5. 检查分箱标签
        python_bins = set(python_df['risk_bin'].unique())
        sql_bins = set(sql_df['risk_bin'].unique())
        
        print(f"\nPython分箱数量: {len(python_bins)}")
        print(f"SQL分箱数量: {len(sql_bins)}")
        
        missing_in_sql = python_bins - sql_bins
        missing_in_python = sql_bins - python_bins
        
        if missing_in_sql:
            print(f"⚠️  SQL中缺失的分箱: {missing_in_sql}")
        if missing_in_python:
            print(f"⚠️  Python中缺失的分箱: {missing_in_python}")
        
        # 6. 合并数据进行详细对比
        merged = pd.merge(
            python_df, sql_df, 
            on=['apply_date', 'risk_bin'], 
            how='outer', 
            suffixes=('_python', '_sql')
        )
        
        # 7. 计算差异
        merged['percentage_python'] = merged['percentage_python'].fillna(0)
        merged['percentage_sql'] = merged['percentage_sql'].fillna(0)
        merged['diff'] = abs(merged['percentage_python'] - merged['percentage_sql'])
        
        # 8. 统计分析
        max_diff = merged['diff'].max()
        mean_diff = merged['diff'].mean()
        median_diff = merged['diff'].median()
        
        print(f"\n=== 差异统计 ===")
        print(f"最大差异: {max_diff:.4f}%")
        print(f"平均差异: {mean_diff:.4f}%")
        print(f"中位数差异: {median_diff:.4f}%")
        
        # 9. 一致性评估
        tolerance = 0.01  # 容差0.01%
        consistent_records = (merged['diff'] <= tolerance).sum()
        total_records = len(merged)
        consistency_rate = consistent_records / total_records * 100
        
        print(f"\n=== 一致性评估 ===")
        print(f"容差设置: ≤{tolerance}%")
        print(f"一致性记录: {consistent_records}/{total_records}")
        print(f"一致性比例: {consistency_rate:.2f}%")
        
        # 10. 识别主要差异
        large_diff = merged[merged['diff'] > tolerance]
        if len(large_diff) > 0:
            print(f"\n⚠️  发现 {len(large_diff)} 条差异较大的记录:")
            print(large_diff[['apply_date', 'risk_bin', 'percentage_python', 'percentage_sql', 'diff']].head(10))
        else:
            print("\n✓ 所有记录都在容差范围内，结果高度一致！")
        
        return {
            'merged_data': merged,
            'max_diff': max_diff,
            'mean_diff': mean_diff,
            'consistency_rate': consistency_rate,
            'large_diff_records': large_diff
        }
    
    def validate_bin_boundaries(self, python_results, sql_results):
        """
        验证分箱边界的一致性
        """
        print("\n=== 分箱边界验证 ===")
        
        # Python分箱边界
        python_bins = python_results['bin_boundaries']
        python_labels = python_results['bin_labels']
        
        # SQL分箱边界
        sql_bin_info = sql_results['bin_info']
        
        print(f"Python分箱数量: {len(python_bins)}")
        print(f"SQL分箱数量: {len(sql_bin_info)}")
        
        # 对比分箱边界
        print("\n分箱边界对比:")
        print("Bin_ID | Python边界 | SQL边界 | 匹配")
        print("-" * 50)
        
        for i, (python_label, sql_row) in enumerate(zip(python_labels[1:], sql_bin_info.itertuples())):
            python_interval = python_bins[i+1]  # 跳过-9999分箱
            sql_left = sql_row.left_bound
            sql_right = sql_row.right_bound
            
            # 检查边界是否匹配（允许小的浮点误差）
            left_match = abs(python_interval.left - sql_left) < 0.001
            right_match = abs(python_interval.right - sql_right) < 0.001
            match_status = "✓" if (left_match and right_match) else "✗"
            
            print(f"{i+1:6d} | ({python_interval.left:.2f},{python_interval.right:.2f}] | ({sql_left:.2f},{sql_right:.2f}] | {match_status}")
        
        return True
    
    def generate_report(self, comparison_results):
        """
        生成验证报告
        """
        print("\n" + "="*60)
        print("数据验证报告")
        print("="*60)
        
        max_diff = comparison_results['max_diff']
        mean_diff = comparison_results['mean_diff']
        consistency_rate = comparison_results['consistency_rate']
        
        print(f"最大百分比差异: {max_diff:.4f}%")
        print(f"平均百分比差异: {mean_diff:.4f}%")
        print(f"数据一致性比例: {consistency_rate:.2f}%")
        
        # 评估等级
        if consistency_rate >= 99.9:
            grade = "A+ (优秀)"
            status = "✓ SQL实现与Python完全一致"
        elif consistency_rate >= 99.0:
            grade = "A (良好)"
            status = "✓ SQL实现与Python高度一致"
        elif consistency_rate >= 95.0:
            grade = "B (可接受)"
            status = "⚠️ SQL实现与Python基本一致，存在少量差异"
        else:
            grade = "C (需要检查)"
            status = "✗ SQL实现与Python存在较大差异，需要检查"
        
        print(f"一致性等级: {grade}")
        print(f"验证状态: {status}")
        
        if len(comparison_results['large_diff_records']) > 0:
            print(f"\n需要关注的差异记录数: {len(comparison_results['large_diff_records'])}")
        
        print("\n建议:")
        if consistency_rate >= 99.0:
            print("- SQL实现可以投入生产使用")
            print("- 定期进行抽样验证以确保持续一致性")
        else:
            print("- 检查SQL逻辑与Python实现的差异")
            print("- 特别关注分箱边界和日期处理逻辑")
            print("- 验证数据类型转换是否正确")
        
        return grade, status

def main():
    """
    主函数 - 执行完整的验证流程
    """
    # 数据库配置 - 请根据实际情况修改
    db_config = {
        'host': 'localhost',
        'user': 'your_username',
        'password': 'your_password',
        'database': 'your_database',
        'charset': 'utf8mb4'
    }
    
    table_name = 'your_table_name'  # 请替换为实际表名
    
    # 创建验证实例
    validator = DataValidationComparison(db_config, table_name)
    
    try:
        # 1. 连接数据库
        validator.connect_database()
        
        # 2. 加载数据
        raw_data = validator.load_data_from_db()
        
        # 3. 执行Python处理
        python_results = validator.python_data_processing(raw_data)
        
        # 4. 执行SQL处理
        sql_results = validator.execute_sql_processing()
        
        # 5. 对比结果
        comparison_results = validator.compare_results(python_results, sql_results)
        
        # 6. 验证分箱边界
        validator.validate_bin_boundaries(python_results, sql_results)
        
        # 7. 生成报告
        grade, status = validator.generate_report(comparison_results)
        
        # 8. 保存详细对比数据（可选）
        comparison_results['merged_data'].to_csv('comparison_results.csv', index=False)
        print(f"\n详细对比数据已保存到: comparison_results.csv")
        
    except Exception as e:
        print(f"验证过程中发生错误: {e}")
        import traceback
        traceback.print_exc()
    
    finally:
        # 9. 关闭数据库连接
        validator.close_connection()

if __name__ == "__main__":
    main()