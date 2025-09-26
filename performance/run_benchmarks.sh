#!/bin/bash

# Performance benchmark runner comparing Etch and Python
echo "==== Etch vs Python Performance Benchmarks ===="
echo "Date: $(date)"
echo

benchmarks=(
    "arithmetic_operations"
    "nested_loops"
    "array_operations"
    "function_calls"
    "string_operations"
    "math_intensive"
    "memory_allocation"
    "for_loop_print"
)

for bench in "${benchmarks[@]}"; do
    echo "--- Running $bench ---"

    if [[ -f "${bench}.etch" ]]; then
        echo -n "Etch:   "
        time nim r ../src/etch.nim --run "${bench}.etch" > /dev/null
    fi

    if [[ -f "${bench}.py" ]]; then
        echo -n "Python: "
        time python3 "${bench}.py" > /dev/null
    fi

    echo
done

echo "==== Benchmark Complete ===="