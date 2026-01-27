# distutils: language = c++
# cython: boundscheck=False
# cython: wraparound=False
# cython: cdivision=True

from libcpp.vector cimport vector
from libcpp.string cimport string
from libcpp.unordered_map cimport unordered_map
from libcpp.algorithm cimport sort
from libcpp.cmath cimport abs
from cython.parallel import prange
from libc.math cimport fmax, fmin
from libc.stdlib cimport rand, RAND_MAX, srand
import time

# ==========================================
# 1. C++ Struct Definitions
# ==========================================
cdef extern from *:
    """
    #include <vector>
    #include <string>
    #include <cmath>
    #include <algorithm>
    #include <iostream>
    #include <limits>
    #include <random>
    #include <unordered_map>

    struct Coordinate {
        int row;
        int bay;
        int tier;
        Coordinate() : row(-1), bay(-1), tier(-1) {}
        Coordinate(int r, int b, int t) : row(r), bay(b), tier(t) {}
        bool operator==(const Coordinate& other) const {
            return row == other.row && bay == other.bay && tier == other.tier;
        }
        bool operator<(const Coordinate& other) const {
            if (row != other.row) return row < other.row;
            if (bay != other.bay) return bay < other.bay;
            return tier < other.tier;
        }
    };

    Coordinate make_coord(int r, int b, int t) {
        return Coordinate(r, b, t);
    }

    struct Agent {
        int id;
        Coordinate currentPos;
        double availableTime;
    };

    struct MissionLog {
        int mission_no;
        int agv_id;
        int batch_id;
        int container_id;
        int related_target_id;
        Coordinate src;
        Coordinate dst;
        int mission_priority;
        long long start_time_epoch;
        long long end_time_epoch;
        double makespan_snapshot;
        int type_code; 
        int mission_status; 
        bool operator<(const MissionLog& other) const {
            return start_time_epoch < other.start_time_epoch;
        }
    };

    struct YardSystem {
        int MAX_ROWS;
        int MAX_BAYS;
        int MAX_TIERS;
        std::vector<std::vector<std::vector<int>>> grid;
        std::vector<Coordinate> boxLocations;
        std::vector<std::vector<int>> tops;

        void init(int r, int b, int t, int total) {
            MAX_ROWS = r; MAX_BAYS = b; MAX_TIERS = t;
            grid.resize(r, std::vector<std::vector<int>>(b, std::vector<int>(t, 0)));
            boxLocations.resize(total + 1, Coordinate(-1, -1, -1));
            tops.resize(r, std::vector<int>(b, 0));
        }

        void initBox(int id, int r, int b, int t) {
            if(r >= MAX_ROWS || b >= MAX_BAYS || t >= MAX_TIERS) return;
            grid[r][b][t] = id;
            if (id >= boxLocations.size()) boxLocations.resize(id + 1, Coordinate(-1, -1, -1));
            boxLocations[id] = Coordinate(r, b, t);
            if (t + 1 > tops[r][b]) tops[r][b] = t + 1;
        }

        void moveToPort(int id, int port_id) {
            if (id >= boxLocations.size()) return;
            Coordinate pos = boxLocations[id];
            if (pos.row != -1) {
                grid[pos.row][pos.bay][pos.tier] = 0;
                tops[pos.row][pos.bay]--;
                boxLocations[id] = Coordinate(-1, -1, port_id);
            }
        }
        
        void returnFromPort(int id, int r, int b) {
            if (id >= boxLocations.size()) return;
            if (r < 0 || r >= MAX_ROWS || b < 0 || b >= MAX_BAYS) return;
            int t = tops[r][b];
            if (t >= MAX_TIERS) return;
            grid[r][b][t] = id;
            tops[r][b]++;
            boxLocations[id] = Coordinate(r, b, t);
        }

        void moveBox(int r1, int b1, int r2, int b2) {
            int t1 = tops[r1][b1] - 1;
            int id = grid[r1][b1][t1];
            int t2 = tops[r2][b2];
            grid[r1][b1][t1] = 0;
            grid[r2][b2][t2] = id;
            boxLocations[id] = Coordinate(r2, b2, t2);
            tops[r1][b1]--;
            tops[r2][b2]++;
        }
        
        Coordinate getBoxPosition(int id) const {
            if (id >= boxLocations.size()) return Coordinate(-1, -1, -1);
            return boxLocations[id];
        }

        bool isTop(int id) const {
            if (id >= boxLocations.size()) return false;
            Coordinate pos = boxLocations[id];
            if (pos.row == -1) return true; 
            return pos.tier == (tops[pos.row][pos.bay] - 1);
        }

        std::vector<int> getBlockingBoxes(int id) const {
            std::vector<int> blockers;
            if (id >= boxLocations.size()) return blockers;
            Coordinate pos = boxLocations[id];
            if (pos.row == -1) return blockers;
            for (int t = pos.tier + 1; t < tops[pos.row][pos.bay]; ++t) {
                blockers.push_back(grid[pos.row][pos.bay][t]);
            }
            return blockers;
        }

        bool canReceiveBox(int r, int b) const {
             if (r < 0 || r >= MAX_ROWS || b < 0 || b >= MAX_BAYS) return false;
             return tops[r][b] < MAX_TIERS;
        }
    };

    struct SearchNode {
        YardSystem yard;
        std::vector<Agent> agvs;
        double g;
        double h;
        double f;
        std::vector<std::vector<double>> gridBusyTime;
        std::vector<double> portsBusyTime; 
        bool isCurrentTargetRetrieved;
        std::vector<MissionLog> history;
        bool operator<(const SearchNode& other) const {
            return f < other.f;
        }
    };
    """
    
    cdef cppclass Coordinate:
        int row
        int bay
        int tier
        bint operator==(const Coordinate&)

    Coordinate make_coord(int r, int b, int t) nogil

    cdef struct Agent:
        int id
        Coordinate currentPos
        double availableTime

    cdef struct MissionLog:
        int mission_no
        int agv_id
        int batch_id
        int container_id
        int related_target_id
        Coordinate src
        Coordinate dst
        int mission_priority
        long long start_time_epoch
        long long end_time_epoch
        double makespan_snapshot
        int type_code
        int mission_status

    cdef cppclass YardSystem:
        int MAX_ROWS
        int MAX_BAYS
        int MAX_TIERS
        vector[vector[vector[int]]] grid
        vector[vector[int]] tops
        void init(int r, int b, int t, int total) nogil
        void initBox(int id, int r, int b, int t) nogil
        void moveToPort(int id, int port_id) nogil 
        void returnFromPort(int id, int r, int b) nogil 
        void moveBox(int r1, int b1, int r2, int b2) nogil
        Coordinate getBoxPosition(int id) nogil
        bint isTop(int id) nogil
        vector[int] getBlockingBoxes(int id) nogil
        bint canReceiveBox(int r, int b) nogil

    cdef cppclass SearchNode:
        YardSystem yard
        vector[Agent] agvs
        double g
        double h
        double f
        vector[vector[double]] gridBusyTime
        vector[double] portsBusyTime
        bint isCurrentTargetRetrieved
        vector[MissionLog] history
        bint operator<(const SearchNode&) const

# ==========================================
# 2. Global Variables & Helper
# ==========================================
cdef double W_PENALTY_BLOCKING = 2000.0 
cdef double W_PENALTY_LOOKAHEAD = 500.0
cdef double TIME_TRAVEL_UNIT = 5.0
cdef double TIME_HANDLE = 30.0
cdef double TIME_PROCESS = 10.0
cdef double TIME_PICK = 5.0
cdef int AGV_COUNT = 3
cdef int BEAM_WIDTH = 100
cdef int PORT_COUNT = 5
cdef long long SIM_START_EPOCH = 1705363200

# bs_solver.pyx 
def set_config(double t_travel, double t_handle, double t_process, double t_pick, int agv_cnt, int beam_w, long long sim_start):
    global TIME_TRAVEL_UNIT, TIME_HANDLE, TIME_PROCESS, TIME_PICK, AGV_COUNT, BEAM_WIDTH, SIM_START_EPOCH
    TIME_TRAVEL_UNIT = t_travel
    TIME_HANDLE = t_handle
    TIME_PROCESS = t_process
    TIME_PICK = t_pick  
    AGV_COUNT = agv_cnt
    BEAM_WIDTH = beam_w
    SIM_START_EPOCH = sim_start

cdef int getSeqIndex(int boxId, vector[int]& seq) noexcept nogil:
    for k in range(seq.size()):
        if seq[k] == boxId: return k
    return 999999 

cdef double getTravelTime(Coordinate src, Coordinate dst) nogil:
    cdef int r1 = 0 if src.row == -1 else src.row
    cdef int b1 = 0 if src.bay == -1 else src.bay
    cdef int r2 = 0 if dst.row == -1 else dst.row
    cdef int b2 = 0 if dst.bay == -1 else dst.bay
    return (abs(r1 - r2) + abs(b1 - b2)) * TIME_TRAVEL_UNIT

cdef double calculateRILPenalty(YardSystem& yard, int r, int b, vector[int]& seq, int currentSeqIdx, int movingBoxId) noexcept nogil:
    cdef int currentTop = yard.tops[r][b]
    if currentTop == 0: return 0.0 
    cdef int topBoxId = yard.grid[r][b][currentTop - 1]
    cdef int movingBoxRank = getSeqIndex(movingBoxId, seq)
    cdef int topBoxRank = getSeqIndex(topBoxId, seq)
    cdef int t, boxId, rank, blockingCount = 0
    for t in range(currentTop):
        boxId = yard.grid[r][b][t]
        rank = getSeqIndex(boxId, seq)
        if rank < movingBoxRank: blockingCount += 1
    if blockingCount > 0: return W_PENALTY_BLOCKING * blockingCount 
    if topBoxRank > movingBoxRank: return 0.0
    if topBoxRank > currentSeqIdx: return W_PENALTY_LOOKAHEAD / <double>(topBoxRank - currentSeqIdx)
    return 0.0

cdef double calculate_3D_UBALB(YardSystem& yard, vector[int]& remainingTargets, int currentSeqIdx, bint currentRetrievedStatus) noexcept nogil:
    cdef double total_time = 0.0
    cdef size_t i
    cdef int targetId, topTier, l, p
    cdef Coordinate targetPos
    cdef double minPortDist, returnDist
    for i in range(currentSeqIdx, remainingTargets.size()):
        targetId = remainingTargets[i]
        if i == currentSeqIdx and currentRetrievedStatus: continue
        targetPos = yard.getBoxPosition(targetId)
        if targetPos.row == -1: continue
        topTier = yard.tops[targetPos.row][targetPos.bay] - 1
        for l in range(topTier, targetPos.tier, -1):
            total_time += TIME_HANDLE + TIME_TRAVEL_UNIT + TIME_HANDLE
        minPortDist = 1e9
        for p in range(1, PORT_COUNT + 1):
             minPortDist = fmin(minPortDist, getTravelTime(targetPos, make_coord(-1, -1, p)))
        total_time += TIME_HANDLE + minPortDist + TIME_HANDLE + TIME_PROCESS
        returnDist = (yard.MAX_ROWS + yard.MAX_BAYS) / 2.0 * TIME_TRAVEL_UNIT
        total_time += TIME_HANDLE + returnDist + TIME_HANDLE
    return total_time / <double>AGV_COUNT

cdef int calculateReturnPenalty(YardSystem& yard, int r, int b, vector[int]& seq, int currentSeqIdx) noexcept nogil:
    cdef int penalty = 0
    cdef int currentTop = yard.tops[r][b]
    cdef int t, boxId, urgency
    cdef size_t k
    for t in range(currentTop):
        boxId = yard.grid[r][b][t]
        for k in range(currentSeqIdx + 1, seq.size()):
            if seq[k] == boxId:
                urgency = (k - currentSeqIdx)
                penalty += 1000 // (urgency + 1)
    return penalty

# ==========================================
# 4. BBS Solver (策略 1 修正)
# ==========================================
cdef vector[MissionLog] solveAndRecord(YardSystem& initialYard, vector[int]& seq, unordered_map[int, int]& sku_map) noexcept nogil:
    srand(12345)
    cdef SearchNode root
    root.yard = initialYard
    root.g = root.h = root.f = 0
    root.isCurrentTargetRetrieved = False
    root.gridBusyTime.resize(initialYard.MAX_ROWS, vector[double](initialYard.MAX_BAYS, 0.0))
    root.portsBusyTime.resize(PORT_COUNT + 1, 0.0)
    cdef int i, p, port_idx
    cdef Agent agv
    agv.currentPos = make_coord(0, 0, 0)
    agv.availableTime = 0.0
    for i in range(AGV_COUNT):
        agv.id = i
        root.agvs.push_back(agv)
    cdef vector[SearchNode] currentBeam, nextBeam
    currentBeam.push_back(root)
    cdef size_t seqIdx
    cdef int targetId, expansion_limit, r, b, bestAGV, blockerId, selectedPort
    cdef bint targetCycleDone, isTop
    cdef SearchNode node, newNode
    cdef Coordinate targetPos, src, dst, selectedPortCoord
    cdef double bestFinishTime, bestStartTime, travel, start, travelToDest, finish, pickupDoneTime, maxAGV, pickupTime, penalty, noise
    cdef double arrivalAtPort, portReadyTime, agvArrivalAtPort, processStart, agvFreeTime, portFinishTime, dynamic_process_time
    cdef vector[int] blockers
    cdef MissionLog log

    for seqIdx in range(seq.size()):
        targetId = seq[seqIdx]
        targetCycleDone = False
        expansion_limit = 0
        while not targetCycleDone and expansion_limit < 40:
            expansion_limit += 1
            nextBeam.clear()
            for node in currentBeam:
                targetPos = node.yard.getBoxPosition(targetId)
                if targetPos.row != -1 and node.isCurrentTargetRetrieved:
                    nextBeam.push_back(node); targetCycleDone = True; continue
                
                # Case B: RETURN
                if targetPos.row == -1:
                    selectedPort = targetPos.tier; src = make_coord(-1, -1, selectedPort)
                    for r in range(node.yard.MAX_ROWS):
                        for b in range(node.yard.MAX_BAYS):
                            if not node.yard.canReceiveBox(r, b): continue
                            dst = make_coord(r, b, node.yard.tops[r][b])
                            penalty = calculateReturnPenalty(node.yard, r, b, seq, seqIdx)
                            bestAGV = -1; bestFinishTime = 1e9; bestStartTime = 0;pickupTime = 0
                            for i in range(AGV_COUNT):
                                travel = getTravelTime(node.agvs[i].currentPos, src)
                                start = fmax(node.agvs[i].availableTime, node.portsBusyTime[selectedPort])
                                travelToDest = getTravelTime(src, dst)
                                
                                finish = start + travel + TIME_HANDLE + travelToDest + TIME_HANDLE
                                if finish < bestFinishTime:
                                    bestFinishTime = finish; bestAGV = i; bestStartTime = start
                                    pickupTime = start + travel + TIME_HANDLE
                            newNode = node
                            newNode.yard.returnFromPort(targetId, dst.row, dst.bay)
                            newNode.isCurrentTargetRetrieved = True 
                            newNode.agvs[bestAGV].currentPos = dst
                            newNode.agvs[bestAGV].availableTime = bestFinishTime
                            newNode.portsBusyTime[selectedPort] = pickupTime
                            newNode.gridBusyTime[dst.row][dst.bay] = bestFinishTime
                            maxAGV = 0
                            for i in range(AGV_COUNT): maxAGV = fmax(maxAGV, newNode.agvs[i].availableTime)
                            newNode.g = maxAGV
                            newNode.h = calculate_3D_UBALB(newNode.yard, seq, seqIdx + 1, False) 
                            newNode.f = newNode.g + newNode.h + penalty + (<double>rand()/RAND_MAX)*0.01
                            log.mission_no = newNode.history.size()+1; log.agv_id = bestAGV; log.type_code = 2 
                            log.container_id = targetId; log.related_target_id = targetId
                            log.src = src; log.dst = dst
                            log.start_time_epoch = <long long>bestStartTime + SIM_START_EPOCH 
                            log.end_time_epoch = <long long>bestFinishTime + SIM_START_EPOCH 
                            log.makespan_snapshot = newNode.g; newNode.history.push_back(log); nextBeam.push_back(newNode)
                    continue 

                # Case C: RETRIEVE
                isTop = node.yard.isTop(targetId)
                if isTop:
                    src = node.yard.getBoxPosition(targetId)
                    bestAGV = -1; bestFinishTime = 1e9; bestStartTime = 0; selectedPort = -1
                    dynamic_process_time = sku_map[targetId] * TIME_PICK
                    for i in range(AGV_COUNT):
                        travel = getTravelTime(node.agvs[i].currentPos, src)
                        start = fmax(node.agvs[i].availableTime, node.gridBusyTime[src.row][src.bay])
                        arrivalAtPort = start + travel + TIME_HANDLE + getTravelTime(src, make_coord(-1, -1, 1))
                        p = -1
                        for port_idx in range(1, PORT_COUNT + 1):
                            if node.portsBusyTime[port_idx] <= arrivalAtPort:
                                p = port_idx
                                break
                        if p == -1:
                            portReadyTime = 1e9
                            for port_idx in range(1, PORT_COUNT+1):
                                if node.portsBusyTime[port_idx] < portReadyTime:
                                    portReadyTime = node.portsBusyTime[port_idx]
                                    p = port_idx
                        selectedPortCoord = make_coord(-1, -1, p)
                        agvArrivalAtPort = start + travel + TIME_HANDLE + getTravelTime(src, selectedPortCoord)
                        processStart = fmax(agvArrivalAtPort, node.portsBusyTime[p])
                        
                        agvFreeTime = processStart + TIME_HANDLE 
                        portFinishTime = agvFreeTime + TIME_PROCESS + dynamic_process_time
                        
                        if portFinishTime < bestFinishTime:
                            bestFinishTime = portFinishTime; bestAGV = i; bestStartTime = start; selectedPort = p; pickupTime = agvFreeTime

                    newNode = node; newNode.yard.moveToPort(targetId, selectedPort)
                    newNode.isCurrentTargetRetrieved = True; selectedPortCoord = make_coord(-1, -1, selectedPort)
                    newNode.agvs[bestAGV].currentPos = selectedPortCoord
                    newNode.agvs[bestAGV].availableTime = pickupTime 
                    newNode.portsBusyTime[selectedPort] = bestFinishTime
                    pickupDoneTime = bestStartTime + getTravelTime(node.agvs[bestAGV].currentPos, src) + TIME_HANDLE
                    newNode.gridBusyTime[src.row][src.bay] = pickupDoneTime
                    maxAGV = 0
                    for i in range(AGV_COUNT): maxAGV = fmax(maxAGV, newNode.agvs[i].availableTime)
                    newNode.g = maxAGV; newNode.h = calculate_3D_UBALB(newNode.yard, seq, seqIdx, True)
                    newNode.f = newNode.g + newNode.h + (<double>rand()/RAND_MAX)*0.01
                    log.mission_no = newNode.history.size()+1; log.agv_id = bestAGV; log.type_code = 0 
                    log.container_id = targetId; log.related_target_id = targetId
                    log.src = src; log.dst = selectedPortCoord 
                    log.start_time_epoch = <long long>bestStartTime + SIM_START_EPOCH
                    log.end_time_epoch = <long long>bestFinishTime + SIM_START_EPOCH
                    log.makespan_snapshot = newNode.g; newNode.history.push_back(log); nextBeam.push_back(newNode)
                else:
                    # Case D: RESHUFFLE
                    blockers = node.yard.getBlockingBoxes(targetId)
                    if blockers.empty(): continue
                    blockerId = blockers.back(); movingBoxId = blockerId; src = node.yard.getBoxPosition(blockerId)
                    for r in range(node.yard.MAX_ROWS):
                        for b in range(node.yard.MAX_BAYS):
                            if r == src.row and b == src.bay: continue
                            if not node.yard.canReceiveBox(r, b): continue
                            dst = make_coord(r, b, node.yard.tops[r][b]); penalty = calculateRILPenalty(node.yard, r, b, seq, seqIdx, movingBoxId)
                            bestAGV = -1; bestFinishTime = 1e9; bestStartTime = 0
                            for i in range(AGV_COUNT):
                                travel = getTravelTime(node.agvs[i].currentPos, src)
                                colReady = fmax(node.gridBusyTime[src.row][src.bay], node.gridBusyTime[r][b])
                                start = fmax(node.agvs[i].availableTime, colReady)
                                finish = start + travel + TIME_HANDLE + getTravelTime(src, dst) + TIME_HANDLE
                                if finish < bestFinishTime: bestFinishTime = finish; bestAGV = i; bestStartTime = start
                            newNode = node; newNode.yard.moveBox(src.row, src.bay, dst.row, dst.bay)
                            newNode.agvs[bestAGV].currentPos = dst; newNode.agvs[bestAGV].availableTime = bestFinishTime
                            pickupTime = bestStartTime + getTravelTime(node.agvs[bestAGV].currentPos, src) + TIME_HANDLE
                            newNode.gridBusyTime[src.row][src.bay] = pickupTime; newNode.gridBusyTime[dst.row][dst.bay] = bestFinishTime
                            maxAGV = 0
                            for i in range(AGV_COUNT): maxAGV = fmax(maxAGV, newNode.agvs[i].availableTime)
                            newNode.g = maxAGV; newNode.h = calculate_3D_UBALB(newNode.yard, seq, seqIdx, False)
                            newNode.f = newNode.g + newNode.h + penalty + (<double>rand()/RAND_MAX)*0.01
                            log.mission_no = newNode.history.size()+1; log.agv_id = bestAGV; log.type_code = 1 
                            log.container_id = blockerId; log.related_target_id = targetId
                            log.src = src; log.dst = dst
                            log.start_time_epoch = <long long>bestStartTime + 1705363200
                            log.end_time_epoch = <long long>bestFinishTime + 1705363200
                            log.makespan_snapshot = newNode.g; newNode.history.push_back(log); nextBeam.push_back(newNode)

            if nextBeam.empty(): break
            sort(nextBeam.begin(), nextBeam.end())
            if nextBeam.size() > BEAM_WIDTH: nextBeam.resize(BEAM_WIDTH)
            currentBeam = nextBeam
            check = currentBeam[0].yard.getBoxPosition(targetId)
            if check.row != -1 and currentBeam[0].isCurrentTargetRetrieved: targetCycleDone = True
        if currentBeam.empty(): return vector[MissionLog]()
        for i in range(currentBeam.size()): currentBeam[i].isCurrentTargetRetrieved = False
    return currentBeam[0].history

# ==========================================
# 5. Entry Point
# ==========================================
cdef class PyMissionLog:
    cdef public int mission_no, agv_id, container_id, related_target_id
    cdef public str mission_type
    cdef public tuple src, dst
    cdef public long long start_time, end_time
    cdef public double makespan

def run_fixed_solver(dict config, list boxes, list commands, list fixed_seq_ids, dict sku_map):
    cdef YardSystem initialYard
    initialYard.init(config['max_row'], config['max_bay'], config['max_level'], config['total_boxes'])
    for box in boxes: initialYard.initBox(box['id'], box['row'], box['bay'], box['level'])
    cdef vector[int] sequence
    for pid in fixed_seq_ids: sequence.push_back(pid)
    cdef unordered_map[int, int] c_sku_map
    for k, v in sku_map.items(): c_sku_map[k] = v
    cdef vector[MissionLog] finalLogs = solveAndRecord(initialYard, sequence, c_sku_map)
    py_logs = []
    for log in finalLogs:
        pl = PyMissionLog()
        pl.mission_no = log.mission_no; pl.agv_id = log.agv_id; pl.container_id = log.container_id; pl.related_target_id = log.related_target_id
        if log.type_code == 0: pl.mission_type = "target"
        elif log.type_code == 1: pl.mission_type = "reshuffle"
        else: pl.mission_type = "return"
        pl.src = (log.src.row, log.src.bay, log.src.tier); pl.dst = (log.dst.row, log.dst.bay, log.dst.tier)
        pl.start_time = log.start_time_epoch; pl.end_time = log.end_time_epoch; pl.makespan = log.makespan_snapshot
        py_logs.append(pl)
    return py_logs