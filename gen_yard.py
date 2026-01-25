import csv
import random

def generate_yard_with_config(cfg):
    # 1. 整理參數
    config = {
        'max_row': cfg['max_row'],
        'max_bay': cfg['max_bay'],
        'max_level': cfg['max_level'],
        'total_boxes': cfg['total_boxes'],
        'time_travel_unit': cfg['t_travel'],
        'time_handle': cfg['t_handle'],
        'time_process': cfg['t_process']
    }

    R, B, L = config['max_row'], config['max_bay'], config['max_level']
    total_boxes = config['total_boxes']

    # 2. 產出 yard_config.csv
    with open('yard_config.csv', 'w', newline='') as f:
        writer = csv.DictWriter(f, fieldnames=config.keys())
        writer.writeheader()
        writer.writerow(config)

    # 3. 隨機生成堆場分佈
    all_columns = [(r, b) for r in range(R) for b in range(B)]
    column_heights = {col: 0 for col in all_columns}
    
    current_count = 0
    while current_count < total_boxes:
        col = random.choice(all_columns)
        if column_heights[col] < L:
            column_heights[col] += 1
            current_count += 1

    # 4. 寫入 mock_yard.csv
    box_id = 1
    with open('mock_yard.csv', 'w', newline='') as f:
        writer = csv.writer(f)
        writer.writerow(["container_id", "row", "bay", "level"])
        for col, height in column_heights.items():
            for l in range(height):
                writer.writerow([box_id, col[0], col[1], l])
                box_id += 1
    
    print(f"Yard generated: size {R}x{B}x{L}, boxes: {total_boxes}")

# 保留舊接口以防萬一
def generate_yard():
    pass