#!/bin/bash

echo "Comparing ground truth outputs to new processor"

cd ~/eecs472/p2

program="$1"

echo "Running $program"

# Run the program on your processor
make "$program.out"

# Compare writeback output
diff "output/$program.wb" "correct_out/$program.wb" > /dev/null
wb_result=$?

# Get the @@@ memory lines from both files
grep "^@@@" "output/$program.out" > /tmp/new_memory.out
grep "^@@@" "correct_out/$program.out" > /tmp/ground_truth_memory.out

# Compare memory output
diff /tmp/new_memory.out /tmp/ground_truth_memory.out > /dev/null
memory_result=$?

echo
echo "Results:"
if [ $wb_result -eq 0 ]; then 
    echo "$program: WB Passed" 
else 
    echo "$program: WB Failed" 
fi

if [ $memory_result -eq 0 ]; then 
    echo "$program: Out Passed" 
else 
    echo "$program: Out Failed" 
fi

