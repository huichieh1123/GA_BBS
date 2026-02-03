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
    cdef int i, r, b, t, k, a, p, targetId, blockerId, bestAgvIdx, bestPort
    cdef double minPenalty, bestFinish, bestStart, start, finish, arrivalAtPort, processStart, portFinish, penalty
    cdef double travel_to_src, travel_to_dst, pickupTime
    cdef Coordinate src_coord, bestDst_coord
    cdef vector[int] blockers
    
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

    for i in range(c_seq.size()):
        targetId = c_seq[i]

        # Phase 1: Reshuffle
        while not yard.isTop(targetId):
            blockers = yard.getBlockingBoxes(targetId)
            if blockers.empty(): break
            blockerId = blockers.back()
            src_coord = yard.getBoxPosition(blockerId)
            
            # 若貨櫃不在場地內(row==-1)，代表邏輯出錯或該櫃正在回庫途中，強制跳過
            if src_coord.row == -1: break 

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

            bestFinish = 1e18
            bestAgvIdx = -1
            for a in range(agvCount):
                # 同步 BS 邏輯：必須等待 (AGV, 貨櫃, 起點儲位, 終點儲位) 全部可用
                start = max(agvs[a].availableTime, 
                            max(containerAvailableTime[blockerId], 
                                max(gridBusyTime[src_coord.row][src_coord.bay], gridBusyTime[bestDst_coord.row][bestDst_coord.bay])))
                
                travel_to_src = (abs(agvs[a].currentPos.row - src_coord.row) + abs(agvs[a].currentPos.bay - src_coord.bay)) * t_travel
                travel_to_dst = (abs(src_coord.row - bestDst_coord.row) + abs(src_coord.bay - bestDst_coord.bay)) * t_travel
                finish = start + travel_to_src + t_handle + travel_to_dst + t_handle
                
                if finish < bestFinish:
                    bestFinish = finish; bestAgvIdx = a; bestStart = start
                    pickupTime = start + travel_to_src + t_handle

            yard.moveBox(src_coord.row, src_coord.bay, bestDst_coord.row, bestDst_coord.bay)
            agvs[bestAgvIdx].availableTime = bestFinish
            agvs[bestAgvIdx].currentPos = bestDst_coord
            containerAvailableTime[blockerId] = bestFinish 
            gridBusyTime[src_coord.row][src_coord.bay] = pickupTime # 儲位在 AGV 離開後釋放
            gridBusyTime[bestDst_coord.row][bestDst_coord.bay] = bestFinish
            
            pl = PyMissionLog()
            pl.mission_no = len(py_logs) + 1; pl.agv_id = bestAgvIdx; pl.mission_type = "reshuffle"
            pl.container_id = blockerId; pl.related_target_id = targetId
            pl.src = (src_coord.row, src_coord.bay, src_coord.tier); pl.dst = (bestDst_coord.row, bestDst_coord.bay, bestDst_coord.tier)
            pl.start_time = <long long>(bestStart + sim_start); pl.end_time = <long long>(bestFinish + sim_start); pl.makespan = bestFinish
            py_logs.append(pl)

        # Phase 2: Target Retrieval
        src_coord = yard.getBoxPosition(targetId)
        if src_coord.row == -1: continue

        bestFinish = 1e18
        bestPort = 1
        for a in range(agvCount):
            for p in range(1, portCount + 1):
                start = max(agvs[a].availableTime, max(containerAvailableTime[targetId], gridBusyTime[src_coord.row][src_coord.bay]))
                travel_to_src = (abs(agvs[a].currentPos.row - src_coord.row) + abs(agvs[a].currentPos.bay - src_coord.bay)) * t_travel
                arrivalAtPort = start + travel_to_src + t_handle + (abs(src_coord.row - (-1)) + abs(src_coord.bay - (-1))) * t_travel
                processStart = max(arrivalAtPort, portBusyTime[p])
                portFinish = processStart + t_handle + t_process + c_sku_map[targetId] * t_pick
                if portFinish < bestFinish:
                    bestFinish = portFinish; bestAgvIdx = a; bestPort = p; bestStart = start
                    pickupTime = processStart + t_handle # AGV 放下貨櫃時間

        yard.removeBox(targetId)
        agvs[bestAgvIdx].availableTime = pickupTime 
        agvs[bestAgvIdx].currentPos = Coordinate(-1, -1, bestPort)
        containerAvailableTime[targetId] = bestFinish 
        portBusyTime[bestPort] = bestFinish
        gridBusyTime[src_coord.row][src_coord.bay] = bestStart + travel_to_src + t_handle
        
        pl = PyMissionLog()
        pl.mission_no = len(py_logs) + 1; pl.agv_id = bestAgvIdx; pl.mission_type = "target"
        pl.container_id = targetId; pl.related_target_id = targetId
        pl.src = (src_coord.row, src_coord.bay, src_coord.tier); pl.dst = (-1, -1, bestPort)
        pl.start_time = <long long>(bestStart + sim_start); pl.end_time = <long long>(pickupTime + sim_start); pl.makespan = pickupTime
        py_logs.append(pl)

        # Phase 3: Return
        bestDst_coord = Coordinate(-1, -1, -1)
        for r in range(yard.MAX_ROWS):
            found_slot = False
            for b in range(yard.MAX_BAYS):
                if yard.canReceiveBox(r, b):
                    bestDst_coord = Coordinate(r, b, yard.tops[r][b]); found_slot = True; break
            if found_slot: break
        
        start = max(agvs[bestAgvIdx].availableTime, max(containerAvailableTime[targetId], portBusyTime[bestPort]))
        travel_to_dst = (abs((-1) - bestDst_coord.row) + abs((-1) - bestDst_coord.bay)) * t_travel
        finish = start + travel_to_dst + t_handle
        
        yard.initBox(targetId, bestDst_coord.row, bestDst_coord.bay, bestDst_coord.tier)
        agvs[bestAgvIdx].availableTime = finish; agvs[bestAgvIdx].currentPos = bestDst_coord
        containerAvailableTime[targetId] = finish 
        gridBusyTime[bestDst_coord.row][bestDst_coord.bay] = finish
        
        pl = PyMissionLog()
        pl.mission_no = len(py_logs) + 1; pl.agv_id = bestAgvIdx; pl.mission_type = "return"
        pl.container_id = targetId; pl.related_target_id = targetId
        pl.src = (-1, -1, bestPort); pl.dst = (bestDst_coord.row, bestDst_coord.bay, bestDst_coord.tier)
        pl.start_time = <long long>(start + sim_start); pl.end_time = <long long>(finish + sim_start); pl.makespan = finish
        py_logs.append(pl)

    return py_logs