`include "sys_defs.svh"

// End-to-end architectural scoreboard. Instructions are encoded here so this
// regression needs no RISC-V cross compiler or DPI library.
module cpu_dual_test;

    // Clock and processor interfaces.
    logic clock = 0, reset = 1;
    always #5 clock = ~clock;
    MEM_TAG accept_tag, response_tag;
    MEM_BLOCK response_data, write_data;
    MEM_COMMAND command;
    MEM_SIZE size;
    ADDR address;
    COMMIT_PACKET [1:0] commits;
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

    // Scoreboard and tagged backing-memory state.
    byte unsigned memory[0:65535], reference_memory[0:65535];
    DATA registers[0:31], vectors[0:31];
    DATA ref_pc, ref_vl, ref_vtype;
    integer cursor, cycles, test_number, total_commits;
    integer latency, bus_cycles, sequence_number;
    integer dual_fetch, dual_issue, dual_alu, dual_load, mixed_load_alu, dual_commit,
            parallel_reads;
    integer delays[1:15];
    logic pending[1:15];
    MEM_BLOCK pending_data[1:15];
    logic finished;
    EXCEPTION_CODE expected_exception;

    // Instruction encoders and program-image helpers.
    function automatic DATA ri(input integer imm, rs1, funct3, rd, opcode);
        return (DATA'(imm & 4095) << 20) | (DATA'(rs1) << 15) | (DATA'(funct3) << 12) |
               (DATA'(rd) << 7) | DATA'(opcode);
    endfunction

    function automatic DATA rr(input integer funct7, rs2, rs1, funct3, rd);
        return (DATA'(funct7) << 25) | (DATA'(rs2) << 20) | (DATA'(rs1) << 15) |
               (DATA'(funct3) << 12) | (DATA'(rd) << 7) | 32'h33;
    endfunction

    function automatic DATA st(input integer imm, rs2, rs1, funct3);
        return (DATA'((imm >> 5) & 127) << 25) | (DATA'(rs2) << 20) | (DATA'(rs1) << 15) |
               (DATA'(funct3) << 12) | (DATA'(imm & 31) << 7) | 32'h23;
    endfunction

    function automatic DATA br(input integer offset, rs2, rs1, funct3);
        return (DATA'((offset >> 12) & 1) << 31) | (DATA'((offset >> 5) & 63) << 25) |
               (DATA'(rs2) << 20) | (DATA'(rs1) << 15) | (DATA'(funct3) << 12) |
               (DATA'((offset >> 1) & 15) << 8) | (DATA'((offset >> 11) & 1) << 7) | 32'h63;
    endfunction

    function automatic DATA jump(input integer offset, rd);
        return (DATA'((offset >> 20) & 1) << 31) | (DATA'((offset >> 1) & 1023) << 21) |
               (DATA'((offset >> 11) & 1) << 20) | (DATA'((offset >> 12) & 255) << 12) |
               (DATA'(rd) << 7) | 32'h6f;
    endfunction

    function automatic DATA vi(input integer fn, vm, vs2, vs1, f3, vd);
        return (DATA'(fn) << 26) | (DATA'(vm) << 25) | (DATA'(vs2) << 20) | (DATA'(vs1) << 15) |
               (DATA'(f3) << 12) | (DATA'(vd) << 7) | 32'h57;
    endfunction

    function automatic DATA vm(input integer store_op, width, regnum, base_reg);
        return 32'h02000000 | (DATA'(base_reg) << 15) | (DATA'(width) << 12) |
               (DATA'(regnum) << 7) | (store_op != 0 ? 32'h27 : 32'h07);
    endfunction

    task automatic emit(input DATA instruction);
        for (int b = 0; b < 4; b++)
            memory[cursor + b] = instruction[b * 8 +: 8];
        cursor += 4;
    endtask

    function automatic DATA read_reference(input DATA addr, input integer bytes_count);
        DATA value;
        value = 0;
        for (int b = 0; b < bytes_count; b++)
            value |= DATA'(reference_memory[addr + b]) << (8 * b);
        return value;
    endfunction

    // Tagged shared memory: variable return delay, deterministic acceptance
    // backpressure, and independently tracked responses for both caches.
    always @(negedge clock) begin : backing_memory
        integer free_tag;
        MEM_BLOCK value;
        accept_tag = 0;
        response_tag = 0;
        response_data = 0;
        if (reset) begin
            bus_cycles = 0;
            sequence_number = 0;
            for (int t = 1; t <= 15; t++) begin
                pending[t] = 0;
                delays[t] = 0;
                pending_data[t] = 0;
            end
        end else begin
            bus_cycles++;
            for (int t = 1; t <= 15; t++)
                if (pending[t] && delays[t] > 0)
                    delays[t]--;
            free_tag = 0;
            for (int t = 15; t >= 1; t--)
                if (!pending[t])
                    free_tag = t;
            if (command != MEM_NONE && free_tag != 0 && (latency == 0 || bus_cycles % 5 != 0)) begin
                if (address >= 65536)
                    $fatal(1, "unfiltered backing address %h", address);
                accept_tag = MEM_TAG'(free_tag);
                sequence_number++;
                value = 0;
                if (command == MEM_STORE) begin
                    for (int b = 0; b < (1 << int'(size)); b++)
                        memory[address + b] = write_data[b * 8 +: 8];
                end else begin
                    for (int b = 0; b < (1 << int'(size)); b++)
                        value[b * 8 +: 8] = memory[address + b];
                    pending[free_tag] = 1;
                    pending_data[free_tag] = value;
                    delays[free_tag] = latency == 0 ? 0 : latency + (sequence_number % 3);
                end
            end
            for (int t = 1; t <= 15; t++)
                if (pending[t] && delays[t] == 0 && response_tag == 0) begin
                    response_tag = MEM_TAG'(t);
                    response_data = pending_data[t];
                    pending[t] = 0;
                end
        end
    end

    // Sequential reference semantics, checked once for every retirement lane.
    task automatic check_commit(input COMMIT_PACKET packet);
        DATA ins, next_pc, result, a, b, addr, imm, mask, x, y;
        integer opcode, f3, rd, rs1, rs2, count, sew, fn;
        logic writes, take;
        EXCEPTION_CODE cause;
        begin
            ins = read_reference(ref_pc, 4);
            next_pc = ref_pc + 4;
            result = 0;
            writes = 0;
            opcode = int'(ins[6:0]);
            f3 = int'(ins[14:12]);
            rd = int'(ins[11:7]);
            rs1 = int'(ins[19:15]);
            rs2 = int'(ins[24:20]);
            a = registers[rs1];
            b = registers[rs2];
            cause = NO_ERROR;
            take = 0;
            addr = 0;
            imm = 0;
            if (packet.NPC != ref_pc + 4)
                $fatal(1, "case%0d retirement order expected PC %h got NPC %h", test_number, ref_pc,
                       packet.NPC);
            case (opcode)
                'h13: begin
                    writes = 1;
                    imm = {{20{ins[31]}}, ins[31:20]};
                    case (f3)
                        0: result = a + imm;
                        2: result = DATA'($signed(a) < $signed(imm));
                        3: result = DATA'(a < imm);
                        4: result = a ^ imm;
                        6: result = a | imm;
                        7: result = a & imm;
                        1: result = a << ins[24:20];
                        5:
                            result =
                                ins[30] ? DATA'($signed(a) >>> ins[24:20]) : a >> ins[24:20];
                        default: $fatal(1, "reference opimm");
                    endcase
                end
                'h33: begin
                    writes = 1;
                    case (f3)
                        0:
                            result = ins[25]   ? a * b
                                     : ins[30] ? a - b
                                               : a + b;
                        4: result = a ^ b;
                        6: result = a | b;
                        7: result = a & b;
                        default: $fatal(1, "reference op");
                    endcase
                end
                'h37: begin
                    writes = 1;
                    result = {ins[31:12], 12'b0};
                end
                'h17: begin
                    writes = 1;
                    result = ref_pc + {ins[31:12], 12'b0};
                end
                'h03: begin
                    writes = 1;
                    addr = a + {{20{ins[31]}}, ins[31:20]};
                    count = 1 << (f3 & 3);
                    if ((addr & (DATA'(count) - 1)) != 0)
                        cause = LOAD_ADDR_MISALIGN;
                    else if (addr >= 65536)
                        cause = LOAD_ACCESS_FAULT;
                    else begin
                        result = read_reference(addr, count);
                        if (!ins[14] && count == 1)
                            result = {{24{result[7]}}, result[7:0]};
                        if (!ins[14] && count == 2)
                            result = {{16{result[15]}}, result[15:0]};
                    end
                end
                'h23: begin
                    imm = {{20{ins[31]}}, ins[31:25], ins[11:7]};
                    addr = a + imm;
                    count = 1 << f3;
                    if ((addr & (DATA'(count) - 1)) != 0)
                        cause = STORE_ADDR_MISALIGN;
                    else if (addr >= 65536)
                        cause = STORE_ACCESS_FAULT;
                    else
                        for (int j = 0; j < count; j++)
                            reference_memory[addr + j] = b[j * 8 +: 8];
                end
                'h63: begin
                    imm = {{19{ins[31]}}, ins[31], ins[7], ins[30:25], ins[11:8], 1'b0};
                    case (f3)
                        0: take = a == b;
                        1: take = a != b;
                        4: take = $signed(a) < $signed(b);
                        5: take = $signed(a) >= $signed(b);
                        6: take = a < b;
                        7: take = a >= b;
                        default: $fatal(1, "reference branch");
                    endcase
                    if (take)
                        next_pc = ref_pc + imm;
                end
                'h6f: begin
                    writes = 1;
                    result = ref_pc + 4;
                    imm = {{11{ins[31]}}, ins[31], ins[19:12], ins[20], ins[30:21], 1'b0};
                    next_pc = ref_pc + imm;
                end
                'h67: begin
                    writes = 1;
                    result = ref_pc + 4;
                    next_pc = (a + {{20{ins[31]}}, ins[31:20]}) & 32'hfffffffe;
                end
                'h0f: begin
                end
                'h57: begin
                    if (f3 == 7) begin
                        ref_vtype = ins[31:30] == 3 ? {22'b0, ins[29:20]}
                                    : ins[31]         ? b
                                                      : {21'b0, ins[30:20]};
                        count = 4 >> (ref_vtype[5:3]);
                        ref_vl = ins[31:30] == 3 ? DATA'(rs1) : a;
                        if (ref_vl > DATA'(count))
                            ref_vl = DATA'(count);
                        result = ref_vl;
                        writes = 1;
                    end else begin
                        sew = 8 << ref_vtype[5:3];
                        mask = sew == 32 ? 32'hffffffff : (32'b1 << sew) - 1;
                        fn = int'(ins[31:26]);
                        for (int e = 0; e < int'(ref_vl); e++)
                            if (ins[25] || vectors[0][e]) begin
                                x = (vectors[rs2] >> (e * sew)) & mask;
                                y = f3 == 4   ? a
                                    : f3 == 3 ? DATA'($signed(ins[19:15]))
                                              : (vectors[rs1] >> (e * sew)) & mask;
                                case (fn)
                                    0: result = x + y;
                                    2: result = x - y;
                                    23: result = y;
                                    default: $fatal(1, "reference vector fn %0d", fn);
                                endcase
                                vectors[rd] = (vectors[rd] & ~(mask << (e * sew))) |
                                              ((result & mask) << (e * sew));
                            end
                    end
                end
                'h07, 'h27: begin
                    sew = f3 == 0 ? 8 : f3 == 5 ? 16 : 32;
                    count = sew / 8;
                    mask = sew == 32 ? 32'hffffffff : (32'b1 << sew) - 1;
                    for (int e = 0; e < int'(ref_vl); e++)
                        if (ins[25] || vectors[0][e]) begin
                            addr = a + DATA'(e * count);
                            if (opcode == 'h07)
                                vectors[rd] = (vectors[rd] & ~(mask << (e * sew))) |
                                              ((read_reference(addr, count) & mask) << (e * sew));
                            else
                                for (int j = 0; j < count; j++)
                                    reference_memory[addr + j] =
                                        8'(vectors[rd] >> (e * sew + j * 8));
                        end
                end
                'h73:
                    if (ins == 32'h10500073) begin
                        if (!packet.halt)
                            $fatal(1, "missing halt");
                        finished = 1;
                    end else
                        $fatal(1, "reference system %h", ins);
                default: cause = ILLEGAL_INST;
            endcase
            if (next_pc[1:0] != 0)
                cause = INST_ADDR_MISALIGN;
            if (packet.exception != cause)
                $fatal(1, "case%0d PC%h cause expected%h actual%h", test_number, ref_pc, cause,
                       packet.exception);
            if (cause != NO_ERROR) begin
                if (cause != expected_exception)
                    $fatal(1, "unexpected fault %h", cause);
                writes = 0;
                finished = 1;
            end
            if (writes && rd != 0) begin
                if (packet.reg_idx != 5'(rd) || packet.data != result)
                    $fatal(1, "case%0d PC%h x%0d expected %h got x%0d=%h", test_number, ref_pc, rd,
                           result, packet.reg_idx, packet.data);
                registers[rd] = result;
            end else if (packet.reg_idx != 0 && cause == NO_ERROR)
                $fatal(1, "unexpected scalar write PC%h x%0d", ref_pc, packet.reg_idx);
            ref_pc = next_pc;
            total_commits++;
        end
    endtask

    // Observe two-wide fetch, issue, execution, and retirement.
    always @(posedge clock)
        if (!reset) begin
            if (dut.fetch_advance == 2)
                dual_fetch++;
            if (dut.issue_count == 2)
                dual_issue++;
            if (dut.ex_packet[0].valid && dut.ex_packet[1].valid &&
                dut.ex_packet[0].exception == NO_ERROR && dut.ex_packet[1].exception == NO_ERROR &&
                !dut.mem_stall && !dut.ex_hold) begin
                if (dut.id_ex_reg[0].rd_mem && dut.id_ex_reg[1].rd_mem)
                    dual_load++;
                else if (dut.id_ex_reg[0].rd_mem || dut.id_ex_reg[1].rd_mem)
                    mixed_load_alu++;
                else
                    dual_alu++;
            end
            if ((&dut.rvalid) && (&dut.rsp_valid))
                parallel_reads++;
        end
    always @(negedge clock)
        if (!reset) begin
            #1;
            cycles++;
            if (commits[0].valid && commits[1].valid)
                dual_commit++;
            for (int lane = 0; lane < 2; lane++)
                if (commits[lane].valid) begin
                    if (finished)
                        $fatal(1, "younger retirement after termination");
                    check_commit(commits[lane]);
                end
            if (cycles > 20000)
                $fatal(1, "case%0d timeout PC%h", test_number, ref_pc);
        end

    // Scenario setup and final-memory checks.
    task automatic initialize_case(input integer number);
        reset = 1;
        finished = 0;
        test_number = number;
        cursor = 0;
        cycles = 0;
        total_commits = 0;
        ref_pc = 0;
        ref_vl = 0;
        ref_vtype = 0;
        expected_exception = NO_ERROR;
        for (int i = 0; i < 65536; i++) begin
            memory[i] = 0;
            reference_memory[i] = 0;
        end
        for (int i = 0; i < 32; i++) begin
            registers[i] = 0;
            vectors[i] = 0;
        end
        for (int i = 0; i < 128; i++)
            memory[1024 + i] = 8'(i * 13 + 7);
    endtask

    task automatic run_case;
        for (int i = 0; i < 65536; i++)
            reference_memory[i] = memory[i];
        repeat (3) @(posedge clock);
        #1 reset = 0;
        wait(finished);
        @(posedge clock);
        #1;
        for (int i = 1024; i < 1152; i++)
            if (memory[i] != reference_memory[i])
                $fatal(1, "case%0d memory %h expected %h actual %h", test_number, i,
                       reference_memory[i], memory[i]);
        $display("PASS cpu case=%0d commits=%0d cycles=%0d", test_number, total_commits, cycles);
        reset = 1;
        repeat (2) @(posedge clock);
    endtask

    initial begin
        latency = 3;
        if ($value$plusargs("LATENCY=%d", latency)) begin
        end
        dual_fetch = 0;
        dual_issue = 0;
        dual_alu = 0;
        dual_load = 0;
        mixed_load_alu = 0;
        dual_commit = 0;
        parallel_reads = 0;
        // Scalar issue, hazards, memory ordering, and control flow.
        initialize_case(0);
        emit(ri(1024, 0, 0, 1, 'h13));
        emit(ri(7, 0, 0, 2, 'h13));
        emit(ri(11, 0, 0, 3, 'h13));
        emit(ri(-8, 0, 0, 4, 'h13));
        emit(rr(0, 3, 2, 0, 5));
        emit(rr(0, 4, 3, 4, 6));
        emit(ri(1, 5, 0, 7, 'h13));
        emit(ri(99, 0, 0, 7, 'h13));
        emit(ri(1, 7, 0, 8, 'h13));
        emit(ri(1, 8, 0, 9, 'h13));
        emit(rr(0, 9, 8, 0, 10));
        emit(ri(5, 0, 0, 8, 'h13));
        emit(st(0, 10, 1, 2));
        emit(32'h13);
        emit(ri(0, 1, 2, 11, 'h03));
        emit(ri(85, 0, 0, 12, 'h13));
        emit(ri(0, 1, 2, 13, 'h03));
        emit(ri(8, 1, 2, 14, 'h03));
        emit(ri(0, 1, 2, 15, 'h03));
        emit(ri(8, 1, 2, 16, 'h03));
        emit(ri(0, 1, 2, 17, 'h03));
        emit(ri(4, 1, 2, 18, 'h03));
        emit(st(1, 2, 1, 0));
        emit(st(2, 3, 1, 1));
        emit(ri(1, 1, 0, 19, 'h03));
        emit(ri(2, 1, 5, 20, 'h03));
        emit(br(12, 2, 19, 0));
        emit(st(16, 4, 1, 2));
        emit(ri(999, 0, 0, 30, 'h13));
        emit(jump(12, 21));
        emit(st(16, 4, 1, 2));
        emit(ri(999, 0, 0, 30, 'h13));
        emit(ri(cursor + 13, 0, 0, 23, 'h13));
        emit(ri(0, 23, 0, 24, 'h67));
        emit(st(16, 4, 1, 2));
        emit(rr(1, 3, 2, 0, 25));
        emit(32'h0ff0000f);
        emit(32'h0000100f);
        emit(32'h10500073);
        run_case();

        // A lane-one memory fault preserves its older sibling and cancels all
        // subsequent register/store effects. The following case faults lane 0.
        initialize_case(1);
        expected_exception = LOAD_ADDR_MISALIGN;
        emit(ri(1024, 0, 0, 1, 'h13));
        emit(ri(9, 0, 0, 2, 'h13));
        emit(ri(23, 0, 0, 3, 'h13));
        emit(ri(1, 1, 2, 4, 'h03));
        emit(st(16, 2, 1, 2));
        emit(32'h10500073);
        run_case();
        initialize_case(2);
        expected_exception = LOAD_ACCESS_FAULT;
        emit(32'h000100b7);
        emit(ri(4, 0, 0, 2, 'h13));
        emit(ri(0, 1, 2, 3, 'h03));
        emit(ri(99, 0, 0, 4, 'h13));
        emit(st(1024, 2, 0, 2));
        emit(32'h10500073);
        run_case();
        initialize_case(3);
        expected_exception = INST_ADDR_MISALIGN;
        emit(ri(2, 0, 0, 1, 'h13));
        emit(ri(0, 1, 0, 2, 'h67));
        emit(ri(99, 0, 0, 3, 'h13));
        emit(32'h10500073);
        run_case();
        initialize_case(4);
        expected_exception = ILLEGAL_INST;
        emit(ri(8, 0, 0, 1, 'h13));
        emit(32'hffffffff);
        emit(ri(99, 0, 0, 2, 'h13));
        run_case();

        // Scalar store -> vector load -> vector arithmetic -> vector store ->
        // parallel scalar loads crosses every new datapath through the cache.
        initialize_case(5);
        emit(ri(1024, 0, 0, 1, 'h13));
        emit(ri(1088, 0, 0, 2, 'h13));
        emit(ri(17, 0, 0, 3, 'h13));
        emit(st(0, 3, 1, 2));
        emit(32'hc0027257); // vsetivli x4,4,e8,m1,tu,mu
        emit(vm(0, 0, 1, 1));
        emit(vi(23, 1, 0, 3, 3, 2));
        emit(vi(0, 1, 1, 2, 0, 3));
        emit(vm(1, 0, 3, 2));
        emit(ri(0, 2, 2, 5, 'h03));
        emit(ri(0, 1, 2, 6, 'h03));
        emit(32'hc0817357); // vsetivli x6,2,e16,m1,tu,mu
        emit(vm(0, 5, 4, 1));
        emit(vi(2, 1, 4, 3, 4, 5));
        emit(vm(1, 5, 5, 2));
        emit(32'hc100f3d7); // vsetivli x7,1,e32,m1,tu,mu
        emit(vm(0, 6, 6, 1));
        emit(vi(0, 1, 6, 3, 4, 7));
        emit(vm(1, 6, 7, 2));
        emit(ri(0, 2, 2, 8, 'h03));
        emit(ri(0, 1, 2, 9, 'h03));
        emit(32'h10500073);
        run_case();
        if (dual_fetch == 0 || dual_issue == 0 || dual_alu == 0 || dual_load == 0 ||
            mixed_load_alu == 0 || dual_commit == 0 || parallel_reads == 0)
            $fatal(
                1,
                "missing throughput evidence FETCH%0d ISSUE%0d ALU%0d LD%0d MIX%0d WB%0d READ%0d",
                dual_fetch, dual_issue, dual_alu, dual_load, mixed_load_alu, dual_commit,
                parallel_reads);
        $display(
            "PASS cpu_dual_test latency=%0d dual_fetch=%0d dual_issue=%0d dual_alu=%0d dual_load=%0d mixed=%0d dual_commit=%0d parallel_read_hits=%0d",
            latency, dual_fetch, dual_issue, dual_alu, dual_load, mixed_load_alu, dual_commit,
            parallel_reads);
        $finish;
    end
endmodule
