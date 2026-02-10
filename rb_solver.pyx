# distutils: language = c++
# cython: language_level=3

from libcpp.vector cimport vector
from libcpp.unordered_map cimport unordered_map
from libc.math cimport abs

cdef extern from "YardSystem.h":
    """
    #ifndef COORDINATE_DEFINED
    #define COORDINATE_DEFINED
    #include "YardSystem.h"
    struct Agent {
        int id;
        Coordinate currentPos;
        double availableTime;
    };
    #endif
    """
    struct Coordinate:
        int row
        int bay
        int tier
    struct Agent:
        int id
        Coordinate currentPos
        double availableTime

cdef extern from "YardSystem.h":
    cppclass YardSystem:
        YardSystem() nogil
        YardSystem(int rows, int bays, int tiers, int totalBoxes) nogil
        void initBox(int boxId, int r, int b, int t) nogil
        void moveBox(int r1, int b1, int r2, int b2) nogil
        void removeBox(int id) nogil
        Coordinate getBoxPosition(int id) nogil
        bint isTop(int id) nogil
        vector[int] getBlockingBoxes(int id) nogil
        bint canReceiveBox(int r, int b) nogil
        int MAX_ROWS, MAX_BAYS
        vector[vector[vector[int]]] grid
        vector[vector[int]] tops

cdef class PyMissionLog:
    cdef public int mission_no, agv_id, container_id, related_target_id
    cdef public str mission_type
    cdef public tuple src, dst
    cdef public long long start_time, end_time
    cdef public double makespan

def run_rb_solver(dict config, list boxes, list sequence, dict sku_map):
    cdef int i, r, b, t, k, a, p, targetId, blockerId, bestAgvIdx, bestPort, best_return_agv_idx
    cdef int box_id, target_count, path_length, tier_idx, min_target_count_so_far, min_path_so_far
    cdef double minPenalty, bestFinish, bestStart, start, finish, arrivalAtPort, processStart, portFinish, penalty, current_pickup_end
    cdef double best_return_finish, best_return_start, temp_finish_time, container_ready_time, travel_to_port, pickup_start, pickup_end, arrival_at_dst, dropoff_start
    cdef unordered_map[int, bint] remaining_targets_map
    cdef list potential_slots, best_class_slots
    cdef dict best_slot
    cdef double travel_to_src, travel_to_dst, pickupTime
    cdef double final_travel_to_src, final_pickupTime # Phase 2 變數
    cdef Coordinate src_coord, bestDst_coord
    cdef vector[int] blockers
    cdef bint found_slot
    
    # 系統初始化
    cdef YardSystem yard = YardSystem(config['max_row'], config['max_bay'], config['max_level'], config['total_boxes'])
    for box_item in boxes:
        yard.initBox(box_item['id'], box_item['row'], box_item['bay'], box_item['level'])
        
    cdef vector[int] c_seq
    for seq_item in sequence: c_seq.push_back(seq_item)
    cdef unordered_map[int, int] c_sku_map
    for sku_id, sku_val in sku_map.items(): c_sku_map[sku_id] = sku_val

    cdef int agvCount = config['agv_count']
    cdef int portCount = config['port_count']
    cdef double w_lookahead = config['w_penalty_lookahead']
    cdef double t_travel = config['t_travel']
    cdef double t_handle = config['t_handle']
    cdef double t_process = config['t_process']
    cdef double t_pick = config['t_pick']
    cdef long long sim_start = config['sim_start_epoch']

    cdef unordered_map[int, double] containerAvailableTime 
    cdef vector[double] portBusyTime
    portBusyTime.resize(portCount + 1, 0.0)
    cdef vector[vector[double]] gridBusyTime
    gridBusyTime.resize(yard.MAX_ROWS, vector[double](yard.MAX_BAYS, 0.0))
    
    cdef vector[Agent] agvs
    cdef Agent tmp_agv
    for i in range(agvCount):
        tmp_agv.id = i
        tmp_agv.currentPos = Coordinate(0, 0, 0)
        tmp_agv.availableTime = 0.0
        agvs.push_back(tmp_agv)

    cdef list py_logs = []

    # 任務主迴圈
    for i in range(c_seq.size()):
        targetId = c_seq[i]

        # Create a set of remaining targets for efficient lookup
        remaining_targets_map.clear()
        for k in range(i, c_seq.size()):
            remaining_targets_map[c_seq[k]] = True

        # Phase 1: Reshuffle (翻堆)
        while not yard.isTop(targetId):
            blockers = yard.getBlockingBoxes(targetId)
            if blockers.empty(): break
            blockerId = blockers.back()
            src_coord = yard.getBoxPosition(blockerId)
            if src_coord.row == -1: break 

            # 尋找暫存位... (此處邏輯不變)
            bestDst_coord = Coordinate(-1, -1, -1)
            minPenalty = 1e18
            for r in range(yard.MAX_ROWS):
                for b in range(yard.MAX_BAYS):
                    if r == src_coord.row and b == src_coord.bay: continue
                    if not yard.canReceiveBox(r, b): continue
                    penalty = 0
                    t = yard.tops[r][b]
                    if t > 0:
                        for k in range(i, c_seq.size()):
                            if c_seq[k] == yard.grid[r][b][t-1]:
                                penalty = w_lookahead / <double>(k - i + 1)
                                break
                    if penalty < minPenalty:
                        minPenalty = penalty; bestDst_coord = Coordinate(r, b, t)

            # 修正 (Reshuffle) 
            bestFinish = 1e18
            bestAgvIdx = -1
            for a in range(agvCount):
                # 1. 提前出發時間
                start_move = max(agvs[a].availableTime, containerAvailableTime[blockerId])
                # 2. 抵達起點並等待
                at_src = start_move + (abs(agvs[a].currentPos.row - src_coord.row) + abs(agvs[a].currentPos.bay - src_coord.bay)) * t_travel
                pickup_start = max(at_src, gridBusyTime[src_coord.row][src_coord.bay])
                pickup_end = pickup_start + t_handle
                # 3. 搬運至終點並等待
                at_dst = pickup_end + (abs(src_coord.row - bestDst_coord.row) + abs(src_coord.bay - bestDst_coord.bay)) * t_travel
                dropoff_start = max(at_dst, gridBusyTime[bestDst_coord.row][bestDst_coord.bay])
                finish = dropoff_start + t_handle
                
                if finish < bestFinish:
                    bestFinish = finish; bestAgvIdx = a; bestStart = start_move
                    pickupTime = pickup_end # 箱子離開貨架的時刻 (50s)

            # 執行 Reshuffle
            yard.moveBox(src_coord.row, src_coord.bay, bestDst_coord.row, bestDst_coord.bay)
            agvs[bestAgvIdx].availableTime = bestFinish
            agvs[bestAgvIdx].currentPos = bestDst_coord
            containerAvailableTime[blockerId] = bestFinish 
            gridBusyTime[src_coord.row][src_coord.bay] = pickupTime # 50s 釋放起點
            gridBusyTime[bestDst_coord.row][bestDst_coord.bay] = bestFinish
            
            pl = PyMissionLog()
            pl.mission_no = len(py_logs) + 1; pl.agv_id = bestAgvIdx; pl.mission_type = "reshuffle"
            pl.container_id = blockerId; pl.related_target_id = targetId
            pl.src = (src_coord.row, src_coord.bay, src_coord.tier); pl.dst = (bestDst_coord.row, bestDst_coord.bay, bestDst_coord.tier)
            pl.start_time = <long long>(bestStart + sim_start); pl.end_time = <long long>(bestFinish + sim_start); pl.makespan = bestFinish
            py_logs.append(pl)

        # Phase 2: Target Retrieval (出庫)
        src_coord = yard.getBoxPosition(targetId)
        if src_coord.row == -1: continue

        final_travel_to_src = 0.0 # 此處保留原變數名
        final_pickupTime = 0.0
        bestFinish = 1e18
        bestPort = 1
        bestAgvIdx = 0
        bestStart = 0.0

        for a in range(agvCount):
            for p in range(1, portCount + 1):
                # 1. 提前出發
                start_move = max(agvs[a].availableTime, containerAvailableTime[targetId])
                # 2. 抵達起點與等待
                at_src = start_move + (abs(agvs[a].currentPos.row - src_coord.row) + abs(agvs[a].currentPos.bay - src_coord.bay)) * t_travel
                pickup_start = max(at_src, gridBusyTime[src_coord.row][src_coord.bay])
                pickup_end = pickup_start + t_handle
                # 3. 搬運至 Port 與等待
                at_port = pickup_end + (abs(src_coord.row - (-1)) + abs(src_coord.bay - (-1))) * t_travel
                processStart = max(at_port, portBusyTime[p])
                finish_dropoff = processStart + t_handle # 這是 AGV 自由的時刻 (140s)
                
                # 計算 Picking 完工時間供 Phase 3 使用
                portFinish = finish_dropoff + t_process + c_sku_map[targetId] * t_pick
                
                if portFinish < bestFinish:
                    bestFinish = portFinish
                    bestAgvIdx = a
                    bestPort = p
                    bestStart = start_move
                    final_pickupTime = finish_dropoff # End_s = 140
                    current_pickup_end = pickup_end # 80s

        yard.removeBox(targetId)
        agvs[bestAgvIdx].availableTime = final_pickupTime 
        agvs[bestAgvIdx].currentPos = Coordinate(-1, -1, bestPort)
        containerAvailableTime[targetId] = bestFinish 
        portBusyTime[bestPort] = bestFinish
        gridBusyTime[src_coord.row][src_coord.bay] = current_pickup_end # 80s 釋放起點
        
        pl = PyMissionLog()
        pl.mission_no = len(py_logs) + 1; pl.agv_id = bestAgvIdx; pl.mission_type = "target"
        pl.container_id = targetId; pl.related_target_id = targetId
        pl.src = (src_coord.row, src_coord.bay, src_coord.tier); pl.dst = (-1, -1, bestPort)
        pl.start_time = <long long>(bestStart + sim_start)
        pl.end_time = <long long>(final_pickupTime + sim_start)
        pl.makespan = final_pickupTime
        py_logs.append(pl)

        # Phase 3: Return (回庫)
        # New single-pass logic to find the best destination slot
        best_slot = {}
        min_target_count_so_far = 100000
        min_path_so_far = 100000

        # 1. Analyze all possible destination stacks in a single pass
        for r in range(yard.MAX_ROWS):
            for b in range(yard.MAX_BAYS):
                if yard.canReceiveBox(r, b):
                    # Calculate metrics for the current candidate slot
                    target_count = 0
                    t = yard.tops[r][b]
                    if t > 0:
                        for tier_idx in range(t):
                            box_id = yard.grid[r][b][tier_idx]
                            if remaining_targets_map.count(box_id):
                                target_count += 1
                    
                    path_length = r + b + 2 # Simplified Manhattan distance from port at (-1, -1)

                    # Inline decision making
                    if target_count < min_target_count_so_far:
                        # Found a new, better class of slots. This is the new champion.
                        min_target_count_so_far = target_count
                        min_path_so_far = path_length
                        best_slot = {'r': r, 'b': b, 't': t}
                    elif target_count == min_target_count_so_far:
                        # Same class, check the tie-breaker (path length)
                        if path_length < min_path_so_far:
                            # Better path length, this is the new champion in this class.
                            min_path_so_far = path_length
                            best_slot = {'r': r, 'b': b, 't': t}
        
        bestDst_coord = Coordinate(-1, -1, -1)
        if best_slot:
            bestDst_coord = Coordinate(best_slot['r'], best_slot['b'], best_slot['t'])

        # Find the best AGV for the return trip, only if a destination was found
        if bestDst_coord.row != -1:
            best_return_finish = 1e18
            best_return_agv_idx = -1
            best_return_start = 0.0

            container_ready_time = portBusyTime[bestPort]

            for a in range(agvCount):
                travel_to_port = (abs(agvs[a].currentPos.row - (-1)) + abs(agvs[a].currentPos.bay - (-1))) * t_travel
                arrival_at_port = agvs[a].availableTime + travel_to_port
                pickup_start = max(arrival_at_port, container_ready_time)
                pickup_end = pickup_start + t_handle
                travel_to_dst = (abs((-1) - bestDst_coord.row) + abs((-1) - bestDst_coord.bay)) * t_travel
                arrival_at_dst = pickup_end + travel_to_dst
                dropoff_start = max(arrival_at_dst, gridBusyTime[bestDst_coord.row][bestDst_coord.bay])
                temp_finish_time = dropoff_start + t_handle

                if temp_finish_time < best_return_finish:
                    best_return_finish = temp_finish_time
                    best_return_agv_idx = a
                    best_return_start = pickup_start - travel_to_port
            
            if best_return_agv_idx != -1:
                yard.initBox(targetId, bestDst_coord.row, bestDst_coord.bay, bestDst_coord.tier)
                agvs[best_return_agv_idx].availableTime = best_return_finish
                agvs[best_return_agv_idx].currentPos = bestDst_coord
                containerAvailableTime[targetId] = best_return_finish 
                gridBusyTime[bestDst_coord.row][bestDst_coord.bay] = best_return_finish
                
                pl = PyMissionLog()
                pl.mission_no = len(py_logs) + 1
                pl.agv_id = best_return_agv_idx
                pl.mission_type = "return"
                pl.container_id = targetId
                pl.related_target_id = targetId
                pl.src = (-1, -1, bestPort)
                pl.dst = (bestDst_coord.row, bestDst_coord.bay, bestDst_coord.tier)
                pl.start_time = <long long>(best_return_start + sim_start)
                pl.end_time = <long long>(best_return_finish + sim_start)
                pl.makespan = best_return_finish
                py_logs.append(pl)

    return py_logs