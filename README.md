# 貨櫃堆場搬運優化系統 (Container Yard Relocation Optimizer)

本專案是一個針對貨櫃堆場（Container Yard）翻箱問題（Block Relocation Problem, BRP）的優化求解器。系統結合了 **基因演算法 (Genetic Algorithm, GA)** 與 **分支搜尋 (Beam Search)**，旨在找出最優的貨櫃出庫順序與搬運路徑，以最小化不必要的翻箱動作（Reshuffles）。

##  專案特色

* **混合演算法 (Hybrid Algorithm)**：利用 GA 優化「出庫順序」，並利用 Beam Search 優化「搬運路徑」。
* **前瞻性懲罰機制 (Lookahead Penalty)**：在移動阻擋貨櫃或放回目標貨櫃時，會檢查是否壓住「未來即將出庫的目標」，有效避免二次搬運。
* **動態環境適應**：Solver 會自動讀取 Generator 產生的設定檔 (`yard_config.csv`)，自動適應不同大小的堆場 (2x2x2, 6x11x8 等)。
* **詳細任務日誌**：輸出包含時間戳記、來源/目的座標、任務類型的詳細 CSV 報表。

##  檔案結構

### 核心程式碼

* **`main.cpp`** (Solver): 主程式。包含 GA 演算法、BBS 評估器 (BBS_Evaluator)、以及核心搬運邏輯。
* **`DataGenerator.cpp`**: 資料生成器。用於產生隨機的堆場佈局 (Layout) 與出庫任務 (Missions)。
* **`YardSystem.h`**: 定義堆場的資料結構 (3D Grid) 與基本操作 (Move, Remove, Init)。
* **`DataLoader.h`**: 負責讀取 CSV 檔案與設定檔。

### 資料檔案 (由 Generator 產生)

* **`mock_yard.csv`**: 堆場的初始狀態快照 (Inventory)。
* **`mock_commands.csv`**: 需要執行的出庫任務清單。
* **`yard_config.csv`**: 紀錄堆場的長寬高與總箱數設定。
* **`output_missions.csv`**: (由 Solver 產生) 最終優化後的詳細搬運指令。

---

##  快速開始 (Quick Start)


### 1. 編譯程式

我們需要分別編譯「資料生成器」與「求解器」。

```bash
# 編譯生成器
g++ DataGenerator.cpp -o generator

# 編譯求解器 (建議開啟 -O3 優化以加快運算速度)
g++ main.cpp -o solver -O3

```

### 2. 生成測試資料

您可以直接執行生成器使用預設值，或是手動指定參數。

**模式 A：使用預設值 (6排 x 11列 x 8層, 400箱, 50個任務)**

```bash
./generator

```

**模式 B：自訂場景大小 (例如：2排 x 2列 x 2層, 4個箱子, 2個任務)**
*參數順序：Rows Bays Levels TotalBoxes MissionCount*

```bash
./generator 2 2 2 4 2

```

> **注意**：執行後會產生 `mock_yard.csv`, `mock_commands.csv` 和 `yard_config.csv`。

### 3. 執行優化求解

執行主程式，它會自動讀取上述產生的 CSV 檔案並開始運算。

```bash
./solver

```

程式執行完畢後，螢幕上會顯示優化前後的 Cost 比較與進步幅度。詳細的搬運步驟會寫入 `output_missions.csv`。

---

##  演算法邏輯細節

### 1. 基因演算法 (GA)

* **染色體 (Individual)**：代表一種「出庫順序 (Retrieval Sequence)」。
* **適應度 (Fitness)**：該順序所需的總搬運步數 (由 BBS Evaluator 計算)。
* **演化操作**：使用 Tournament Selection 選擇親代，並透過 Mutation (隨機交換順序) 產生子代。

### 2. 分支搜尋 (Beam Search)

用於評估一個特定的出庫順序所需的最小步數。

* **Phase 1 (Outbound)**：將目標箱移至工作站。若有阻擋箱，會嘗試移至場內其他空位。
* **Phase 2 (Inbound)**：目標箱處理完畢後，需放回場內（模擬查驗或暫存後回庫）。

### 3. 關鍵啟發式規則 (Heuristics)

為了避免 Beam Search 陷入短視近利的決策，我們引入了 **Lookahead Penalty**：

* **移動阻擋箱時**：若將阻擋箱移到「未來即將出庫的目標」上方，給予極大懲罰。
* **放回目標箱時**：若將目標箱放回「未來即將出庫的目標」上方，給予極大懲罰。
* **Break Tie**：若所有位置都不理想，優先選擇壓在「最晚才要出庫」的箱子上。

---

##  輸出格式說明 (`output_missions.csv`)

| 欄位 | 說明 | 範例 |
| --- | --- | --- |
| **mission_no** | 任務流水號 | 1 |
| **mission_type** | 任務類型 (target: 取貨, block: 移阻擋物, return: 放回) | target |
| **batch_id** | 批次編號 | 20260117 |
| **parent_carrier_id** | container ID | 4 |
| **source_position** | 起始位置 (row;bay;level) 或 work station | (1;0;1) |
| **dest_position** | 目的位置 (row;bay;level) 或 work station | work station |
| **mission_priority** | 執行優先級 | 1 |
| **mission_status** | 狀態 | PLANNED |
| **created_time** | 模擬建立時間 (Unix Timestamp) | 1705363200 |

- work station用 (-1, -1, -1) 代表

---

##  開發環境

* **語言**: C++ (C++11 或更高版本)
* **編譯器**: g++ (MinGW on Windows, GCC on Linux/Mac)
* **依賴**: 標準庫 (STL)

##  References

- Wu, K. C., & Ting, C. J. (2010). A beam search algorithm for minimizing reshuffle operations at container yards. In Proceedings of the 2010 International Conference on Logistics and Maritime Systems, Busan, Korea.
- Bacci, T., Mattia, S., & Ventura, P. (2019). The bounded beam search algorithm for the block relocation problem. Computers & Operations Research, 103, 252–264.
- Gulić, M., Maglić, L., Krljan, T., & Maglić, L. (2022). Solving the Container Relocation Problem by Using a Metaheuristic Genetic Algorithm. Applied Sciences, 12(15), 7397.