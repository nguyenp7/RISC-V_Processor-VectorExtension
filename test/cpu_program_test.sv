`include "sys_defs.svh"

// DPI-free runner for assembled programs. The Python regression generates an
// independent RV32IM retirement trace and complete final memory image.
module cpu_program_test;

    // Clock and processor interfaces.
    logic clock = 0, reset = 1;
    always #5 clock = ~clock;
    MEM_TAG accept_tag, response_tag;
    MEM_BLOCK response_data, write_data;
    MEM_COMMAND command;
    MEM_SIZE size;
    ADDR address;
    COMMIT_PACKET [`N - 1:0] commits;
    cpu dut (
        .clock(clock),
        .reset(reset),
        .mem2proc_transaction_tag(accept_tag),
        .mem2proc_data(response_data),
        .mem2proc_data_tag(response_tag),
        .proc2mem_command(command),
        .proc2mem_addr(address),
        .proc2mem_data(write_data),
        .proc2mem_size(size),
        .committed_insts(commits),
        .if_NPC_dbg(),
        .if_inst_dbg(),
        .if_valid_dbg(),
        .if_id_NPC_dbg(),
        .if_id_inst_dbg(),
        .if_id_valid_dbg(),
        .id_ex_NPC_dbg(),
        .id_ex_inst_dbg(),
        .id_ex_valid_dbg(),
        .ex_mem_NPC_dbg(),
        .ex_mem_inst_dbg(),
        .ex_mem_valid_dbg(),
        .mem_wb_NPC_dbg(),
        .mem_wb_inst_dbg(),
        .mem_wb_valid_dbg()
    );

    mem memory (
        .clock(clock),
        .proc2mem_addr(address),
        .proc2mem_data(write_data),
        .proc2mem_size(size),
        .proc2mem_command(command),
        .mem2proc_transaction_tag(accept_tag),
        .mem2proc_data(response_data),
        .mem2proc_data_tag(response_tag)
    );

    logic [63:0] expected_memory[0:`MEM_64BIT_LINES - 1];
    string image_file, trace_file, final_file;
    integer trace_handle, count = 0, cycles = 0, scanned;
    DATA expected_pc, expected_rd, expected_data, expected_halt;
    logic done = 0;

    // Fixture loading and reset.
    initial begin
        if (!$value$plusargs("MEMORY=%s", image_file) || !$value$plusargs("TRACE=%s", trace_file) ||
            !$value$plusargs("FINAL=%s", final_file))
            $fatal(1, "MEMORY TRACE FINAL required");
        @(posedge clock);
        @(posedge clock);
        #1;
        $readmemh(image_file, memory.unified_memory);
        $readmemh(final_file, expected_memory);
        trace_handle = $fopen(trace_file, "r");
        if (trace_handle == 0)
            $fatal(1, "cannot open trace %s", trace_file);
        repeat (2) @(posedge clock);
        #1 reset = 0;
    end

    // Retirement trace and final-memory checks.
    always @(negedge clock)
        if (!reset) begin
            #2;
            cycles++;
            for (int lane = 0; lane < `N; lane++)
                if (commits[lane].valid) begin
                    if (done)
                        $fatal(1, "retirement after termination");
                    scanned = $fscanf(trace_handle, "%h %h %h %h\n", expected_pc, expected_rd,
                                      expected_data, expected_halt);
                    if (scanned != 4)
                        $fatal(1, "extra/invalid retirement at %h", commits[lane].NPC - 4);
                    if (commits[lane].NPC - 4 != expected_pc ||
                        int'(commits[lane].reg_idx) != int'(expected_rd) ||
                        (expected_rd != 0 && commits[lane].data != expected_data) ||
                        DATA'(commits[lane].halt) != expected_halt || commits[lane].illegal)
                        $fatal(
                            1,
                            "retirement%0d expected PC%h x%0d=%h halt%0d got PC%h x%0d=%h halt%0d illegal%0d",
                            count, expected_pc, expected_rd, expected_data, expected_halt,
                            commits[lane].NPC - 4, commits[lane].reg_idx, commits[lane].data,
                            commits[lane].halt, commits[lane].illegal);
                    count++;
                    if (commits[lane].halt)
                        done = 1;
                end
            if (done) begin
                scanned = $fscanf(trace_handle, "%h", expected_pc);
                if (scanned == 1)
                    $fatal(1, "missing retirement records");
                for (int line = 0; line < `MEM_64BIT_LINES; line++)
                    if (memory.unified_memory[line] !== expected_memory[line])
                        $fatal(1, "memory %h expected %h got %h", line * 8, expected_memory[line],
                               memory.unified_memory[line]);
                $display("PASS cpu_program_test program=%s commits=%0d cycles=%0d", image_file,
                         count, cycles);
                $fclose(trace_handle);
                $finish;
            end
            if (cycles > 2000000)
                $fatal(1, "timeout after%0d commits", count);
        end
endmodule
