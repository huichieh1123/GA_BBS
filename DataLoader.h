#ifndef DATALOADER_H
#define DATALOADER_H

#include <iostream>
#include <fstream>
#include <sstream>
#include <vector>
#include <string>

// 1. Coordinate Structure
struct Coord3D {
    int row;
    int bay;
    int level;
};

// 2. Mock Command Structure
struct Command {
    int cmd_no;             // Serial Number
    int batch_id;           // Batch Identifier
    std::string cmd_type;   // target / block
    int cmd_priority;       // Execution Sequence
    int parent_carrier_id;  // Container ID
    Coord3D source_position;
    Coord3D dest_position;  // Workstation (-1) or Null
    long long create_time;
};

// 3. Yard Snapshot Structure
struct BoxSnapshot {
    int container_id;
    int row;
    int bay;
    int level;
};

// 4. Configuration Structure (New)
struct YardConfig {
    int max_row;
    int max_bay;
    int max_level;
    int total_boxes;
};

class DataLoader {
public:
    // Load Yard Snapshot (mock_yard.csv)
    static std::vector<BoxSnapshot> loadYardSnapshot(const std::string& filename) {
        std::vector<BoxSnapshot> boxes;
        std::ifstream file(filename);
        std::string line;
        
        // Skip Header
        std::getline(file, line); 

        while (std::getline(file, line)) {
            if (line.empty()) continue;
            std::stringstream ss(line);
            std::string segment;
            BoxSnapshot box;

            std::getline(ss, segment, ','); box.container_id = std::stoi(segment);
            std::getline(ss, segment, ','); box.row = std::stoi(segment);
            std::getline(ss, segment, ','); box.bay = std::stoi(segment);
            std::getline(ss, segment, ','); box.level = std::stoi(segment);

            boxes.push_back(box);
        }
        return boxes;
    }

    // Load Commands (mock_commands.csv)
    static std::vector<Command> loadCommands(const std::string& filename) {
        std::vector<Command> commands;
        std::ifstream file(filename);
        std::string line;

        // Skip Header
        std::getline(file, line);

        while (std::getline(file, line)) {
            if (line.empty()) continue;
            std::stringstream ss(line);
            std::string segment;
            Command cmd;

            // 1. cmd_no
            std::getline(ss, segment, ','); cmd.cmd_no = std::stoi(segment);
            
            // 2. batch_id
            std::getline(ss, segment, ','); cmd.batch_id = std::stoi(segment);
            
            // 3. cmd_type
            std::getline(ss, cmd.cmd_type, ',');
            
            // 4. cmd_priority
            std::getline(ss, segment, ','); cmd.cmd_priority = std::stoi(segment);
            
            // 5. parent_carrier_id
            std::getline(ss, segment, ','); cmd.parent_carrier_id = std::stoi(segment);
            
            // 6. source_position (x, y, z)
            std::getline(ss, segment, ','); cmd.source_position.row = std::stoi(segment);
            std::getline(ss, segment, ','); cmd.source_position.bay = std::stoi(segment);
            std::getline(ss, segment, ','); cmd.source_position.level = std::stoi(segment);

            // 7. dest_position (x, y, z)
            try {
                std::getline(ss, segment, ','); cmd.dest_position.row = std::stoi(segment);
                std::getline(ss, segment, ','); cmd.dest_position.bay = std::stoi(segment);
                std::getline(ss, segment, ','); cmd.dest_position.level = std::stoi(segment);
            } catch (...) {
                cmd.dest_position = {-1, -1, -1};
            }

            // 8. create_time
            std::getline(ss, segment, ','); 
            if (!segment.empty()) cmd.create_time = std::stoll(segment);
            else cmd.create_time = 0;

            commands.push_back(cmd);
        }
        return commands;
    }

    // Load Yard Configuration (yard_config.csv)
    static YardConfig loadYardConfig(const std::string& filename) {
        std::ifstream file(filename);
        YardConfig config = {0, 0, 0, 0}; // Default failure value
        
        if (!file.is_open()) return config;

        std::string line;
        // Skip Header
        std::getline(file, line);
        
        // Read Data
        if (std::getline(file, line)) {
            std::stringstream ss(line);
            std::string segment;
            
            try {
                std::getline(ss, segment, ','); config.max_row = std::stoi(segment);
                std::getline(ss, segment, ','); config.max_bay = std::stoi(segment);
                std::getline(ss, segment, ','); config.max_level = std::stoi(segment);
                std::getline(ss, segment, ','); config.total_boxes = std::stoi(segment);
            } catch (...) {
                // Parse error, return default 0s
            }
        }
        return config;
    }
};

#endif