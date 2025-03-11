#!/bin/bash

date > check

for f in \
  file1 \
  path/file2 \
  path/file3
do
  sha256sum $f >> check
done
