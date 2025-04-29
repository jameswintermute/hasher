#!/bin/bash
cores=`cat /proc/cpuinfo | grep processor | wc -l`
multiplier=$(( 4* $cores ))

filename='hasher-'`date +"%Y-%m-%d"`'.txt'

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

# pwd
PWD=$(pwd)

# File
TYPE=$(file "$FILE" -b)

# Compute sha256sum
CHECKSUM=$(sha256sum "$FILE" | awk '{print $1}')

# Output result
for file in "$@"; do
    xargs -P $cores -L $multiplier -0 | echo "SHA256 of file:'$FILE',$CHECKSUM At:$DATE,Type:$TYPE,PWD:$PWD"
done

# Execute example:
# find . -type f -print0 | xargs -0 ./new.sh
