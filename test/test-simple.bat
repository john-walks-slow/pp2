@echo off
echo === BAT TEST SERVICE ===
echo PID: (no PID in batch)
echo CWD: %CD%
echo Args: %1 %2 %3
echo Env TEST_VAR: %TEST_VAR%
echo All args: %*
echo Running for 30 seconds...
timeout /t 30 /nobreak > nul