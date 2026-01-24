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
from libc.math cimport fmax
# [NEW] Import random for noise
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

        void removeBox(int id) {
            if (id >= boxLocations.size()) return;
            Coordinate pos = boxLocations[id];
            if (pos.row != -1) {
                grid[pos.row][pos.bay][pos.tier] = 0;
                tops[pos.row][pos.bay]--;
                boxLocations[id] = Coordinate(-1, -1, -1);
            }
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
        double workstationBusyTime;
        bool isCurrentTargetRetrieved;
        std::vector<MissionLog> history;
        
        bool operator<(const SearchNode& other) const {
            return f < other.f;
        }
    };
    """

    # ==========================================
    # [NEW] Tuning Hyperparameters
    # ==========================================
    # 1. Hard Penalty: Directly blocking a container that needs to be retrieved sooner.
    #    Set to 2000, roughly equal to 30 reshuffle costs, forcing AGVs to avoid it.
    cdef double W_PENALTY_BLOCKING = 2000.0 

    # 2. Soft Penalty (Look-ahead): Blocking a container that is retrieved later but relatively soon.
    #    Set to 500. If diff=2 (urgent), penalty is 250 (approx 4 reshuffles).
    #    If diff=50 (not urgent), penalty is 10 (negligible).
    cdef double W_PENALTY_LOOKAHEAD = 500.0

    # [MODIFIED] Helper to get the sequence index of a box
    # If the box is not in the sequence (e.g., static blocker), return a large value indicating safety.
    cdef int getSeqIndex(int boxId, vector[int]& seq) noexcept nogil:
        for k in range(seq.size()):
            if seq[k] == boxId:
                return k
        return 999999 # Not in sequence (static block), very safe to stack on

    # [MODIFIED] RIL-based Penalty Calculation
    # Args:
    #   yard: Current yard state
    #   r, b: Target column coordinates
    #   seq: Job sequence
    #   currentSeqIdx: Current progress index
    #   movingBoxId: ID of the blocking box being moved
    cdef double calculateRILPenalty(YardSystem& yard, int r, int b, vector[int]& seq, int currentSeqIdx, int movingBoxId) noexcept nogil:
        cdef int currentTop = yard.tops[r][b]
        if currentTop == 0:
            return 0.0 # Empty column is usually a good choice, zero penalty

        cdef int topBoxId = yard.grid[r][b][currentTop - 1]
        cdef int movingBoxRank = getSeqIndex(movingBoxId, seq)
        cdef int topBoxRank = getSeqIndex(topBoxId, seq)
        
        cdef int t, boxId, rank
        cdef int blockingCount = 0
        
        # 1. RI (Reshuffle Index) Calculation
        # Count how many boxes in this column are retrieved 'earlier' than the moving box (Rank < movingBoxRank)
        # These represent potential future reshuffle costs.
        for t in range(currentTop):
            boxId = yard.grid[r][b][t]
            rank = getSeqIndex(boxId, seq)
            if rank < movingBoxRank:
                blockingCount += 1
                
        # 2. RIL (Tie-breaking with Look-ahead)
        # Calculate base penalty
        cdef double penalty = 0.0

        # Primary Penalty: If it causes future reshuffles (RI > 0)
        if blockingCount > 0:
            # The more blocks, the heavier the penalty.
            penalty += W_PENALTY_BLOCKING * blockingCount 
        else:
            # RI = 0 (Safe column), enter RIL comparison
            # We prefer topBoxRank to be as large as possible (retrieved far in the future).
            
            # Logic: Penalty should be inversely proportional to topBoxRank.
            if topBoxRank > movingBoxRank:
                # Normal stacking (Late retrieval at bottom, Early retrieval on top).
                # No penalty as this is ideal.
                penalty += 0.0 
            else:
                # General case: Stacking on top of another box.
                # We want the denominator (topBoxRank) to be large.
                if topBoxRank > currentSeqIdx: # Ensure it is a future task
                    penalty += W_PENALTY_LOOKAHEAD / <double>(topBoxRank - currentSeqIdx)
                else:
                    # Should be caught by RI, but just in case.
                    penalty += 0.0

        return penalty
        
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
        void removeBox(int id) nogil
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
        double workstationBusyTime
        bint isCurrentTargetRetrieved
        vector[MissionLog] history
        bint operator<(const SearchNode&) const

    void printf(const char *format, ...) nogil

# ==========================================
# 2. Global Config
# ==========================================
cdef double TIME_TRAVEL_UNIT = 5.0
cdef double TIME_HANDLE = 30.0
cdef double TIME_PROCESS = 10.0
cdef int AGV_COUNT = 3
cdef int BEAM_WIDTH = 100

def set_config(double t_travel, double t_handle, double t_process, int agv_cnt, int beam_w):
    global TIME_TRAVEL_UNIT, TIME_HANDLE, TIME_PROCESS, AGV_COUNT, BEAM_WIDTH
    TIME_TRAVEL_UNIT = t_travel
    TIME_HANDLE = t_handle
    TIME_PROCESS = t_process
    AGV_COUNT = agv_cnt
    BEAM_WIDTH = beam_w

# ==========================================
# 3. Logic Implementation
# ==========================================

cdef double getTravelTime(Coordinate src, Coordinate dst) nogil:
    cdef int r1 = 0 if src.row == -1 else src.row
    cdef int b1 = 0 if src.bay == -1 else src.bay
    cdef int r2 = 0 if dst.row == -1 else dst.row
    cdef int b2 = 0 if dst.bay == -1 else dst.bay
    cdef double dist = abs(r1 - r2) + abs(b1 - b2)
    return dist * TIME_TRAVEL_UNIT

cdef double calculate_3D_UBALB(YardSystem& yard, vector[int]& remainingTargets, int currentSeqIdx, unordered_map[int, Coordinate]& targetDests, bint currentRetrievedStatus) noexcept nogil:
    cdef double total_time = 0.0
    cdef size_t i
    cdef int targetId, topTier, l
    cdef Coordinate targetPos, realDst
    cdef double distToPort, returnDist, avgDist

    for i in range(currentSeqIdx, remainingTargets.size()):
        targetId = remainingTargets[i]

        if i == currentSeqIdx and currentRetrievedStatus:
             avgDist = (yard.MAX_ROWS + yard.MAX_BAYS) / 2.0 * TIME_TRAVEL_UNIT
             total_time += TIME_HANDLE + avgDist + TIME_HANDLE
             continue

        targetPos = yard.getBoxPosition(targetId)
        if targetPos.row == -1: continue

        topTier = yard.tops[targetPos.row][targetPos.bay] - 1
        for l in range(topTier, targetPos.tier, -1):
            total_time += TIME_HANDLE + TIME_TRAVEL_UNIT + TIME_HANDLE
        
        if targetDests.count(targetId):
            realDst = targetDests[targetId]
        else:
            realDst = make_coord(-1, -1, 1)

        distToPort = getTravelTime(targetPos, realDst)
        total_time += TIME_HANDLE + distToPort + TIME_HANDLE + TIME_PROCESS
        
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
# 4. BBS Solver
# ==========================================
cdef vector[MissionLog] solveAndRecord(YardSystem& initialYard, vector[int]& seq, unordered_map[int, Coordinate]& dests) noexcept nogil:
    # Seed randomness for diversity
    srand(12345)
    
    cdef SearchNode root
    root.yard = initialYard
    root.g = 0
    root.h = 0
    root.f = 0
    root.workstationBusyTime = 0.0
    root.isCurrentTargetRetrieved = False
    
    root.gridBusyTime.resize(initialYard.MAX_ROWS, vector[double](initialYard.MAX_BAYS, 0.0))
    
    cdef int i
    cdef Agent agv
    agv.currentPos = make_coord(0, 0, 0)
    agv.availableTime = 0.0
    
    for i in range(AGV_COUNT):
        agv.id = i
        root.agvs.push_back(agv)

    cdef vector[SearchNode] currentBeam
    currentBeam.push_back(root)
    
    cdef size_t seqIdx
    cdef int targetId, expansion_limit
    cdef bint targetCycleDone
    cdef Coordinate realDest
    cdef vector[SearchNode] nextBeam
    
    cdef SearchNode node, newNode
    cdef Coordinate targetPos, src, dst, check
    cdef int r, b, bestAGV, blockerId
    cdef double bestFinishTime, bestStartTime, travel, start, travelToDest, finish, pickupDoneTime, maxAGV, travelToWS, travelToYard, colReady, pickupTime, penalty, noise
    cdef bint isTop
    cdef vector[int] blockers
    cdef MissionLog log
    cdef int movingBoxId # Variable to store current moving box ID

    for seqIdx in range(seq.size()):
        targetId = seq[seqIdx]
        targetCycleDone = False
        expansion_limit = 0
        
        if dests.count(targetId):
            realDest = dests[targetId]
        else:
            realDest = make_coord(-1, -1, 1)

        while not targetCycleDone and expansion_limit < 40:
            expansion_limit += 1
            nextBeam.clear()

            for node in currentBeam:
                targetPos = node.yard.getBoxPosition(targetId)

                # A: Done
                if targetPos.row != -1 and node.isCurrentTargetRetrieved:
                    nextBeam.push_back(node)
                    targetCycleDone = True
                    continue
                
                # B: Return
                if targetPos.row == -1:
                    for r in range(node.yard.MAX_ROWS):
                        for b in range(node.yard.MAX_BAYS):
                            if not node.yard.canReceiveBox(r, b): continue
                            
                            dst = make_coord(r, b, node.yard.tops[r][b])
                            penalty = calculateReturnPenalty(node.yard, r, b, seq, seqIdx)
                            
                            bestAGV = -1
                            bestFinishTime = 1e9
                            bestStartTime = 0

                            for i in range(AGV_COUNT):
                                travelToWS = getTravelTime(node.agvs[i].currentPos, realDest)
                                start = fmax(node.agvs[i].availableTime, node.workstationBusyTime)
                                travelToYard = getTravelTime(realDest, dst)
                                finish = start + travelToWS + TIME_HANDLE + travelToYard + TIME_HANDLE
                                if finish < bestFinishTime:
                                    bestFinishTime = finish
                                    bestAGV = i
                                    bestStartTime = start
                            
                            newNode = node
                            newNode.yard.initBox(targetId, dst.row, dst.bay, dst.tier)
                            newNode.isCurrentTargetRetrieved = True
                            newNode.agvs[bestAGV].currentPos = dst
                            newNode.agvs[bestAGV].availableTime = bestFinishTime
                            newNode.gridBusyTime[dst.row][dst.bay] = bestFinishTime
                            
                            maxAGV = 0
                            for i in range(AGV_COUNT):
                                maxAGV = fmax(maxAGV, newNode.agvs[i].availableTime)
                            newNode.g = maxAGV
                            # [UPDATED] f value calculation includes RIL Penalty
                            newNode.h = calculate_3D_UBALB(newNode.yard, seq, seqIdx + 1, dests, True)
                            noise = (<double>rand() / <double>RAND_MAX) * 0.01
                            
                            # Penalty weight can be tuned, set to 1.0 as RIL internally scales it
                            newNode.f = newNode.g + newNode.h + penalty + noise
                            
                            log.mission_no = newNode.history.size() + 1
                            log.agv_id = bestAGV
                            log.type_code = 2 
                            log.batch_id = 20260117
                            log.container_id = targetId
                            log.src = realDest
                            log.dst = dst
                            log.start_time_epoch = <long long>bestStartTime + 1705363200
                            log.end_time_epoch = <long long>bestFinishTime + 1705363200
                            log.makespan_snapshot = newNode.g
                            log.mission_status = 0
                            log.mission_priority = 0

                            newNode.history.push_back(log)
                            nextBeam.push_back(newNode)
                    continue

                # C: Retrieve
                isTop = node.yard.isTop(targetId)
                if isTop:
                    src = node.yard.getBoxPosition(targetId)
                    bestAGV = -1
                    bestFinishTime = 1e9
                    bestStartTime = 0

                    for i in range(AGV_COUNT):
                        travel = getTravelTime(node.agvs[i].currentPos, src)
                        start = fmax(node.agvs[i].availableTime, node.gridBusyTime[src.row][src.bay])
                        travelToDest = getTravelTime(src, realDest)
                        finish = start + travel + TIME_HANDLE + travelToDest + TIME_HANDLE + TIME_PROCESS
                        if finish < bestFinishTime:
                            bestFinishTime = finish
                            bestAGV = i
                            bestStartTime = start
                    
                    newNode = node
                    newNode.yard.removeBox(targetId)
                    newNode.isCurrentTargetRetrieved = False
                    newNode.agvs[bestAGV].currentPos = realDest
                    newNode.agvs[bestAGV].availableTime = bestFinishTime
                    newNode.workstationBusyTime = bestFinishTime
                    pickupDoneTime = bestStartTime + getTravelTime(node.agvs[bestAGV].currentPos, src) + TIME_HANDLE
                    newNode.gridBusyTime[src.row][src.bay] = pickupDoneTime

                    maxAGV = 0
                    for i in range(AGV_COUNT):
                        maxAGV = fmax(maxAGV, newNode.agvs[i].availableTime)
                    newNode.g = maxAGV
                    newNode.h = calculate_3D_UBALB(newNode.yard, seq, seqIdx, dests, False)
                    # [FIX] Add Noise
                    noise = (<double>rand() / <double>RAND_MAX) * 0.01
                    newNode.f = newNode.g + newNode.h + noise

                    log.mission_no = newNode.history.size() + 1
                    log.agv_id = bestAGV
                    log.type_code = 0
                    log.batch_id = 20260117
                    log.container_id = targetId
                    log.src = src
                    log.dst = realDest
                    log.start_time_epoch = <long long>bestStartTime + 1705363200
                    log.end_time_epoch = <long long>bestFinishTime + 1705363200
                    log.makespan_snapshot = newNode.g
                    log.mission_priority = 0
                    log.mission_status = 0

                    newNode.history.push_back(log)
                    nextBeam.push_back(newNode)
                else:
                    # Reshuffle
                    blockers = node.yard.getBlockingBoxes(targetId)
                    if blockers.empty(): continue
                    blockerId = blockers.back()
                    movingBoxId = blockerId 
                    src = node.yard.getBoxPosition(blockerId)

                    for r in range(node.yard.MAX_ROWS):
                        for b in range(node.yard.MAX_BAYS):
                            if r == src.row and b == src.bay: continue
                            if not node.yard.canReceiveBox(r, b): continue
                            
                            dst = make_coord(r, b, node.yard.tops[r][b])
                            
                            # [NEW] Calculate Penalty using RIL
                            penalty = calculateRILPenalty(node.yard, r, b, seq, seqIdx, movingBoxId)

                            bestAGV = -1
                            bestFinishTime = 1e9
                            bestStartTime = 0

                            for i in range(AGV_COUNT):
                                travel = getTravelTime(node.agvs[i].currentPos, src)
                                colReady = fmax(node.gridBusyTime[src.row][src.bay], node.gridBusyTime[r][b])
                                start = fmax(node.agvs[i].availableTime, colReady)
                                travelToDest = getTravelTime(src, dst)
                                finish = start + travel + TIME_HANDLE + travelToDest + TIME_HANDLE
                                if finish < bestFinishTime:
                                    bestFinishTime = finish
                                    bestAGV = i
                                    bestStartTime = start
                            
                            newNode = node
                            newNode.yard.moveBox(src.row, src.bay, dst.row, dst.bay)
                            newNode.agvs[bestAGV].currentPos = dst
                            newNode.agvs[bestAGV].availableTime = bestFinishTime
                            pickupTime = bestStartTime + getTravelTime(node.agvs[bestAGV].currentPos, src) + TIME_HANDLE
                            newNode.gridBusyTime[src.row][src.bay] = pickupTime
                            newNode.gridBusyTime[dst.row][dst.bay] = bestFinishTime
                            
                            maxAGV = 0
                            for i in range(AGV_COUNT):
                                maxAGV = fmax(maxAGV, newNode.agvs[i].availableTime)
                            newNode.g = maxAGV
                            newNode.h = calculate_3D_UBALB(newNode.yard, seq, seqIdx, dests, False)
                            # [FIX] Add Noise
                            noise = (<double>rand() / <double>RAND_MAX) * 0.01
                            newNode.f = newNode.g + newNode.h + penalty + noise

                            log.mission_no = newNode.history.size() + 1
                            log.agv_id = bestAGV
                            log.type_code = 1 
                            log.batch_id = 20260117
                            log.container_id = blockerId
                            log.src = src
                            log.dst = dst
                            log.start_time_epoch = <long long>bestStartTime + 1705363200
                            log.end_time_epoch = <long long>bestFinishTime + 1705363200
                            log.makespan_snapshot = newNode.g
                            log.mission_priority = 0
                            log.mission_status = 0

                            newNode.history.push_back(log)
                            nextBeam.push_back(newNode)

            # [DEBUG] Print Beam Size and Top Scores to Verify Diversity
            #if not nextBeam.empty():
            #    printf("Target %d | Depth %d | Nodes Generated: %lu | Best f: %.2f\n", targetId, expansion_limit, nextBeam.size(), nextBeam[0].f)

            if nextBeam.empty(): break
            sort(nextBeam.begin(), nextBeam.end())
            if nextBeam.size() > BEAM_WIDTH:
                nextBeam.resize(BEAM_WIDTH)
            
            currentBeam = nextBeam
            
            check = currentBeam[0].yard.getBoxPosition(targetId)
            if check.row != -1 and currentBeam[0].isCurrentTargetRetrieved:
                targetCycleDone = True

        if currentBeam.empty(): return vector[MissionLog]()
        
        for i in range(currentBeam.size()):
            currentBeam[i].isCurrentTargetRetrieved = False

    return currentBeam[0].history

# ==========================================
# 5. Entry Point
# ==========================================

cdef class PyMissionLog:
    cdef public int mission_no
    cdef public int agv_id
    cdef public str mission_type
    cdef public int container_id
    cdef public tuple src
    cdef public tuple dst
    cdef public long long start_time
    cdef public long long end_time
    cdef public double makespan

def run_fixed_solver(dict config, list boxes, list commands, list fixed_seq_ids):
    # 1. Setup Data
    cdef YardSystem initialYard
    initialYard.init(config['max_row'], config['max_bay'], config['max_level'], config['total_boxes'])
    
    for box in boxes:
        initialYard.initBox(box['id'], box['row'], box['bay'], box['level'])

    cdef vector[int] sequence
    cdef unordered_map[int, Coordinate] targetDests
    cdef Coordinate destCoord

    # Prepare Target Dests Map
    for cmd in commands:
        if cmd['type'] == 'target':
            destCoord = make_coord(cmd['dest']['row'], cmd['dest']['bay'], cmd['dest']['level'])
            targetDests[cmd['id']] = destCoord
    
    # Prepare Sequence Vector
    for pid in fixed_seq_ids:
        sequence.push_back(pid)
    
    print(f"Running Fixed Sequence Solver with {sequence.size()} targets...")
    
    # 2. Run Solver (Once)
    cdef vector[MissionLog] finalLogs = solveAndRecord(initialYard, sequence, targetDests)
    
    # 3. Convert Results
    py_logs = []
    for log in finalLogs:
        pl = PyMissionLog()
        pl.mission_no = log.mission_no
        pl.agv_id = log.agv_id
        pl.container_id = log.container_id
        
        if log.type_code == 0: pl.mission_type = "target"
        elif log.type_code == 1: pl.mission_type = "reshuffle"
        else: pl.mission_type = "return"
        
        pl.src = (log.src.row, log.src.bay, log.src.tier)
        pl.dst = (log.dst.row, log.dst.bay, log.dst.tier)
        pl.start_time = log.start_time_epoch
        pl.end_time = log.end_time_epoch
        pl.makespan = log.makespan_snapshot
        py_logs.append(pl)
        
    return py_logs