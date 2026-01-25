import csv
import random

def generate_sequence_with_config(cfg):
    mission_cnt = cfg['mission_count']
    
    box_pos = {}   # bid -> (r, b, t)
    stacks = {}    # (r, b) -> [bid, bid, ...]
    
    # 1. 讀取剛剛產生的地圖
    with open('mock_yard.csv', 'r') as f:
        reader = csv.DictReader(f)
        for row in reader:
            bid, r, b, t = int(row['container_id']), int(row['row']), int(row['bay']), int(row['level'])
            box_pos[bid] = (r, b, t)
            stacks.setdefault((r, b), []).append(bid)
    
    for col in stacks:
        stacks[col].sort(key=lambda x: box_pos[x][2])

    # 2. 隨機選擇目標箱
    all_bids = list(box_pos.keys())
    target_bids = random.sample(all_bids, mission_cnt)
    
    target_stacks = {}
    for tid in target_bids:
        col = (box_pos[tid][0], box_pos[tid][1])
        target_stacks.setdefault(col, []).append(tid)
    
    for col in target_stacks:
        target_stacks[col].sort(key=lambda x: box_pos[x][2], reverse=True)

    # 3. 啟發式排序 (Score 越低越優先)
    def get_score(tid):
        r, b, t = box_pos[tid]
        dist = r + b
        blockers = len(stacks[(r, b)]) - 1 - t
        return dist + (blockers * 10)

    final_seq = []
    candidates = {col: stack.pop() for col in target_stacks if (stack := target_stacks[col])}

    while candidates:
        best_tid = min(candidates.values(), key=get_score)
        final_seq.append(best_tid)
        best_col = (box_pos[best_tid][0], box_pos[best_tid][1])
        if target_stacks.get(best_col):
            candidates[best_col] = target_stacks[best_col].pop()
        else:
            del candidates[best_col]

    # 4. 寫入 mock_commands.csv (含隨機 SKU 數量)
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
            
    print(f"Sequence generated: {len(final_seq)} jobs with dynamic SKUs.")
    return final_seq

# 保留舊接口
def generate_sequence():
    pass