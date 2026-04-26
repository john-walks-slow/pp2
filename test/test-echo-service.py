#!/usr/bin/env python3
"""
Test service - prints environment, args, cwd to verify correct passing
"""
import sys
import os
import json
import time

def main():
    result = {
        "args": sys.argv[1:] if len(sys.argv) > 1 else [],
        "env": dict(os.environ),
        "cwd": os.getcwd(),
        "pid": os.getpid()
    }
    
    # Print structured output for test verification
    print("=== TEST SERVICE START ===")
    print(json.dumps(result, indent=2))
    print("=== TEST SERVICE END ===")
    
    # Keep running for 30 seconds or until stopped
    print(f"Running for 30 seconds (PID: {os.getpid()})...")
    time.sleep(30)
    print("Service finished normally")

if __name__ == "__main__":
    main()