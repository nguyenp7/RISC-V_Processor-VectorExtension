/////////////////////////////////////////////////////////////////////////
//                                                                     //
//   Modulename :  mem_test.sv                                          //
//                                                                     //
//  Description :  Directed memory-tag saturation and rejected-store     //
//                 backpressure test.                                   //
//                                                                     //
/////////////////////////////////////////////////////////////////////////

`include "sys_defs.svh"

// Compile with +define+MEM_LATENCY_IN_CYCLES=32 (or -D...=32). This fills
// all fifteen tags and proves a rejected partial store has no side effects.
module mem_test;

    // ---- Clock and memory interface ---- //

    logic       clock = 0;
    always #5 clock = ~clock;

    ADDR        proc2mem_addr    = 0;
    MEM_BLOCK   proc2mem_data    = 0;
    MEM_SIZE    proc2mem_size    = DOUBLE;
    MEM_COMMAND proc2mem_command = MEM_NONE;
    MEM_TAG     mem2proc_transaction_tag, mem2proc_data_tag;
    MEM_BLOCK   mem2proc_data;

    // ---- Transaction scoreboard ---- //

    logic [15:1] accepted_tags = 0, returned_tags = 0;
    logic        track_responses = 0;
    integer      response_count = 0;

    mem memory (.*);

    always @(posedge clock)
        if (track_responses && mem2proc_data_tag != 0) begin
            if (returned_tags[mem2proc_data_tag])
                $fatal(1, "duplicate memory response");

            returned_tags[mem2proc_data_tag] = 1;
            response_count++;
        end

    // ---- Directed test sequence ---- //

    initial begin
        integer timeout;

        if (`MEM_LATENCY_IN_CYCLES < 24)
            $fatal(1, "mem_test requires memory latency >= 24");

        repeat (2) @(posedge clock);
        #1;
        memory.unified_memory['h100 >> 3] = 64'h1122334455667788;
        track_responses = 1;

        // Occupy every memory tag with a delayed load.
        for (int n = 0; n < 15; n++) begin
            proc2mem_command = MEM_LOAD;
            proc2mem_addr    = 32'(8*n);

            @(posedge clock);
            if (mem2proc_transaction_tag == 0 || accepted_tags[mem2proc_transaction_tag])
                $fatal(1, "memory did not accept fifteen distinct outstanding loads");

            accepted_tags[mem2proc_transaction_tag] = 1;
            #1;
        end

        // A rejected byte store must leave the original line unchanged.
        proc2mem_command = MEM_STORE;
        proc2mem_addr    = 'h101;
        proc2mem_data    = 'ha5;
        proc2mem_size    = BYTE;

        repeat (4) begin
            @(posedge clock);
            if (mem2proc_transaction_tag != 0)
                $fatal(1, "tag saturation unexpectedly accepted store");
            if (memory.unified_memory['h100 >> 3] !== 64'h1122334455667788)
                $fatal(1, "rejected store modified memory");
            #1;
        end

        // Keep the store asserted until a tag becomes available.
        timeout = 0;
        begin : wait_accept
            forever begin
                @(posedge clock);
                if (mem2proc_transaction_tag != 0) begin
                    if (memory.unified_memory['h100 >> 3] !== 64'h112233445566a588)
                        $fatal(1, "accepted byte store incorrect");

                    #1 proc2mem_command = MEM_NONE;
                    disable wait_accept;
                end
                #1;
                timeout++;
                if (timeout > 100)
                    $fatal(1, "store never accepted after tag release");
            end
        end

        // Every accepted load must return exactly once.
        while (response_count != 15) begin
            @(posedge clock);
            #1;
            timeout++;
            if (timeout > 100)
                $fatal(1, "lost outstanding memory response");
        end

        $display("PASS mem_test: fifteen tags saturated, rejected stores unchanged, fifteen responses");
        $finish;
    end

endmodule // mem_test
