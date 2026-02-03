╔══════════════════════════════════════════════════════════════════════════╗
║                    PROCESS CONTROL QUICK REFERENCE                       ║
╚══════════════════════════════════════════════════════════════════════════╝

TO START AND STOP PROCESSES:
════════════════════════════

1. Start the system:
   $ ./run.sh start

2. Launch interactive client:
   $ ./run.sh interactive

3. Select a server (type 1, 2, or 3)

4. You'll see a live dashboard with processes - NOTE THE PIDs!

5. Press Ctrl+C to open menu:
   ┌─────────────────────────────────┐
   │  Process Management Menu        │
   │─────────────────────────────────│
   │  1. Stop a process              │
   │  2. Start a new process         │
   │  3. Return to monitoring        │
   │  4. Quit                        │
   └─────────────────────────────────┘

6. To STOP a process:
   - Choose option 1
   - Enter the PID from the dashboard
   - Done! (sends SIGTERM, then SIGKILL if needed)

7. To START a process:
   - Choose option 2
   - Enter command (e.g., "sleep 300" or "python script.py")
   - Done! Process runs in background

8. Choose option 3 to return to monitoring


EXAMPLE SESSION:
═══════════════

$ ./run.sh interactive

Available Servers:
  1. server1 (server1:9001)
  2. server2 (server2:9001)
  3. server3 (server3:9001)

Select server (number): 1

[Dashboard shows:]
Top Processes:
#   PID      Name         CPU%    MEM%    Status
1   1234     python       45.2    12.3    running   ← Note this PID!
2   5678     sleep        0.1     0.5     sleeping
...

[Press Ctrl+C]

Process Management Menu
------------------------------
1. Stop a process
2. Start a new process
3. Return to monitoring
4. Quit

Select option (1-4): 1

Stop Process
Enter the PID of the process to stop (or 'c' to cancel):
PID: 1234

✓ Process python (PID: 1234) terminated successfully

[Press 3 to return to monitoring - python process is now gone!]


TWO MODES EXPLAINED:
═══════════════════

View-Only Mode:              Interactive Mode:
$ ./run.sh client           $ ./run.sh interactive
  ✓ View metrics              ✓ View metrics
  ✗ No process control        ✓ Start processes
  Ctrl+C = Quit               ✓ Stop processes
                              Ctrl+C = Menu


COMMON COMMANDS TO START:
════════════════════════

sleep 300                    # Sleep for 5 minutes
python script.py             # Run a Python script
python -m http.server 8080   # Start web server
bash /path/to/script.sh      # Run shell script
top -b -n 1                  # Run top command once


TROUBLESHOOTING:
═══════════════

Q: I don't see a process control menu!
A: Use ./run.sh interactive (NOT ./run.sh client)

Q: "Process not found" error
A: Check the PID is correct from the Top Processes panel

Q: "Access denied" when stopping process
A: Process may belong to another user - check username column

Q: Command not found when starting
A: Use full path (/usr/bin/python) or check if available in container


QUICK TIPS:
══════════

• Top Processes panel shows PIDs sorted by CPU usage
• Type 'c' to cancel when prompted for PID/command
• Process stop tries SIGTERM first, then SIGKILL after 3s
• Started processes run detached in background
• You can monitor multiple servers in different terminals
• Check logs with: ./run.sh logs


═══════════════════════════════════════════════════════════════════════════
Need more details? See PROCESS_CONTROL.md for complete documentation
═══════════════════════════════════════════════════════════════════════════
