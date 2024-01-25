import multiprocessing
import pathlib
import os
import sys
import hashlib

# https://stackoverflow.com/questions/22058048/hashing-a-file-in-python

# Count the number of CPU cores:
CPUs = multiprocessing.cpu_count()
# print(CPUs)

# Show current path:
pathlib.Path().resolve()
print("Your current path ", pathlib.Path().resolve())

# Input the file path
file_path = input("Enter file path you'd like to has from: ")
print(file_path)

if not os.path.exists(file_path):
    print("Path of the file is Invalid")

# see https://bobbyhadz.com/blog/python-input-file-path
