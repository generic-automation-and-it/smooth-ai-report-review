#!/bin/bash
# Intersect two NUL-delimited file lists while preserving NUL delimiters.
if [ "$#" -ne 3 ]; then
  echo "Usage: $0 <file_list_a> <file_list_b> <output_file>" >&2
  exit 1
fi

input_a="$1"
input_b="$2"
output_file="$3"

comm -z -12 \
  <(sort -z < "$input_a") \
  <(sort -z < "$input_b") \
  > "$output_file"
