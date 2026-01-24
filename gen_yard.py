import csv
import random
import re

def get_config_from_cpp(file_path):
    config = {}
    with open(file_path, 'r', encoding='utf-8') as f:
        content = f.read()
        patterns = {
            'max_row': r'int\s+max_row\s*=\s*(\d+);',
            'max_bay': r'int\s+max_bay\s*=\s*(\d+);',
            'max_level': r'int\s+max_level\s*=\s*(\d+);',
            'total_boxes': r'int\s+total_boxes\s*=\s*(\d+);'
        }
        for key, pattern in patterns.items():
            match = re.search(pattern, content)
            if match:
                config[key] = int(match.group(1))
    return config

def generate_yard():
    # 1. 獲取參數
    config = get_config_from_cpp('DataGenerator.cpp')
    if not config:
        print("無法讀取 DataGenerator.cpp 的參數，請確認檔案路徑。")
        return

    R, B, L = config['max_row'], config['max_bay'], config['max_level']
    total_boxes = config['total_boxes']

    # 2. 產出 yard_config.csv (供演算法主程式讀取)
    with open('yard_config.csv', 'w', newline='') as f:
        writer = csv.DictWriter(f, fieldnames=config.keys())
        writer.writeheader()
        writer.writerow(config)

    # 3. 產出 mock_yard.csv (符合物理堆疊)
    # 邏輯：先隨機分配每根柱子要堆多高，直到總數達到 400
    all_columns = [(r, b) for r in range(R) for b in range(B)]
    column_heights = {col: 0 for col in all_columns}
    
    current_count = 0
    while current_count < total_boxes:
        col = random.choice(all_columns)
        if column_heights[col] < L:
            column_heights[col] += 1
            current_count += 1

    # 4. 根據高度分配 ID 並寫入檔案
    box_id = 1
    with open('mock_yard.csv', 'w', newline='') as f:
        writer = csv.writer(f)
        writer.writerow(["container_id", "row", "bay", "level"])
        for col, height in column_heights.items():
            for level in range(height):
                # 這裡確保每一層(level)都是連續的，從 0 開始往上填
                writer.writerow([box_id, col[0], col[1], level])
                box_id += 1

    print(f"yard generated")
    print(f"size ：{R}x{B}x{L}, container_num: {total_boxes}")

if __name__ == "__main__":
    generate_yard()