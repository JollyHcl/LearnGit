#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
快速验证脚本：简化版本的SQL vs Python结果对比
适用于快速测试和验证
"""

import pandas as pd
import numpy as np
from datetime import datetime, timedelta
import json

def load_sample_data():
    """
    生成示例数据用于测试（如果没有实际数据库连接）
    """
    np.random.seed(42)
    n_records = 10000
    
    # 生成日期范围（120天）
    start_date = datetime.now() - timedelta(days=120)
    dates = pd.date_range(start_date, periods=120, freq='D')
    
    # 生成数据
    data = []
    for date in dates:
        n_daily = np.random.randint(50, 200)  # 每天50-200条记录
        for _ in range(n_daily):
            # 生成风险分数（正态分布 + 一些异常值）
            if np.random.random() < 0.05:  # 5%的异常值
                pred_score = -9999
            else:
                pred_score = np.random.normal(500, 150)
                pred_score = max(0, min(1000, pred_score))  # 限制在0-1000范围
            
            data.append({
                'risk_time': date.strftime('%Y-%m-%d %H:%M:%S'),
                'pred_score': pred_score
            })
    
    return pd.DataFrame(data)

def python_processing(df):
    """
    原始Python处理逻辑
    """
    print("执行Python数据处理...")
    
    # 1. 数据预处理
    df['apply_date'] = df['risk_time'].apply(lambda x: str(x).split(' ')[0])
    df['apply_date'] = pd.to_datetime(df['apply_date'])
    df['apply_month'] = df['apply_date'].dt.strftime('%Y-%m')
    
    # 2. 提取基础数据（前6天，排除-9999异常值）
    earliest_date = df['apply_date'].min()
    end_date_ = earliest_date + pd.Timedelta(days=5)
    base_data = df[
        (df['apply_date'] >= earliest_date) &
        (df['apply_date'] <= end_date_) & 
        (df['pred_score'] != -9999)
    ].copy()
    
    print(f"基准期数据: {len(base_data)} 条")
    
    # 3. 计算十分位数边界
    bins = pd.qcut(base_data['pred_score'], q=10, duplicates='drop').cat.categories
    bin_labels = [f'({int(b.left)},{int(b.right)}]' for b in bins]
    
    # 4. 添加-9999特殊分箱
    bin_labels = ['[-9999]'] + bin_labels
    bins = pd.IntervalIndex.from_tuples([(-9999, -9999)] + [(b.left, b.right) for b in bins])
    
    # 5. 筛选近100天数据
    end_date = datetime.today()
    start_date = end_date - timedelta(days=100)
    recent_data = df[
        (df['apply_date'] >= start_date) &
        (df['apply_date'] <= end_date)
    ].copy()
    
    print(f"近期数据: {len(recent_data)} 条")
    
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
    
    return res_python, bins, bin_labels

def simulate_sql_processing(df):
    """
    模拟SQL处理逻辑（使用pandas实现SQL的NTILE功能）
    """
    print("模拟SQL数据处理...")
    
    # 1. 数据预处理
    df_sql = df.copy()
    df_sql['apply_date'] = pd.to_datetime(df_sql['risk_time'].str[:10])
    
    # 2. 基准期数据
    earliest_date = df_sql['apply_date'].min()
    end_date_ = earliest_date + pd.Timedelta(days=5)
    base_data = df_sql[
        (df_sql['apply_date'] >= earliest_date) &
        (df_sql['apply_date'] <= end_date_) & 
        (df_sql['pred_score'] != -9999)
    ].copy()
    
    # 3. 使用NTILE(10)等效逻辑计算分位数
    base_data_sorted = base_data.sort_values('pred_score')
    base_data_sorted['ntile_group'] = pd.cut(
        range(len(base_data_sorted)), 
        bins=10, 
        labels=range(1, 11)
    ).astype(int)
    
    # 4. 计算每个NTILE组的边界
    ntile_boundaries = base_data_sorted.groupby('ntile_group')['pred_score'].agg(['min', 'max']).reset_index()
    ntile_boundaries['left_bound'] = ntile_boundaries['min'].shift(1).fillna(ntile_boundaries['min'].iloc[0])
    ntile_boundaries['right_bound'] = ntile_boundaries['max']
    
    # 5. 生成分箱标签
    bin_definitions = []
    for _, row in ntile_boundaries.iterrows():
        if row['ntile_group'] == 1:
            left = ntile_boundaries['min'].iloc[0]
        else:
            left = ntile_boundaries.loc[ntile_boundaries['ntile_group'] == row['ntile_group'] - 1, 'max'].iloc[0]
        
        right = row['max']
        bin_label = f'({int(left)},{int(right)}]'
        bin_definitions.append({
            'ntile_group': row['ntile_group'],
            'left_bound': left,
            'right_bound': right,
            'bin_label': bin_label
        })
    
    bin_df = pd.DataFrame(bin_definitions)
    
    # 6. 近期数据
    end_date = datetime.today()
    start_date = end_date - timedelta(days=100)
    recent_data = df_sql[
        (df_sql['apply_date'] >= start_date) &
        (df_sql['apply_date'] <= end_date)
    ].copy()
    
    # 7. 应用分箱
    def assign_bin(score, bin_df):
        if score == -9999:
            return '[-9999]'
        
        for _, row in bin_df.iterrows():
            if score > row['left_bound'] and score <= row['right_bound']:
                return row['bin_label']
        return None
    
    recent_data['risk_bin'] = recent_data['pred_score'].apply(lambda x: assign_bin(x, bin_df))
    
    # 8. 统计
    daily_stats = recent_data.groupby(['apply_date', 'risk_bin']).size().reset_index(name='count')
    daily_totals = recent_data.groupby('apply_date').size().reset_index(name='total')
    
    result = daily_stats.merge(daily_totals, on='apply_date')
    result['percentage'] = (result['count'] / result['total'] * 100).round(2)
    
    res_sql = result[['apply_date', 'risk_bin', 'percentage']]
    
    return res_sql, bin_df

def compare_results(python_result, sql_result):
    """
    对比两个结果的一致性
    """
    print("\n=== 结果对比 ===")
    
    # 标准化数据
    python_df = python_result.copy()
    sql_df = sql_result.copy()
    
    python_df['apply_date'] = pd.to_datetime(python_df['apply_date'])
    sql_df['apply_date'] = pd.to_datetime(sql_df['apply_date'])
    
    # 排序
    python_df = python_df.sort_values(['apply_date', 'risk_bin']).reset_index(drop=True)
    sql_df = sql_df.sort_values(['apply_date', 'risk_bin']).reset_index(drop=True)
    
    print(f"Python结果: {len(python_df)} 条记录")
    print(f"SQL结果: {len(sql_df)} 条记录")
    
    # 合并对比
    merged = pd.merge(
        python_df, sql_df,
        on=['apply_date', 'risk_bin'],
        how='outer',
        suffixes=('_python', '_sql')
    )
    
    merged['percentage_python'] = merged['percentage_python'].fillna(0)
    merged['percentage_sql'] = merged['percentage_sql'].fillna(0)
    merged['diff'] = abs(merged['percentage_python'] - merged['percentage_sql'])
    
    # 统计分析
    max_diff = merged['diff'].max()
    mean_diff = merged['diff'].mean()
    
    print(f"最大差异: {max_diff:.4f}%")
    print(f"平均差异: {mean_diff:.4f}%")
    
    # 一致性评估
    tolerance = 0.01
    consistent_records = (merged['diff'] <= tolerance).sum()
    consistency_rate = consistent_records / len(merged) * 100
    
    print(f"一致性比例: {consistency_rate:.2f}%")
    
    if consistency_rate >= 99.0:
        print("✓ 结果高度一致！")
        status = "PASS"
    elif consistency_rate >= 95.0:
        print("⚠️ 结果基本一致，存在少量差异")
        status = "WARN"
    else:
        print("✗ 结果存在较大差异")
        status = "FAIL"
    
    # 显示差异较大的记录
    large_diff = merged[merged['diff'] > tolerance]
    if len(large_diff) > 0:
        print(f"\n差异较大的记录 ({len(large_diff)} 条):")
        print(large_diff[['apply_date', 'risk_bin', 'percentage_python', 'percentage_sql', 'diff']].head())
    
    return {
        'status': status,
        'consistency_rate': consistency_rate,
        'max_diff': max_diff,
        'mean_diff': mean_diff,
        'merged_data': merged
    }

def main():
    """
    主函数
    """
    print("=== 数据处理一致性验证 ===\n")
    
    # 1. 加载数据（这里使用示例数据，实际使用时替换为数据库查询）
    print("1. 加载数据...")
    df = load_sample_data()
    print(f"加载了 {len(df)} 条记录")
    
    # 2. Python处理
    print("\n2. Python数据处理...")
    python_result, python_bins, python_labels = python_processing(df)
    
    # 3. SQL处理（模拟）
    print("\n3. SQL数据处理（模拟）...")
    sql_result, sql_bins = simulate_sql_processing(df)
    
    # 4. 结果对比
    print("\n4. 结果对比...")
    comparison = compare_results(python_result, sql_result)
    
    # 5. 生成报告
    print(f"\n=== 验证报告 ===")
    print(f"验证状态: {comparison['status']}")
    print(f"一致性: {comparison['consistency_rate']:.2f}%")
    print(f"最大差异: {comparison['max_diff']:.4f}%")
    print(f"平均差异: {comparison['mean_diff']:.4f}%")
    
    # 6. 保存结果
    comparison['merged_data'].to_csv('validation_results.csv', index=False)
    print(f"\n详细结果已保存到: validation_results.csv")
    
    # 7. 显示分箱信息
    print(f"\nPython分箱标签示例:")
    for i, label in enumerate(python_labels[:5]):
        print(f"  {i+1}: {label}")
    
    print(f"\nSQL分箱边界示例:")
    print(sql_bins.head())

if __name__ == "__main__":
    main()