import time
import csv
import pandas as pd
import matplotlib.pyplot as plt
import bs_solver  # 確保已經編譯好 (setup.py build_ext --inplace)
from main import load_csv_data, job_sequence  # 從 main.py 匯入資料讀取函式和正確的 job_sequence

# ==========================================
# 實驗設定
# ==========================================
# 設定想要測試的 Beam Width 列表
BW_LIST = [1, 5, 10, 20, 50, 100, 200, 300, 400, 500, 600]

# 設定 AGV 數量 (固定)
FIXED_AGV_COUNT = 3

# 輸出檔案名稱
OUTPUT_CSV = "experiment_bw_results.csv"

def run_experiment():
    # 1. 準備資料
    print("Loading data...")
    try:
        config, boxes, commands = load_csv_data()
    except Exception as e:
        print(f"Error loading data: {e}")
        return

    # 準備結果容器
    results = []

    print(f"Starting experiment with BW list: {BW_LIST}")
    print("-" * 60)
    print(f"{'BW':<10} | {'Makespan (s)':<15} | {'Compute Time (s)':<20}")
    print("-" * 60)

    # 2. 迴圈測試不同的 Beam Width
    for bw in BW_LIST:
        # [CRITICAL] 設定 C++ 內部參數
        # 這裡會動態改變 BW，AGV 保持固定
        bs_solver.set_config(
            config['t_travel'],
            config['t_handle'],
            config['t_process'],
            FIXED_AGV_COUNT,
            bw  # <--- 變數
        )

        start_time = time.time()
        
        # 執行 Solver
        # 注意：這裡假設 bs_solver.run_fixed_solver 會回傳 logs list
        logs = bs_solver.run_fixed_solver(config, boxes, commands, job_sequence)
        
        end_time = time.time()
        compute_time = end_time - start_time

        # 計算 Final Makespan
        # 找出所有任務中結束時間最晚的那個
        if logs:
            final_makespan = max(log.makespan for log in logs)
        else:
            final_makespan = -1.0  # 失敗

        # 顯示即時結果
        print(f"{bw:<10} | {final_makespan:<15.2f} | {compute_time:<20.4f}")

        # 儲存數據
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
    
    # 4. (選用) 簡單繪圖
    try:
        plt.figure(figsize=(10, 6))
        plt.plot(df['Beam_Width'], df['Makespan'], marker='o', linestyle='-', color='b')
        plt.title(f'Beam Width vs Makespan (AGV={FIXED_AGV_COUNT})')
        plt.xlabel('Beam Width')
        plt.ylabel('Makespan (seconds)')
        plt.grid(True)
        plt.savefig('bw_experiment_plot.png')
        print("Plot saved to bw_experiment_plot.png")
    except Exception as e:
        print("Skipping plot generation (matplotlib might be missing or error).")

if __name__ == "__main__":
    run_experiment()