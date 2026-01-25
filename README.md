# Multi-Agent Time-Optimized BRP Solver using Beam Search with Front Rule Pruning

## 1. 系統概述 (System Overview)

本系統旨在解決多台 AGV 在貨櫃堆場中的 **翻箱問題 (Block Relocation Problem, BRP)**。目標不再是最小化步數，而是最小化 **最大完工時間 (Makespan)**。系統採用 Beam Search 作為搜尋骨幹，並引入排程理論中的 Front Rule 進行節點剪枝，以處理 3 台 AGV 的協同作業效率。

---

## 2. 物理模型與參數定義 (Physics & Parameters)

### 2.1 時間常數 (Time Constants)

所有成本計算皆以「秒 (Seconds)」為單位。

* **`TIME_TRAVEL_UNIT`**: AGV 移動一格 (Row 或 Bay) 所需時間。
* 預設: 5.0 秒/格。


* **`TIME_HANDLE`**: 包含對準、抓取、垂直起降、釋放的總固定時間。
* 預設: 30.0 秒/次。


* **`TIME_PROCESS`**: 貨櫃抵達 Workstation 後的處理/交接時間（AGV 需等待）。
* 預設: 10.0 秒/次。



### 2.2 距離計算 (Distance Calculation)

採用曼哈頓距離 (Manhattan Distance) 簡化計算，忽略加減速與轉彎。


---

## 3. 資料結構設計 (Data Structures)

### 3.1 代理人狀態 (Agent State)

每一台 AGV 獨立維護其狀態，用於計算最早可用時間 (Earliest Available Time)。

```cpp
struct Agent {
    int id;                 // 0, 1, 2
    Coordinate currentPos;  // 目前所在座標 (r, b, l)
    double availableTime;   // 該 AGV 完成當前任務並變成閒置的時間點
};

```

### 3.2 搜尋節點 (Search Node)

Beam Search 中的每一個節點代表一個「部分完成的排程狀態」。

```cpp
struct SearchNode {
    // --- 狀態資訊 ---
    YardSystem yard;              // 當前的 3D 堆場快照
    std::vector<Agent> agvs;      // 3 台 AGV 的狀態
    
    // --- 成本資訊 ---
    double g; // Current Makespan = max(agv[0].time, agv[1].time, agv[2].time)
    double h; // Heuristic: 預估還需要多少時間才能搬完所有 Target
    double f; // Total Score = g + h
    
    // --- 排程歷程 (用於 Front Rule) ---
    // 紀錄導致來到此狀態的「最後 3 個任務分配」
    // 用於檢查是否可以交換任務來優化時間
    struct LastTask {
        int agentId;
        int boxId;
        double finishTime;
    };
    std::vector<LastTask> frontTasks; 

    // 用於排序
    bool operator<(const SearchNode& other) const { return f < other.f; }
};

```

---

## 4. 核心演算法邏輯 (Core Algorithm Logic)

### 4.1 主流程 (Main Loop)

保持 GA 產生 Target 順序 (`target_sequence`) 的架構不變。
BBS Evaluator 修改為以下邏輯：

1. **初始化**：Root Node 的 `g = 0`，3 台 AGV `availableTime = 0`。
2. **層級遍歷 (Layer-by-Layer)**：
* 按照 `target_sequence` 順序，一次處理一個 Target。
* **注意**：處理一個 Target 可能包含多個步驟 (移開阻擋 A -> 移開阻擋 B -> 取 Target)。這些步驟視為同一層的子步驟或展開為多層。


3. **展開 (Expansion)**：
* 找出當前必須移動的箱子 (Top Blocker 或 Target 本身)。
* 生成所有可能的 **目的地 (Destinations)** (場內空位)。
* 生成所有可能的 **AGV 指派 (Assignments)** (哪台車去搬)。


4. **評估與剪枝 (Evaluation & Pruning)**：
* 計算 。
* 應用 **Front Rule** 進行剪枝。
* 保留最好的 `BEAM_WIDTH` 個節點進入下一層。



### 4.2 啟發式函數 (LB Calculation - 3D Grid Based)

這是您的 **3D UBALB (Utilization-Based Adjusted Lower Bound)**，用於估算 。

其中  計算方式：

1. **3D 掃描**：遍歷整個 Grid。
2. **必要移動成本**：
* 對於所有尚未取出的 Target ，計算 。
* 對於壓在 Target  上方的所有阻擋箱 ，計算 。


3. **加總與平均**：將所有  加總，除以 3 (AGV 數量)，因為理想情況下 3 台車會完美分工。

### 4.3 任務指派策略 (Greedy Dispatching)

在展開節點時，針對一個特定的搬運任務 (Job)，如何決定由哪台 AGV 執行？

* **規則**：選擇 **完工時間 (Completion Time)** 最早的 AGV。


* ：如果是移開阻擋箱，該箱子隨時可搬。如果是取 Target，需等上面的阻擋箱被移完。



---

## 5. Front Rule 優化與剪枝 (Front Rule Optimization)

這是本規格書的核心優化技術，源自 *Parallel Machine Scheduling* 理論。

### 5.1 邏輯定義

在 Beam Search 產生一個新節點 (New Node) 後，檢查該節點的 **前緣任務 (Front Tasks)**。

* 假設剛執行完的三個任務分別是：
*  由  執行，耗時 
*  由  執行，耗時 
*  由  執行，耗時 



### 5.2 執行步驟

1. **提取**：從 Node 中取得最近指派給 3 台 AGV 的任務 。
2. **排列 (Permutation)**：產生  種分配組合。
* Case 1:  (原案)
* Case 2: 
* ...


3. **模擬驗證**：針對每一種組合，快速計算完工時間。
* 檢查 **物理限制**：是否違反干涉？(本規格暫忽略細微路徑干涉，僅檢查時間)。
* 檢查 **相依性**：這三個任務是否有順序關係？(若 A 擋住 B，則 B 不能比 A 早做)。


4. **支配檢查 (Dominance Check)**：
* 如果發現某個 Case 的  **小於** 原案的 。
* 或者 Makespan 相同，但總機器運轉時間更短。


5. **剪枝決策**：
* 如果存在優勢排列，則標記當前 Node 為 **Dominated**。
* **Action**: 在 Beam Search 的篩選階段，直接丟棄 Dominated Nodes，或是用優化後的狀態取代當前節點。



---

## 6. 輸入輸出規範 (I/O Specification)

### 6.1 輸入 (Input)

* **`yard_config.csv`**: 讀取 `max_row`, `max_bay`, `max_level` 以初始化 3D Array。
* **`mock_yard.csv`**: 初始箱子位置。
* **`mock_commands.csv`**: 任務列表。

### 6.2 輸出 (Output)

`output_missions.csv` 需增加 AGV 編號與詳細時間戳記。

| Column | Description |
| --- | --- |
| `mission_no` | 1, 2, 3... |
| `agv_id` | **[NEW]** 執行此任務的 AGV (0, 1, 2) |
| `container_id` | 箱號 |
| `type` | target / reshuffle |
| `src_pos` | (r;b;l) |
| `dst_pos` | (r;b;l) or workstation |
| `start_time` | **[NEW]** AGV 開始移動的時間 |
| `end_time` | **[NEW]** AGV 完成動作的時間 |
| `makespan` | 當前系統的 Global Makespan |

---

## 7. 偽程式碼 (Pseudo-Code) for Beam Search Step

```cpp
function expand_beam(current_beam):
    next_beam = []
    
    for node in current_beam:
        // 1. Identify next logical task (e.g., move top blocker of current target)
        task = get_next_task(node)
        
        // 2. Try all valid destinations (for reshuffling)
        for dest in valid_slots(node.yard):
            
            // 3. Try assigning to each AGV (Greedy dispatch initially)
            best_agv = find_earliest_agv(node.agvs, task, dest)
            
            new_node = simulate_move(node, best_agv, task, dest)
            
            // 4. Calculate Costs
            new_node.g = max(agv.availableTime for agv in new_node.agvs)
            new_node.h = calculate_3D_UBALB(new_node.yard)
            new_node.f = new_node.g + new_node.h
            
            // 5. Apply Front Rule Check
            if check_front_rule_dominance(new_node):
                continue // Prune this node immediately
            
            next_beam.push(new_node)
            
    // 6. Sort by f and keep top K
    return select_top_k(next_beam, BEAM_WIDTH)

```
## 8. 編譯指令
```
pip install setuptools numpy cython pandas matplotlib

python setup.py build_ext --inplace

python main.py
```
##2026/01/25 新增優化邏輯
AGV 在將貨櫃送達 Port 並執行放下動作（TIME_HANDLE）後立即釋放，不再於原位等待 $5n$ 秒的揀貨時間。
根據 mock_commands.csv 中的 sku_qty 欄位，系統會動態計算每個貨櫃的揀貨耗時（$Duration = SKU \times 5.0s$）
AGV 獲得自由後，可利用工作站揀貨的空窗期，執行其他任務（如翻箱 Reshuffle 或搬運下一個目標箱），將原本的「無效等待時間」轉化為「有效作業時間」。
