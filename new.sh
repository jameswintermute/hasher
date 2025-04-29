#!/bin/bash

# Check if a file is provided
if [ -z "$1" ]; then
  echo "Usage: $0 <filename>"
  exit 1
fi

FILE="$1" 

# Check if the file exists
if [ ! -f "$FILE" ]; then
  echo "Error: File '$FILE' not found!"
  exit 1
fi

# Get current date
DATE=$(date +"%Y-%m-%d %H:%M:%S")

# File
TYPE=$(file "$FILE" -b)

#MACB
STAT=$(stat "$FILE" -x -y -z)

# Compute sha256sum
CHECKSUM=$(sha256sum "$FILE" | awk '{print $1}')

# Output result
echo "Checksum of file:'$FILE',$CHECKSUM At: $DATE, $TYPE, $STAT"
