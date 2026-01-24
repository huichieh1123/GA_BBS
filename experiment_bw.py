import time
import csv
import pandas as pd
import matplotlib.pyplot as plt
import bs_solver  # 確保已經編譯好 (setup.py build_ext --inplace)

# ==========================================
# 實驗設定
# ==========================================
BW_LIST = [1, 5, 10, 20, 50, 100, 200, 300, 400, 500, 600]
FIXED_AGV_COUNT = 3
OUTPUT_CSV = "experiment_bw_results.csv"

# ==========================================
# 核心資料讀取邏輯 (對齊 main.py)
# ==========================================
def load_csv_data():
    """載入地圖設定、貨櫃位置與任務清單 (與 main.py 一致)"""
    config = {}
    with open('yard_config.csv', 'r') as f:
        reader = csv.DictReader(f)
        row = next(reader)
        config['max_row'] = int(row['max_row'])
        config['max_bay'] = int(row['max_bay'])
        config['max_level'] = int(row['max_level'])
        config['total_boxes'] = int(row['total_boxes'])
        config['t_travel'] = float(row.get('time_travel_unit', 5.0))
        config['t_handle'] = float(row.get('time_handle', 30.0))
        config['t_process'] = float(row.get('time_process', 10.0))

    boxes = []
    with open('mock_yard.csv', 'r') as f:
        reader = csv.DictReader(f)
        for row in reader:
            boxes.append({
                'id': int(row['container_id']),
                'row': int(row['row']),
                'bay': int(row['bay']),
                'level': int(row['level'])
            })

    commands = []
    with open('mock_commands.csv', 'r') as f:
        reader = csv.DictReader(f)
        for row in reader:
            commands.append({
                'id': int(row['parent_carrier_id']),
                'type': row['cmd_type'],
                'dest': {'row': int(row['dst_row']), 'bay': int(row['dst_bay']), 'level': int(row['dst_level'])}
            })
    return config, boxes, commands

def run_experiment():
    # 1. 準備資料
    print("Loading data from local CSVs...")
    try:
        config, boxes, commands = load_csv_data()
        # [修改點]：自動從載入的 commands 提取 target 序號作為 job_sequence
        job_sequence = [cmd['id'] for cmd in commands if cmd['type'] == 'target']
    except Exception as e:
        print(f"Error loading data: {e}")
        return

    if not job_sequence:
        print("Error: No target jobs found in mock_commands.csv")
        return

    results = []

    print(f"Starting experiment with BW list: {BW_LIST}")
    print("-" * 60)
    print(f"{'BW':<10} | {'Makespan (s)':<15} | {'Compute Time (s)':<20}")
    print("-" * 60)

    # 2. 迴圈測試不同的 Beam Width
    for bw in BW_LIST:
        # 設定 C++ 內部參數
        bs_solver.set_config(
            config['t_travel'], 
            config['t_handle'], 
            config['t_process'], 
            FIXED_AGV_COUNT, 
            bw
        )
        
        start_time = time.time()
        # 執行 Solver
        logs = bs_solver.run_fixed_solver(config, boxes, commands, job_sequence)
        end_time = time.time()
        
        compute_time = end_time - start_time
        final_makespan = max(log.makespan for log in logs) if logs else -1.0

        print(f"{bw:<10} | {final_makespan:<15.2f} | {compute_time:<20.4f}")

        results.append({
            "Beam_Width": bw,
            "AGV_Count": FIXED_AGV_COUNT,
            "Makespan": final_makespan,
            "Compute_Time_Seconds": round(compute_time, 4),
            "Total_Missions": len(logs)
        })

    # 3. 寫入 CSV
    print("-" * 60)
    print(f"Saving results to {OUTPUT_CSV}...")
    df = pd.DataFrame(results)
    df.to_csv(OUTPUT_CSV, index=False)
    print("Done!")

if __name__ == "__main__":
    run_experiment()