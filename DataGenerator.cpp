#include <iostream>
#include <fstream>
#include <vector>
#include <string>
#include <random>
#include <algorithm>
#include <ctime>
#include <cstdlib> // For std::atoi

// Define box structure
struct BoxData {
    int id;       // Represents parent_carrier_id
    int row;
    int bay;
    int level;
};

int main(int argc, char* argv[]) {
    // 1. Set default parameters
    int max_row = 6;
    int max_bay = 11;
    int max_level = 8;
    int total_boxes = 400;
    int mission_count = 50;

    // 2. Process command-line arguments
    if (argc == 1) {
        // No arguments provided, use default configuration
        std::cout << "No arguments provided. Using default configuration." << std::endl;
    } else if (argc == 6) {
        // User provided 5 arguments
        max_row = std::atoi(argv[1]);
        max_bay = std::atoi(argv[2]);
        max_level = std::atoi(argv[3]);
        total_boxes = std::atoi(argv[4]);
        mission_count = std::atoi(argv[5]);
    } else {
        // Incorrect number of arguments, display usage instructions
        std::cerr << "Usage: " << argv[0] << " <Rows> <Bays> <Levels> <TotalBoxes> <MissionCount>" << std::endl;
        std::cerr << "Example: " << argv[0] << " 6 11 8 400 50" << std::endl;
        std::cerr << "Or run without arguments to use defaults." << std::endl;
        return 1;
    }

    // 3. Safety Check: Is capacity sufficient?
    int capacity = max_row * max_bay * max_level;
    if (total_boxes > capacity) {
        std::cerr << "Error: Total boxes (" << total_boxes 
                  << ") exceeds yard capacity (" << capacity << ")!" << std::endl;
        return 1;
    }

    if (mission_count > total_boxes) {
        std::cerr << "Error: Mission count (" << mission_count 
                  << ") cannot be larger than total boxes (" << total_boxes << ")!" << std::endl;
        return 1;
    }

    // Display current configuration
    std::cout << "--- Generator Configuration ---" << std::endl;
    std::cout << "Grid Size    : " << max_row << " x " << max_bay << " x " << max_level << std::endl;
    std::cout << "Capacity     : " << capacity << " slots" << std::endl;
    std::cout << "Total Boxes  : " << total_boxes << " (" << (float)total_boxes/capacity*100.0 << "% full)" << std::endl;
    std::cout << "Missions     : " << mission_count << std::endl;
    std::cout << "-------------------------------" << std::endl;

    // 4. Initialize random number generator and variables
    std::mt19937 rng(static_cast<unsigned int>(std::time(nullptr)));
    std::uniform_int_distribution<int> distRow(0, max_row - 1);
    std::uniform_int_distribution<int> distBay(0, max_bay - 1);

    std::vector<int> heights(max_row * max_bay, 0);
    std::vector<BoxData> allBoxes;
    allBoxes.reserve(total_boxes);

    // 5. Generate boxes and place them randomly
    for (int i = 1; i <= total_boxes; ++i) {
        bool placed = false;
        // Safety Valve: If random placement takes too long (e.g., 99% density), switch to linear scan
        int attempts = 0;
        
        while (!placed) {
            int r, b, idx;

            if (attempts < 1000) {
                // Random position selection
                r = distRow(rng);
                b = distBay(rng);
                idx = r * max_bay + b;
                attempts++;
            } else {
                // Fill Mode (Linear Scan) - Prevent infinite loops
                bool foundSlot = false;
                for (int tr = 0; tr < max_row; ++tr) {
                    for (int tb = 0; tb < max_bay; ++tb) {
                        int tidx = tr * max_bay + tb;
                        if (heights[tidx] < max_level) {
                            r = tr; b = tb; idx = tidx;
                            foundSlot = true;
                            break;
                        }
                    }
                    if (foundSlot) break;
                }
                if (!foundSlot) {
                    std::cerr << "Critical Error: Cannot find slot even though capacity check passed." << std::endl;
                    return 1;
                }
            }

            if (heights[idx] < max_level) {
                allBoxes.push_back({i, r, b, heights[idx]});
                heights[idx]++;
                placed = true;
            }
        }
    }

    // 6. Output File A: Inventory Snapshot (mock_yard.csv)
    std::ofstream yardFile("mock_yard.csv");
    yardFile << "container_id,row,bay,level\n";
    for (const auto& box : allBoxes) {
        yardFile << box.id << "," << box.row << "," << box.bay << "," << box.level << "\n";
    }
    yardFile.close();

    // 7. Output File B: Retrieval Commands (mock_commands.csv)
    std::ofstream cmdFile("mock_commands.csv");
    cmdFile << "cmd_no,batch_id,cmd_type,cmd_priority,parent_carrier_id,"
            << "src_row,src_bay,src_level,"
            << "dest_row,dest_bay,dest_level,create_time\n";

    // Randomly select targets
    std::vector<BoxData> candidates = allBoxes;
    std::shuffle(candidates.begin(), candidates.end(), rng);

    int serialNo = 1;
    long long baseTime = 1705363200; 

    for (int i = 0; i < mission_count; ++i) {
        const auto& box = candidates[i];
        cmdFile << serialNo << ","                  // cmd_no
                << "20260117,"                      // batch_id
                << "target,"                        // cmd_type
                << serialNo << ","                  // cmd_priority
                << box.id << ","                    // parent_carrier_id
                << box.row << "," << box.bay << "," << box.level << "," 
                << "-1,-1,-1,"                      // dest
                << (baseTime + serialNo * 60)       // create_time
                << "\n";
        serialNo++;
    }
    cmdFile.close();

    // 8. Output File C: Configuration (yard_config.csv)
    std::ofstream configFile("yard_config.csv");
    // Write Header
    configFile << "max_row,max_bay,max_level,total_boxes\n";
    // Write Data
    configFile << max_row << "," 
               << max_bay << "," 
               << max_level << "," 
               << total_boxes << "\n";
    configFile.close();

    std::cout << "Success! Generated files:\n"
              << "1. mock_yard.csv (Layout)\n"
              << "2. mock_commands.csv (Missions)\n"
              << "3. yard_config.csv (Dimensions)" << std::endl;

    return 0;
}