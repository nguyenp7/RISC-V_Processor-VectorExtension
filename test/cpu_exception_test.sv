`include "sys_defs.svh"

// Integration checks for precise retirement, vector restart state, and fence.i.
module cpu_exception_test;

    // Clock and processor interfaces.
    logic clock = 0, reset = 1;
    always #5 clock = ~clock;
    MEM_COMMAND command;
    ADDR address;
    MEM_BLOCK write_data, read_data;
    MEM_SIZE size;
    MEM_TAG accept_tag, data_tag;
    COMMIT_PACKET [`N - 1:0] commits;
    integer stores = 0, scenario = 0, retired = 0, vector_requests = 0;
    logic vector_active = 0;
    VECTOR_CONTROL active_vector_control;
    INST active_vector_instruction;
    cpu dut (
        .clock(clock),
        .reset(reset),
        .mem2proc_transaction_tag(accept_tag),
        .mem2proc_data(read_data),
        .mem2proc_data_tag(data_tag),
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
        .mem2proc_data(read_data),
        .mem2proc_data_tag(data_tag)
    );

    always @(posedge clock) begin
        if (reset) begin
            stores = 0;
            vector_requests = 0;
            vector_active <= 0;
            active_vector_control <= '0;
            active_vector_instruction <= '0;
        end else begin
            if (command == MEM_STORE && accept_tag != 0)
                stores++;
            if (dut.vreq_valid && dut.vreq_ready) begin
                vector_requests++;
                vector_active <= 1;
                active_vector_control <= dut.id_ex_reg[0].vector_control;
                active_vector_instruction <= dut.id_ex_reg[0].inst;
            end else if (!dut.vbusy) begin
                vector_active <= 0;
            end
            if (vector_active && dut.vbusy &&
                (dut.id_ex_reg[0].vector_control != active_vector_control ||
                 dut.id_ex_reg[0].inst != active_vector_instruction))
                $fatal(1, "vector instruction/control changed while execution was held");
        end
    end

    // Encoders and scenario helpers.
    function automatic DATA addi(input integer rd, rs1, imm);
        return (32'(imm & 4095) << 20) | (32'(rs1) << 15) | (32'(rd) << 7) | 32'h13;
    endfunction

    function automatic DATA lw(input integer rd, rs1, imm);
        return (32'(imm & 4095) << 20) | (32'(rs1) << 15) | (32'(rd) << 7) | 32'h2003;
    endfunction

    function automatic DATA sw(input integer rs2, rs1, imm);
        return (32'((imm >> 5) & 127) << 25) | (32'(rs2) << 20) | (32'(rs1) << 15) |
               (32'(imm & 31) << 7) | 32'h2023;
    endfunction

    function automatic DATA jal(input integer rd, imm);
        return (32'((imm >> 20) & 1) << 31) | (32'((imm >> 1) & 1023) << 21) |
               (32'((imm >> 11) & 1) << 20) | (32'((imm >> 12) & 255) << 12) | (32'(rd) << 7) |
               32'h6f;
    endfunction

    function automatic DATA jalr(input integer rd, rs1, imm);
        return (32'(imm & 4095) << 20) | (32'(rs1) << 15) | (32'(rd) << 7) | 32'h67;
    endfunction

    task automatic put(input integer addr, input DATA inst);
        memory.unified_memory[addr / 8][(addr % 8) * 8 +: 32] = inst;
    endtask

    task automatic initialize;
        @(negedge clock);
        #1;
        reset = 1;
        repeat (4) @(posedge clock);
        @(negedge clock);
        #1;
        for (int i = 0; i < `MEM_64BIT_LINES; i++)
            memory.unified_memory[i] = 0;
        put(0, addi(1, 0, 128));
        put(4, addi(2, 0, 37));
        put(8, 32'h10500073);
        memory.unified_memory[16] = 64'h112233440000002a;
        retired = 0;
        scenario++;
    endtask

    task automatic run(input EXCEPTION_CODE cause, input ADDR fault_pc, input integer count);
        logic finished;
        finished = 0;
        @(negedge clock);
        #1;
        reset = 0;
        for (int cycle = 0; cycle < 5000 && !finished; cycle++) begin
            @(negedge clock);
            #1;
            for (int lane = 0; lane < `N; lane++)
                if (commits[lane].valid) begin
                    if (finished)
                        $fatal(1, "scenario %0d: younger commit after fault", scenario);
                    retired++;
                    if (cause != HALTED_ON_WFI && commits[lane].NPC - 4 > fault_pc)
                        $fatal(1, "scenario %0d: wrong-path PC %h", scenario,
                               commits[lane].NPC - 4);
                    if (commits[lane].exception != NO_ERROR || commits[lane].halt ||
                        commits[lane].illegal) begin
                        if ((cause == HALTED_ON_WFI && !commits[lane].halt) ||
                            (cause != HALTED_ON_WFI && commits[lane].exception != cause) ||
                            commits[lane].NPC - 4 != fault_pc)
                            $fatal(1, "scenario %0d: wrong terminal pc/cause pc=%h cause=%h",
                                   scenario, commits[lane].NPC - 4, commits[lane].exception);
                        finished = 1;
                    end
                end
        end
        if (!finished || retired != count)
            $fatal(1, "scenario %0d: retired %0d expected %0d finished=%b", scenario, retired,
                   count, finished);
        // Let the RF apply the last commit and verify no delayed side effects.
        repeat (8) begin
            @(negedge clock);
            #1;
            if (commits[0].valid || commits[1].valid)
                $fatal(1, "duplicate terminal retirement");
        end
    endtask

    // Precise faults, redirects, restart state, and instruction coherence.
    initial begin
        // Fault in lane zero cancels a simultaneously issued younger ALU.
        initialize();
        put(8, lw(3, 0, 129));
        put(12, addi(4, 0, 9));
        put(16, sw(2, 1, 0));
        run(LOAD_ADDR_MISALIGN, 8, 3);
        if (stores != 0 || memory.unified_memory[16] != 64'h112233440000002a)
            $fatal(1, "younger store escaped");

        // Fault in lane one retains the older ALU and its writeback.
        initialize();
        put(8, addi(4, 0, 9));
        put(12, lw(3, 0, 129));
        put(16, sw(2, 1, 0));
        run(LOAD_ADDR_MISALIGN, 12, 4);
        if (dut.regfile_0.registers[4] != 9 || stores != 0)
            $fatal(1, "lane-one fault ordering");

        // Older cache miss must finish before its younger fault retires.
        initialize();
        put(8, lw(4, 1, 0));
        put(12, lw(3, 0, 129));
        put(16, sw(2, 1, 0));
        run(LOAD_ADDR_MISALIGN, 12, 4);
        if (dut.regfile_0.registers[4] != 42 || stores != 0)
            $fatal(1, "fault overtook older load");

        initialize();
        put(8, 32'b0);
        put(12, sw(2, 1, 0));
        run(ILLEGAL_INST, 8, 3);
        if (stores != 0)
            $fatal(1, "store after illegal");

        initialize();
        put(8, sw(2, 0, 129));
        put(12, addi(3, 0, 99));
        run(STORE_ADDR_MISALIGN, 8, 3);
        if (stores != 0)
            $fatal(1, "misaligned store changed memory");

        initialize();
        put(8, jal(0, 2));
        put(12, sw(2, 1, 0));
        run(INST_ADDR_MISALIGN, 8, 3);
        if (stores != 0)
            $fatal(1, "store after bad branch");

        // JALR clears bit zero before enforcing IALIGN=32.
        initialize();
        put(8, addi(3, 0, 25));
        put(12, addi(0, 0, 0));
        put(16, jalr(0, 3, 0));
        put(20, sw(2, 1, 0));
        put(24, addi(7, 0, 45));
        put(28, 32'h10500073);
        run(HALTED_ON_WFI, 28, 7);
        if (dut.regfile_0.registers[7] != 45 || stores != 0)
            $fatal(1, "jalr bit-zero/flush");

        // A vector load crossing the memory limit preserves completed elements
        // and records the failing index in vstart before the scalar fault.
        initialize();
        put(0, 32'h000100b7);
        put(4, addi(1, 1, -8));
        put(8, 32'hc0027057);  // vsetivli x0,4,e8,m1
        put(12, 32'h0200e207); // vle32.v v4,(x1), EEW32 EMUL4
        put(16, sw(2, 0, 128));
        memory.unified_memory[`MEM_64BIT_LINES - 1] = 64'hcafebabe12345678;
        run(LOAD_ACCESS_FAULT, 12, 4);
        if (dut.vector_unit_0.vstart != 2 || dut.vector_unit_0.vregs[4] != 32'h12345678 ||
            dut.vector_unit_0.vregs[5] != 32'hcafebabe || stores != 0)
            $fatal(1, "vector restart fault state");

        // Warm a code line, change it through the write-through D-cache,
        // execute fence.i, and require the newly fetched instruction.
        initialize();
        put(0, addi(10, 0, 8));
        put(4, jal(0, 60));
        put(8, 32'h00200137);
        put(12, addi(2, 2, 32'h393));
        put(16, sw(2, 0, 64));
        put(20, 32'h0000100f);
        put(24, addi(10, 0, 32));
        put(28, jal(0, 36));
        put(32, 32'h10500073);
        put(64, addi(7, 0, 1));
        put(68, jalr(0, 10, 0));
        run(HALTED_ON_WFI, 32, 13);
        if (dut.regfile_0.registers[7] != 2 || stores != 1)
            $fatal(1, "fence.i coherence");

        // A statically unsupported OP-V encoding faults in shared decode and
        // must never be submitted to the vector engine or allow a younger store.
        initialize();
        put(8, 32'h02001457); // OP-V with unsupported floating-point funct3.
        put(12, sw(2, 1, 0));
        run(ILLEGAL_INST, 8, 3);
        if (vector_requests != 0 || stores != 0 || dut.vector_unit_0.vl != 0)
            $fatal(1, "statically illegal vector instruction reached execution");

        // Redirect before a queued vector configuration/move. Only the target
        // CSR read may reach the engine; the wrong-path configuration changes
        // neither scalar rd nor architectural vl/vtype.
        initialize();
        put(0, addi(5, 0, 55));
        put(4, jal(0, 12));
        put(8, 32'hc00272d7);  // vsetivli x5,4,e8,m1,tu,mu (wrong path).
        put(12, 32'h5e00b257); // vmv.v.i v4,1 (wrong path).
        put(16, 32'hc2002373); // csrrs x6,vl,x0.
        put(20, 32'h10500073);
        run(HALTED_ON_WFI, 20, 4);
        if (vector_requests != 1 || stores != 0 || dut.regfile_0.registers[5] != 55 ||
            dut.regfile_0.registers[6] != 0 || dut.vector_unit_0.vl != 0 ||
            dut.vector_unit_0.vtype != 32'h80000000)
            $fatal(1, "wrong-path vector configuration escaped redirect");

        // An older cache miss supplies AVL through shared scalar operand
        // capture. Configuration/CSR scalar results then feed immediate scalar
        // consumers, including a scalar producer feeding a vector CSR source.
        initialize();
        put(4, lw(2, 1, 0));
        put(8, 32'h000172d7);  // vsetvli x5,x2,e8,m1,tu,mu -> min(42,4).
        put(12, addi(6, 5, 3));
        put(16, 32'hc20023f3); // csrrs x7,vl,x0.
        put(20, addi(8, 7, 9));
        put(24, 32'h008314f3); // csrrw x9,vstart,x6.
        put(28, 32'h00802573); // csrrs x10,vstart,x0.
        put(32, addi(11, 10, 1));
        put(36, 32'h10500073);
        run(HALTED_ON_WFI, 36, 10);
        if (vector_requests != 4 || stores != 0 || dut.regfile_0.registers[2] != 42 ||
            dut.regfile_0.registers[5] != 4 || dut.regfile_0.registers[6] != 7 ||
            dut.regfile_0.registers[7] != 4 || dut.regfile_0.registers[8] != 13 ||
            dut.regfile_0.registers[9] != 0 || dut.regfile_0.registers[10] != 7 ||
            dut.regfile_0.registers[11] != 8 || dut.vector_unit_0.vstart != 7)
            $fatal(1, "shared ID scalar/vector configuration/CSR dependencies");
        $display("PASS cpu_exception_test: %0d precise-fault/redirect/fence scenarios", scenario);
        $finish;
    end
    initial begin
        #1000000;
        $fatal(1, "timeout");
    end
endmodule
