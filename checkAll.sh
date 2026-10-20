echo "Comparing ground truth outputs to new processor"

cd ~/eecs472/p2

for source_file in programs/*.s programs/*.c; do

    if [ "$source_file" = "programs/crt.s" ]; then
        continue
    fi

    program=$(echo "$source_file" | cut -d '.' -f 1 | cut -d '/' -f 2)

    echo "Running $program"
    
    # Compare writeback output
    diff "output/$program.wb" "correct_out/$program.wb" > /dev/null
    wb_result=$?

    # Get the @@@ memory lines from both files
    grep "^@@@" "output/$program.out" > /tmp/new_memory.out
    grep "^@@@" "correct_out/$program.out" > /tmp/ground_truth_memory.out

    # Compare memory output
    diff /tmp/new_memory.out /tmp/ground_truth_memory.out > /dev/null
    memory_result=$?

    if [ $wb_result -eq 0 ]; then 
         results="$results$program: WB Passed\n" 
    else 
         results="$results$program: WB Failed\n" 
    fi

    if [ $memory_result -eq 0 ]; then 
         results="$results$program: Out Passed\n" 
    else 
         results="$results$program: Out Failed\n" 
    fi


done

echo
echo "Results:"
printf "$results"