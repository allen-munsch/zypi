#!/usr/bin/env python3
# hello.py

import time
import socket
import os
from datetime import datetime

print("Hello from Zypi, but with python!")
print(f"Container ID: {socket.gethostname()}")
print(f"Time: {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}")
print(f"Python Version: {os.sys.version}")
print(f"Process ID: {os.getpid()}")

counter = 0
while True:
    counter += 1
    print(f"Still running... loop #{counter}")
    time.sleep(10)