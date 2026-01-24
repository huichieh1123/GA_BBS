import csv
import random
import re

def get_mission_count_from_cpp(file_path):
    with open(file_path, 'r', encoding='utf-8') as f:
        content = f.read()
        match = re.search(r'int\s+mission_count\s*=\s*(\d+);', content)
        return int(match.group(1)) if match else 50

def generate_sequence():
    # 1. 初始化設定與讀取地圖
    mission_cnt = get_mission_count_from_cpp('DataGenerator.cpp')
    workstation = (-1, -1)
    
    box_pos = {}   # bid -> (r, b, t)
    stacks = {}    # (r, b) -> [bid, bid, ...] (從底到頂)
    
    with open('mock_yard.csv', 'r') as f:
        reader = csv.DictReader(f)
        for row in reader:
            bid, r, b, t = int(row['container_id']), int(row['row']), int(row['bay']), int(row['level'])
            box_pos[bid] = (r, b, t)
            stacks.setdefault((r, b), []).append(bid)
    
    # 確保每根柱子按高度排序
    for col in stacks:
        stacks[col].sort(key=lambda x: box_pos[x][2])

    # 2. 挑選要處理的 50 個 Target (隨機挑選但數量同步)
    all_bids = list(box_pos.keys())
    targets = random.sample(all_bids, mission_cnt)
    target_set = set(targets)

    # 3. 定義 Rule-based 評分函式
    def get_score(tid):
        r, b, t = box_pos[tid]
        wbi, wui, wdi = [2.0, 5.0, 0.5]
        # Bi: 阻擋數 (上方有多少箱子)
        bi = sum(1 for o in stacks[(r, b)] if box_pos[o][2] > t)
        # Ui: 解鎖收益 (下方壓住了多少個其他目標箱)
        ui = sum(1 for o in stacks[(r, b)] if o in target_set and box_pos[o][2] < t)
        # Di: 到工作站 (-1, -1) 的距離
        di = abs(r - workstation[0]) + abs(b - workstation[1])
        
        # 綜合得分 = weight*阻擋 - weight*解鎖收益 + weight*距離
        return (wbi * bi) - (wui * ui) + (wdi * di)

    # 4. 根據柱子進行分組，並處理層級依賴 (Top-to-Bottom)
    target_stacks = {}
    for tid in targets:
        col = (box_pos[tid][0], box_pos[tid][1])
        target_stacks.setdefault(col, []).append(tid)
    
    # 每一根柱子內的目標箱必須「從上到下」排序
    for col in target_stacks:
        target_stacks[col].sort(key=lambda x: box_pos[x][2], reverse=True)

    # 5. 貪婪選取最優序列
    final_seq = []
    # 候選箱：每一根柱子中最上層的目標箱
    candidates = {col: s.pop(0) for col, s in target_stacks.items() if s}
    
    while candidates:
        # 在所有目前「可選」的目標箱中，挑選 Score 最低（最優先）的
        best_tid = min(candidates.values(), key=get_score)
        final_seq.append(best_tid)
        
        # 更新候選名單
        best_col = (box_pos[best_tid][0], box_pos[best_tid][1])
        if target_stacks[best_col]:
            candidates[best_col] = target_stacks[best_col].pop(0)
        else:
            del candidates[best_col]

    # 6. 產出符合 DataLoader 格式的 mock_commands.csv
    with open('mock_commands.csv', 'w', newline='') as f:
        writer = csv.writer(f)
        writer.writerow(["cmd_no", "batch_id", "cmd_type", "cmd_priority", "parent_carrier_id", "src_row", "src_bay", "src_level", "dst_row", "dst_bay", "dst_level", "create_time"])
        for i, tid in enumerate(final_seq):
            r, b, t = box_pos[tid]
            # cmd_priority 使用 i+1 以符合排序
            writer.writerow([i+1, 20260124, "target", i+1, tid, r, b, t, -1, -1, -1, 1705363200])

    print(f"sequence generated")
    return final_seq

if __name__ == "__main__":
    generate_sequence()