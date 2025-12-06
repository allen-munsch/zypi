#!/bin/sh
echo "Hello from Zypi!"
echo "Container ID: $(hostname)"
echo "Time: $(date)"
while true; do sleep 30; echo "Still running..."; done
