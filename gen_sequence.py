import csv
import random
import re

def get_mission_count_from_cpp(file_path):
    """從 C++ 檔案中同步任務數量設定"""
    try:
        with open(file_path, 'r', encoding='utf-8') as f:
            content = f.read()
            match = re.search(r'int\s+mission_count\s*=\s*(\d+);', content)
            return int(match.group(1)) if match else 50
    except FileNotFoundError:
        return 50

def generate_sequence_with_config(cfg):
    # 優先從 cfg 讀取數量，若無則從 CPP 同步
    mission_cnt = cfg.get('mission_count')
    if mission_cnt is None:
        mission_cnt = get_mission_count_from_cpp('DataGenerator.cpp')
    
    box_pos = {}   # bid -> (r, b, t)
    stacks = {}    # (r, b) -> [bid, bid, ...]
    workstation = (-1, -1)
    
    # 1. 讀取地圖
    with open('mock_yard.csv', 'r') as f:
        reader = csv.DictReader(f)
        for row in reader:
            bid, r, b, t = int(row['container_id']), int(row['row']), int(row['bay']), int(row['level'])
            box_pos[bid] = (r, b, t)
            stacks.setdefault((r, b), []).append(bid)
    
    for col in stacks:
        stacks[col].sort(key=lambda x: box_pos[x][2])

    # 2. 挑選目標箱並建立集合 (用於計算解鎖收益)
    all_bids = list(box_pos.keys())
    target_bids = random.sample(all_bids, mission_cnt)
    target_set = set(target_bids)
    
    target_stacks = {}
    for tid in target_bids:
        col = (box_pos[tid][0], box_pos[tid][1])
        target_stacks.setdefault(col, []).append(tid)
    
    # 強制執行「由上至下」的出庫順序依賴
    for col in target_stacks:
        target_stacks[col].sort(key=lambda x: box_pos[x][2], reverse=True)

    # 3. 新版 Rule-based 評分函式 (關鍵計算部分)
    def get_score(tid):
        r, b, t = box_pos[tid]
        wbi, wui, wdi = [2.0, 5.0, 0.5]
        
        # Bi: 阻擋數 (上方壓著的總箱數)
        bi = sum(1 for o in stacks[(r, b)] if box_pos[o][2] > t)
        
        # Ui: 解鎖收益 (下方壓住了多少個「也是目標」的箱子)
        ui = sum(1 for o in stacks[(r, b)] if o in target_set and box_pos[o][2] < t)
        
        # Di: 到工作站的曼哈頓距離
        di = abs(r - workstation[0]) + abs(b - workstation[1])
        
        # 綜合得分，分數越低優先權越高
        return (wbi * bi) - (wui * ui) + (wdi * di)

    # 4. 根據評分貪婪選取最優序列
    final_seq = []
    candidates = {col: s.pop(0) for col, s in target_stacks.items() if s}

    while candidates:
        best_tid = min(candidates.values(), key=get_score)
        final_seq.append(best_tid)
        
        best_col = (box_pos[best_tid][0], box_pos[best_tid][1])
        if target_stacks.get(best_col):
            candidates[best_col] = target_stacks[best_col].pop(0)
        else:
            del candidates[best_col]

    # 5. 寫入指令檔 (保留原本的 SKU 隨機邏輯)
    with open('mock_commands.csv', 'w', newline='') as f:
        writer = csv.writer(f)
        writer.writerow(["cmd_no", "batch_id", "cmd_type", "cmd_priority", "parent_carrier_id", 
                         "src_row", "src_bay", "src_level", "dest_row", "dest_bay", "dest_level", 
                         "create_time", "sku_qty"])
        
        baseTime = 1705363200
        for i, tid in enumerate(final_seq):
            r, b, t = box_pos[tid]
            sku_qty = random.randint(1, 30)
            writer.writerow([i+1, 20260124, "target", i+1, tid, r, b, t, -1, -1, -1, baseTime, sku_qty])
            
    print(f"Sequence generated: {len(final_seq)} jobs with advanced rule-based scoring.")
    return final_seq

def generate_sequence():
    # 預設呼叫接口
    return generate_sequence_with_config({'mission_count': 50})

if __name__ == '__main__':
    generate_sequence()