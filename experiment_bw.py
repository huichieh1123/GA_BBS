import time
import csv
import pandas as pd
import matplotlib.pyplot as plt
import bs_solver  # 確保已經編譯好 (setup.py build_ext --inplace)

# --- 修改匯入部分 ---
from main import load_csv_data 
import gen_sequence 
import gen_yard

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
        # 確保地圖與序列已生成
        gen_yard.generate_yard()
        job_sequence = gen_sequence.generate_sequence()
        
        # [修正] 匹配 main.py 更新後的 4 個回傳值 (config, boxes, commands, sku_map)
        config, boxes, commands, sku_map = load_csv_data()
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
        # 設定 C++ 內部參數
        bs_solver.set_config(
            config['t_travel'],
            config['t_handle'],
            config['t_process'],
            FIXED_AGV_COUNT,
            bw
        )

        start_time = time.time()
        
        # [修正] 呼叫 solver 時傳入第 5 個參數 sku_map
        logs = bs_solver.run_fixed_solver(config, boxes, commands, job_sequence, sku_map)
        
        end_time = time.time()
        compute_time = end_time - start_time

        # 計算 Final Makespan
        if logs:
            # 獲取最後一個 log 的 makespan 作為最終完工時間
            final_makespan = logs[-1].makespan
        else:
            final_makespan = -1.0  # 模擬失敗標記

        # 顯示即時結果
        print(f"{bw:<10} | {final_makespan:<15.2f} | {compute_time:<20.4f}")

        # 儲存數據
        results.append({
            "Beam_Width": bw,
            "AGV_Count": FIXED_AGV_COUNT,
            "Makespan": final_makespan,
            "Compute_Time_Seconds": round(compute_time, 4),
            "Total_Missions": len(logs) if logs else 0
        })

    # 3. 寫入 CSV
    print("-" * 60)
    print(f"Saving results to {OUTPUT_CSV}...")
    
    df = pd.DataFrame(results)
    df.to_csv(OUTPUT_CSV, index=False)
    
    print("Done!")
    
    # 4. 繪圖
    # try:
    #     plt.figure(figsize=(10, 6))
    #     plt.plot(df['Beam_Width'], df['Makespan'], marker='o', linestyle='-', color='b')
    #     plt.title(f'Beam Width vs Makespan (AGV={FIXED_AGV_COUNT})')
    #     plt.xlabel('Beam Width')
    #     plt.ylabel('Makespan (seconds)')
    #     plt.grid(True)
    #     plt.savefig('bw_experiment_plot.png')
    #     print("Plot saved to bw_experiment_plot.png")
    # except Exception as e:
    #     print(f"Skipping plot generation: {e}")

if __name__ == "__main__":
    run_experiment()