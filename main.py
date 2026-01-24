import csv
import time
import bs_solver  # 確保已經編譯好
from gen_yard import generate_yard
from gen_sequence import generate_sequence

def load_csv_data():
    """載入最新的地圖設定、貨櫃位置與任務清單"""
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

def main():
    # --- 保留先前改過的自動同步內容 ---
    generate_yard()
    generate_sequence() 

    config, boxes, commands = load_csv_data()

    # 自動獲取剛產出的 Rule-based 序列
    job_sequence = [cmd['id'] for cmd in commands if cmd['type'] == 'target']

    print(f"size : {config['max_row']}x{config['max_bay']}x{config['max_level']}")
    print(f"opt seq , mission : {len(job_sequence)}")

    start_cpu_time = time.time()
    # 執行 C++ 核心運算
    logs = bs_solver.run_fixed_solver(config, boxes, commands, job_sequence)
    end_cpu_time = time.time()

    # --- Step 4: 修正後的 CSV 輸出 (恢復所有參數與格式) ---
    output_file = 'output_missions_python.csv'
    with open(output_file, 'w', newline='') as f:
        writer = csv.writer(f)
        # 恢復完整欄位
        writer.writerow([
            "mission_no", "agv_id", "mission_type", "container_id", 
            "related_target_id", "src_pos", "dst_pos", "start_time", "end_time", "makespan"
        ])
        
        final_makespan = 0
        for log in logs:
            # 恢復原始 Workstation Port 顯示邏輯
            if log.src[0] == -1:
                s_str = f"work station (Port {log.src[2]})"
            else:
                s_str = f"({log.src[0]};{log.src[1]};{log.src[2]})"
            
            if log.dst[0] == -1:
                d_str = f"work station (Port {log.dst[2]})"
            else:
                d_str = f"({log.dst[0]};{log.dst[1]};{log.dst[2]})"

            writer.writerow([
                log.mission_no,
                log.agv_id,
                log.mission_type,
                log.container_id,
                log.related_target_id, 
                s_str,
                d_str,
                log.start_time,        
                log.end_time,          
                log.makespan
            ])
            final_makespan = max(final_makespan, log.makespan)

    print(f"save in : {output_file}")

if __name__ == "__main__":
    main()