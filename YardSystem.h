#ifndef YARDSYSTEM_H
#define YARDSYSTEM_H

#include <vector>
#include <iostream>
#include <algorithm>

// 座標結構
struct Coordinate {
    int row; // x
    int bay; // y
    int tier; // z

    bool operator==(const Coordinate& other) const {
        return row == other.row && bay == other.bay && tier == other.tier;
    }
};

class YardSystem {
public: // <--- [關鍵修改] 將所有成員變數移到 public，讓 main.cpp 可以直接存取
    
    // 資料結構 1: 3D Matrix (空間查箱子)
    std::vector<std::vector<std::vector<int>>> grid;

    // 資料結構 2: Lookup Table (箱子查空間)
    std::vector<Coordinate> boxLocations;

    // 輔助結構: 每個柱子目前的高度 (Top Cache)
    std::vector<std::vector<int>> tops;

    // 環境參數
    int MAX_ROWS;
    int MAX_BAYS;
    int MAX_TIERS;

    // [必要] 預設建構子 (為了解決 vector resize 錯誤)
    YardSystem() : MAX_ROWS(0), MAX_BAYS(0), MAX_TIERS(0) {}

    // 主要建構子
    YardSystem(int rows, int bays, int tiers, int totalBoxes) 
        : MAX_ROWS(rows), MAX_BAYS(bays), MAX_TIERS(tiers) {
        
        // 初始化 Matrix (全為 0)
        grid.resize(rows, std::vector<std::vector<int>>(bays, std::vector<int>(tiers, 0)));
        
        // 初始化 Lookup Table (預留空間)
        boxLocations.resize(totalBoxes + 1, {-1, -1, -1}); 
        
        // 初始化高度表
        tops.resize(rows, std::vector<int>(bays, 0));
    }

    // 1. 初始化放置箱子
    void initBox(int boxId, int r, int b, int t) {
        if (r >= MAX_ROWS || b >= MAX_BAYS || t >= MAX_TIERS) return;

        grid[r][b][t] = boxId;
        boxLocations[boxId] = {r, b, t};
        
        if (t + 1 > tops[r][b]) {
            tops[r][b] = t + 1;
        }
    }

    // 2. 移動箱子
    bool moveBox(int fromRow, int fromBay, int toRow, int toBay) {
        if (tops[fromRow][fromBay] == 0) return false;
        if (tops[toRow][toBay] >= MAX_TIERS) return false;

        int currentTier = tops[fromRow][fromBay] - 1; 
        int boxId = grid[fromRow][fromBay][currentTier];
        int targetTier = tops[toRow][toBay];

        // 更新 Matrix
        grid[fromRow][fromBay][currentTier] = 0; 
        grid[toRow][toBay][targetTier] = boxId; 

        // 更新 Lookup Table
        boxLocations[boxId] = {toRow, toBay, targetTier};

        // 更新高度緩存
        tops[fromRow][fromBay]--;
        tops[toRow][toBay]++;

        return true;
    }

    // 3. 取出箱子
    void removeBox(int boxId) {
        if (boxId >= boxLocations.size()) return;
        Coordinate pos = boxLocations[boxId];
        if (pos.row == -1) return;

        if (pos.tier == tops[pos.row][pos.bay] - 1) {
            grid[pos.row][pos.bay][pos.tier] = 0;
            tops[pos.row][pos.bay]--;
            boxLocations[boxId] = {-1, -1, -1}; 
        }
    }

    // --- 查詢 API ---

    Coordinate getBoxPosition(int boxId) const {
        if (boxId >= boxLocations.size()) return {-1, -1, -1};
        return boxLocations[boxId];
    }

    std::vector<int> getBlockingBoxes(int boxId) const {
        std::vector<int> blockers;
        if (boxId >= boxLocations.size()) return blockers;
        
        Coordinate pos = boxLocations[boxId];
        if (pos.row == -1) return blockers; 

        int topTier = tops[pos.row][pos.bay];
        for (int t = pos.tier + 1; t < topTier; ++t) {
            blockers.push_back(grid[pos.row][pos.bay][t]);
        }
        return blockers;
    }

    bool canReceiveBox(int r, int b) const {
        if (r < 0 || r >= MAX_ROWS || b < 0 || b >= MAX_BAYS) return false;
        return tops[r][b] < MAX_TIERS;
    }

    bool isTop(int boxId) const {
        if (boxId >= boxLocations.size()) return false;
        Coordinate pos = boxLocations[boxId];
        if (pos.row == -1) return true; // 視為已取出

        return pos.tier == (tops[pos.row][pos.bay] - 1);
    }
};

#endif // YARDSYSTEM_H