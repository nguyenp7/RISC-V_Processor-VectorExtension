/////////////////////////////////////////////////////////////////////////
//                                                                     //
//   Modulename :  dcache_test.sv                                       //
//                                                                     //
//  Description :  Data-cache dual-read, refill, partial-store, and       //
//                 backpressure tests with transaction scoreboards.      //
//                                                                     //
/////////////////////////////////////////////////////////////////////////

`include "sys_defs.svh"

module dcache_test;

    // ---- Clock and cache interface ---- //

    logic clock = 0;
    always #5 clock = ~clock;

    logic          reset = 1;
    logic [1:0]    rvalid, rready, rsp_valid;
    ADDR [1:0]     raddr;
    MEM_SIZE [1:0] rsize;
    DATA [1:0]     rdata;
    logic          wvalid, wready;
    ADDR           waddr;
    MEM_SIZE       wsize;
    DATA           wdata;
    MEM_COMMAND    mem_command;
    ADDR           mem_addr;
    MEM_BLOCK      mem_data, mem_data_in;
    MEM_SIZE       mem_size;
    MEM_TAG        mem_transaction_tag, mem_data_tag;

    // ---- Backing-memory state and scoreboards ---- //

    logic [7:0] backing [0:4095];
    logic       allow_accept        = 1;
    logic       random_backpressure = 0;
    integer     latency             = 0;
    integer     countdown           = 0;
    logic       pending             = 0;
    MEM_TAG     pending_tag, next_tag = 1;
    MEM_BLOCK   pending_data;
    integer     load_transactions = 0, store_transactions = 0;
    integer     read_completions = 0;
    integer     cycles = 0;

    dcache #(.LINES(8)) dut (.*);

    // ---- Expected access data ---- //

    function automatic DATA expected(input ADDR address, input MEM_SIZE size);
        DATA value;

        begin
            value = 0;
            for (int b = 0; b < 4; b++)
                if (b < (1 << size))
                    value[8*b +: 8] = backing[address + b];
            return value;
        end
    endfunction

    // ---- Tagged backing-memory model ---- //
    // One shared bus returns acceptance and data together for latency zero.
    // Other tests delay the response or reject requests before acceptance.

    always @(negedge clock) begin
        mem_transaction_tag = 0;
        mem_data_tag        = 0;
        cycles++;

        if (pending) begin
            countdown--;
            if (countdown == 0) begin
                mem_data_tag = pending_tag;
                mem_data_in  = pending_data;
                pending      = 0;
            end
        end

        if (!reset && allow_accept && (!random_backpressure || cycles % 3 != 0) &&
            mem_command != MEM_NONE) begin
            mem_transaction_tag = next_tag;
            if (next_tag == 15)
                next_tag = 1;
            else
                next_tag++;

            if (mem_command == MEM_LOAD) begin
                if (pending)
                    $fatal(1, "more than one outstanding refill");
                if (mem_addr[2:0] != 0 || mem_size != DOUBLE)
                    $fatal(1, "refill must request an aligned full line");

                load_transactions++;
                for (int b = 0; b < 8; b++)
                    pending_data.byte_level[b] = backing[mem_addr+b];

                if (latency == 0) begin
                    mem_data_tag = mem_transaction_tag;
                    mem_data_in  = pending_data;
                end else begin
                    pending     = 1;
                    pending_tag = mem_transaction_tag;
                    countdown   = latency;
                end
            end else begin
                store_transactions++;
                for (int b = 0; b < 4; b++)
                    if (b < (1 << mem_size))
                        backing[mem_addr+b] = mem_data[8*b +: 8];
            end
        end
    end

    // ---- Dual-read driver and completion checks ---- //

    task automatic reads(
        input ADDR a0,
        input ADDR a1,
        input MEM_SIZE s0,
        input MEM_SIZE s1,
        input logic require_parallel,
        input integer blocked_cycles = 0
    );
        logic [1:0] done;
        DATA [1:0]  want;
        integer     timeout, before_loads;

        begin
            @(negedge clock);
            #1;
            raddr[0]     = a0;
            raddr[1]     = a1;
            rsize[0]     = s0;
            rsize[1]     = s1;
            rvalid       = 2'b11;
            want[0]      = expected(a0, s0);
            want[1]      = expected(a1, s1);
            done         = 0;
            before_loads = load_transactions;
            allow_accept = blocked_cycles == 0;
            #1;

            if (require_parallel && rsp_valid != 2'b11)
                $fatal(1, "resident reads did not respond concurrently: %b", rsp_valid);
            if (a0 == 'h500 && rsp_valid != 2'b10)
                $fatal(1, "resident port did not hit under the other port's miss");

            repeat (blocked_cycles) begin
                @(posedge clock);
                if (rsp_valid != 0 || load_transactions != before_loads ||
                    mem_command != MEM_LOAD || mem_addr != (a0 & 32'hfffffff8))
                    $fatal(1, "refill request lost or changed during acceptance backpressure");
                #1;
            end

            allow_accept = 1;
            timeout      = 0;
            while (done != 2'b11) begin
                @(posedge clock);
                for (int p = 0; p < 2; p++) begin
                    if (rsp_valid[p]) begin
                        if (done[p] || !rvalid[p])
                            $fatal(1, "duplicate read response");
                        if (rdata[p] !== want[p])
                            $fatal(1, "port %0d addr %x got %x expected %x",
                                   p, raddr[p], rdata[p], want[p]);

                        done[p] = 1;
                        read_completions++;
                    end
                end
                if (rready !== rsp_valid)
                    $fatal(1, "ready/response mismatch");
                #1;
                rvalid = ~done;
                timeout++;
                if (timeout > 100)
                    $fatal(1, "read timeout (lost request/refill)");
            end
            #1;
            rvalid = 0;
        end
    endtask

    // ---- Hit during an accepted, delayed refill ---- //

    task automatic hit_during_pending_refill;
        integer timeout;

        begin
            latency = 5;
            @(negedge clock);
            #1;
            raddr[0] = 'hb00;
            rsize[0] = WORD;
            rvalid   = 2'b01;
            timeout  = 0;

            // Accept the miss before introducing a resident hit on port one.
            while (mem_transaction_tag == 0) begin
                @(posedge clock);
                timeout++;
                if (timeout > 100)
                    $fatal(1, "pending-refill acceptance timeout");
                #1;
            end

            raddr[1]  = 'ha08;
            rsize[1]  = WORD;
            rvalid[1] = 1;
            #1;
            if (rsp_valid != 2'b10 || rdata[1] !== expected('ha08, WORD))
                $fatal(1, "resident hit blocked by an outstanding refill");

            @(posedge clock);
            if (!rsp_valid[1])
                $fatal(1, "hit-under-refill response was lost");
            read_completions++;
            #1 rvalid[1] = 0;

            begin : finish_pending_read
                forever begin
                    @(posedge clock);
                    if (rsp_valid[0]) begin
                        if (rdata[0] !== expected('hb00, WORD))
                            $fatal(1, "pending read corrupted");
                        read_completions++;
                        #1 rvalid = 0;
                        disable finish_pending_read;
                    end
                    #1;
                    timeout++;
                    if (timeout > 100)
                        $fatal(1, "pending read lost after other-port hit");
                end
            end
        end
    endtask

    // ---- Store driver and write-priority checks ---- //

    task automatic store(
        input ADDR address,
        input MEM_SIZE size,
        input DATA value,
        input logic concurrent_reads,
        input integer blocked_cycles
    );
        integer timeout, before_stores;

        begin
            @(negedge clock);
            #1;
            before_stores = store_transactions;
            waddr         = address;
            wsize         = size;
            wdata         = value;
            wvalid        = 1;
            raddr[0]      = address & 32'hfffffff8;
            raddr[1]      = address & 32'hfffffff8;
            rsize[0]      = WORD;
            rsize[1]      = WORD;
            rvalid        = concurrent_reads ? 2'b11 : 2'b00;
            allow_accept  = blocked_cycles == 0;

            repeat (blocked_cycles) begin
                @(posedge clock);
                if (wready || rsp_valid != 0)
                    $fatal(1, "write priority/backpressure failed");
                #1;
            end

            allow_accept = 1;
            timeout      = 0;
            begin : wait_store
                forever begin
                    @(posedge clock);
                    if (rsp_valid != 0)
                        $fatal(1, "read completed during write-priority cycle");
                    if (wready) begin
                        #1;
                        wvalid = 0;
                        rvalid = 0;
                        disable wait_store;
                    end
                    #1;
                    timeout++;
                    if (timeout > 100)
                        $fatal(1, "store timeout");
                end
            end
            if (store_transactions != before_stores+1)
                $fatal(1, "lost/duplicate backing store");
        end
    endtask

    // ---- Directed and repeated test sequence ---- //

    initial begin
        rvalid              = 0;
        raddr               = 0;
        rsize[0]            = WORD;
        rsize[1]            = WORD;
        wvalid              = 0;
        waddr               = 0;
        wsize               = WORD;
        wdata               = 0;
        mem_transaction_tag = 0;
        mem_data_tag        = 0;
        mem_data_in         = 0;

        for (int b = 0; b < 4096; b++)
            backing[b] = 8'(b ^ (b >> 8));
        repeat (3) @(posedge clock);
        #1 reset = 0;

        // Independent cold misses, followed by two hits on distinct lines.
        reads('h100, 'h108, WORD, WORD, 0);
        if (load_transactions != 2)
            $fatal(1, "dual misses lost or duplicated a refill");
        reads('h100, 'h108, WORD, WORD, 1);
        reads('h100, 'h104, WORD, WORD, 1); // Same line and index.
        reads('h101, 'h102, BYTE, HALF, 1);

        // Both misses share one line; one refill must satisfy both ports.
        begin
            integer before_loads;

            before_loads = load_transactions;
            reads('h300, 'h304, WORD, WORD, 0);
            if (load_transactions != before_loads+1)
                $fatal(1, "same-line misses were not coalesced");
        end

        latency = 5;
        reads('h500, 'h108, WORD, WORD, 0); // Resident port one hit under port zero miss.
        reads('h400, 'h440, WORD, WORD, 0); // Different tags, same direct-map index.
        reads('h400, 'h448, WORD, WORD, 0); // Evict/refill; retain the unaffected line.

        // Partial stores, write priority, and rejected requests.
        reads('h100, 'h108, WORD, WORD, 0);
        store('h101, BYTE, 'ha5, 1, 3);
        reads('h100, 'h100, WORD, WORD, 1);
        store('h102, HALF, 'hbeef, 1, 0);
        reads('h100, 'h102, WORD, HALF, 1);
        store('h104, WORD, 'h12345678, 1, 0);
        reads('h104, 'h100, WORD, WORD, 1);
        store('h880, WORD, 'hdeadbeef, 0, 0); // Write-no-allocate.
        reads('h880, 'h884, WORD, WORD, 0);
        reads('ha00, 'ha08, WORD, WORD, 0, 3); // Hold both while the bus rejects requests.
        hit_during_pending_refill();

        // Repeated independent requests and changing memory latency exercise
        // tag reuse, partial stores, replacement, and acceptance backpressure.
        random_backpressure = 1;
        for (int n = 0; n < 80; n++) begin
            latency = n % 6;
            if (n % 4 == 0)
                store(32'h900 + 4*(n % 24), WORD, 32'h89abcdef ^ 32'(n), 0, 0);
            reads(32'h900 + 4*(n % 24), 32'h900 + 4*((n*7) % 24), WORD, WORD, 0);
        end

        if (read_completions != 190)
            $fatal(1, "incorrect read completion scoreboard: %0d", read_completions);
        $display("PASS dcache_test: %0d read completions, %0d refills, %0d acknowledged stores",
                 read_completions, load_transactions, store_transactions);
        $finish;
    end

endmodule // dcache_test
