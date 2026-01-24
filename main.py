import csv
import time
import bs_solver # Beam Search
import mcts_solver # Monte Carlo Tree Search

def load_csv_data():
    # 1. Load Config
    config = {}
    with open('yard_config.csv', 'r') as f:
        reader = csv.DictReader(f)
        row = next(reader)
        config['max_row'] = int(row['max_row'])
        config['max_bay'] = int(row['max_bay'])
        config['max_level'] = int(row['max_level'])
        config['total_boxes'] = int(row['total_boxes'])
        config['t_travel'] = float(row.get('time_travel_unit', 5.0))
        config['t_handle'] = float(row.get('time_handle', 30.0))
        config['t_process'] = float(row.get('time_process', 10.0))

    # 2. Load Yard
    boxes = []
    with open('mock_yard.csv', 'r') as f:
        reader = csv.DictReader(f)
        for row in reader:
            boxes.append({
                'id': int(row['container_id']),
                'row': int(row['row']),
                'bay': int(row['bay']),
                'level': int(row['level'])
            })

    # 3. Load Commands (Only for destination info now)
    commands = []
    with open('mock_commands.csv', 'r') as f:
        reader = csv.DictReader(f)
        for row in reader:
            try:
                dr = int(row['dest_row'])
                db = int(row['dest_bay'])
                dl = int(row['dest_level'])
            except:
                dr, db, dl = -1, -1, 1

            commands.append({
                'id': int(row['parent_carrier_id']),
                'type': row['cmd_type'],
                'dest': {'row': dr, 'bay': db, 'level': dl}
            })
            
    return config, boxes, commands

# 1. Fixed Sequence provided by user
job_sequence = [
    398, 61, 262, 185, 373, 3, 133, 387, 4, 328, 
    361, 103, 62, 240, 126, 340, 122, 32, 226, 271, 
    190, 98, 202, 309, 1, 167, 233, 110, 281, 246, 
    339, 395, 311, 250, 104, 332, 346, 356, 143, 350, 
    135, 151, 221, 375, 219, 193, 389, 50, 266, 268
]

def main():
    start_t = time.time()
    
    # 2. Load Data
    config, boxes, commands = load_csv_data()
    
    # 3. Configure Solver (bs/mcts)

    bs_solver.set_config(
        config['t_travel'], 
        config['t_handle'], 
        config['t_process'],
        3,   # AGV Count
        200  # Beam Width (Increased for single pass high quality)
    )

    # mcts_solver.set_config(
    #     config['t_travel'], 
    #     config['t_handle'], 
    #     config['t_process'],
    #     3 # AGV Count
    # )

    # 4. Run Solver with Fixed Sequence
    print(f"Starting Solver with {len(job_sequence)} fixed jobs...")
    logs = bs_solver.run_fixed_solver(config, boxes, commands, job_sequence)
    # logs = mcts_solver.run_mcts_solver(config, boxes, commands, job_sequence, iterations=50000)
    
    # 5. Output
    with open('output_missions_python.csv', 'w', newline='') as f:
        writer = csv.writer(f)
        writer.writerow(["mission_no", "agv_id", "mission_type", "container_id", "related_target_id", "src_pos", "dst_pos", "start_time", "end_time", "makespan"])
        
        for log in logs:
            if log.src[0] == -1:
                s_str = f"work station (Port {log.src[2]})"
            else:
                s_str = f"({log.src[0]};{log.src[1]};{log.src[2]})"
            
            if log.dst[0] == -1:
                d_str = f"work station (Port {log.dst[2]})"
            else:
                d_str = f"({log.dst[0]};{log.dst[1]};{log.dst[2]})"

            writer.writerow([
                log.mission_no,
                log.agv_id,
                log.mission_type,
                log.container_id,
                log.related_target_id,
                s_str,
                d_str,
                log.start_time,
                log.end_time,
                log.makespan
            ])

    end_t = time.time()
    print(f"Total Time: {end_t - start_t:.2f}s")
    if logs:
        print(f"Final Makespan: {logs[-1].makespan:.2f}s")

if __name__ == "__main__":
    main()