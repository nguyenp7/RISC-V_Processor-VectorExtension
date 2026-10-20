/////////////////////////////////////////////////////////////////////////
//                                                                     //
//   Modulename :  icache_test.sv                                       //
//                                                                     //
//  Description :  Instruction-cache refill, redirect, and invalidation   //
//                 tests using a tagged backing-memory model.            //
//                                                                     //
/////////////////////////////////////////////////////////////////////////

`include "sys_defs.svh"

module icache_test;

    // ---- Clock and cache interface ---- //

    logic clock = 0;
    always #5 clock = ~clock;

    logic       reset = 1, request_valid = 0, invalidate = 0;
    MEM_TAG     Imem2proc_transaction_tag = 0, Imem2proc_data_tag = 0;
    MEM_BLOCK   Imem2proc_data, Icache_data_out;
    ADDR        proc2Icache_addr = 0, proc2Imem_addr;
    MEM_COMMAND proc2Imem_command;
    logic       Icache_valid_out;

    // ---- Backing-memory state ---- //

    integer   latency      = 0;
    integer   transactions = 0;
    integer   clocks_left  [1:15];
    logic     active       [1:15];
    MEM_BLOCK saved_data   [1:15];

    icache #(.LINES(8)) dut (.*);

    // ---- Expected line data ---- //

    function automatic MEM_BLOCK expected(input ADDR address);
        MEM_BLOCK line_data;

        begin
            line_data = {32'h80000000 ^ {address[31:3], 3'b0},
                         32'h40000000 ^ {address[31:3], 3'b0}};
            return line_data;
        end
    endfunction

    // ---- Tagged backing-memory model ---- //
    // Multiple physical memory tags are necessary here because invalidate may
    // abandon a pending instruction fetch and start a different fetch.

    always @(negedge clock) begin
        logic bus_used, accepted;

        Imem2proc_transaction_tag = 0;
        Imem2proc_data_tag        = 0;
        bus_used                 = 0;
        accepted                 = 0;

        for (int tag = 1; tag <= 15; tag++) begin
            if (active[tag]) begin
                if (clocks_left[tag] > 0)
                    clocks_left[tag]--;

                if (clocks_left[tag] == 0 && !bus_used) begin
                    Imem2proc_data_tag = MEM_TAG'(tag);
                    Imem2proc_data     = saved_data[tag];
                    active[tag]       = 0;
                    bus_used          = 1;
                end
            end else if (!reset && proc2Imem_command == MEM_LOAD && !accepted) begin
                accepted                 = 1;
                Imem2proc_transaction_tag = MEM_TAG'(tag);
                transactions++;
                saved_data[tag] = expected(proc2Imem_addr);

                if (latency == 0 && !bus_used) begin
                    Imem2proc_data_tag = MEM_TAG'(tag);
                    Imem2proc_data     = saved_data[tag];
                    bus_used          = 1;
                end else begin
                    active[tag]      = 1;
                    clocks_left[tag] = latency;
                end
            end
        end
    end

    // ---- Fetch request driver ---- //

    task automatic fetch(input ADDR address);
        integer timeout;

        begin
            @(negedge clock);
            #1;
            request_valid    = 1;
            proc2Icache_addr = address;
            timeout          = 0;

            begin : wait_fetch
                forever begin
                    @(posedge clock);
                    if (Icache_valid_out) begin
                        if (Icache_data_out !== expected(address))
                            $fatal(1, "wrong refill/fetch address: %x data %x",
                                   address, Icache_data_out);
                        #1;
                        request_valid = 0;
                        disable wait_fetch;
                    end
                    #1;
                    timeout++;
                    if (timeout > 100)
                        $fatal(1, "instruction fetch lost");
                end
            end
        end
    endtask

    // ---- Directed test sequence ---- //

    initial begin
        Imem2proc_data = 0;
        for (int tag = 1; tag <= 15; tag++) begin
            active[tag]      = 0;
            clocks_left[tag] = 0;
            saved_data[tag]  = 0;
        end

        repeat (3) @(posedge clock);
        #1 reset = 0;

        // Both words of a resident instruction line share one refill.
        fetch('h0);
        fetch('h4);
        if (transactions != 1)
            $fatal(1, "same-line instruction hit missed");

        latency = 5;
        @(negedge clock);
        #1;
        request_valid    = 1;
        proc2Icache_addr = 'h40;
        @(negedge clock);
        #1;
        @(posedge clock);
        #1; // Accepted line 0x40 is now pending.
        proc2Icache_addr = 'h48;

        // Redirect while a miss is outstanding. The old fill must keep its
        // original tag/index, and the new fetch must fetch the new line.
        begin
            integer timeout;

            timeout = 0;
            while (!Icache_valid_out) begin
                @(posedge clock);
                #1;
                timeout++;
                if (timeout > 100)
                    $fatal(1, "redirect stalled");
            end
            if (Icache_data_out !== expected('h48))
                $fatal(1, "redirect mis-tagged old fill");
        end

        request_valid = 0;
        fetch('h40);
        if (transactions != 3)
            $fatal(1, "old redirected fill not retained correctly");

        // Cancel a pending fill. Its later response must not repopulate an
        // invalidated line or become the data for the replacement request.
        @(negedge clock);
        #1;
        request_valid    = 1;
        proc2Icache_addr = 'h80;
        @(negedge clock);
        #1;
        @(posedge clock);
        #1;
        invalidate = 1;
        @(posedge clock);
        #1;
        invalidate       = 0;
        proc2Icache_addr = 'h88;

        begin
            integer timeout;

            timeout = 0;
            while (!Icache_valid_out) begin
                @(posedge clock);
                #1;
                timeout++;
                if (timeout > 100)
                    $fatal(1, "invalidation replacement fetch stalled");
            end
            if (Icache_data_out !== expected('h88))
                $fatal(1, "stale fill consumed after invalidation");
        end

        request_valid = 0;
        begin
            integer before_fetch;

            before_fetch = transactions;
            fetch('h80);
            if (transactions != before_fetch+1)
                $fatal(1, "abandoned fill survived invalidation");
        end

        $display("PASS icache_test: %0d tagged transactions, redirects and invalidation",
                 transactions);
        $finish;
    end

endmodule // icache_test
