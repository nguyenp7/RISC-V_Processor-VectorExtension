`include "sys_defs.svh"
`include "ISA.svh"

// Verify the common scalar/vector decoder and its actual two-wide ID wrapper.
// Tests inspect public controls and operand/hazard interfaces, not decode
// internals. This bench requires no register file, CPU, DPI, or program image.
module vector_decode_test;
    INST dec_inst;
    logic dec_valid;
    ALU_OPA_SELECT dec_opa;
    ALU_OPB_SELECT dec_opb;
    ALU_FUNC dec_alu;
    VECTOR_CONTROL dec_vector;
    logic dec_has_dest, dec_mult, dec_rd_mem, dec_wr_mem;
    logic dec_cond_branch, dec_uncond_branch, dec_csr, dec_halt, dec_illegal;
    logic dec_uses_rs1, dec_uses_rs2;

    IF_ID_PACKET [1:0] if_id_reg;
    ID_EX_PACKET [1:0] id_ex_reg, id_packet;
    EX_MEM_PACKET [1:0] ex_mem_reg;
    DATA [3:0] rf_read_data;
    REG_IDX [3:0] rf_read_idx;
    logic issue_enable;
    logic [1:0] raw_hazard, serial, issue_count;
    integer checks = 0, vector_instructions = 0;

    decoder decode_dut (
        .inst(dec_inst),
        .valid(dec_valid),
        .opa_select(dec_opa),
        .opb_select(dec_opb),
        .has_dest(dec_has_dest),
        .alu_func(dec_alu),
        .mult(dec_mult),
        .rd_mem(dec_rd_mem),
        .wr_mem(dec_wr_mem),
        .cond_branch(dec_cond_branch),
        .uncond_branch(dec_uncond_branch),
        .csr_op(dec_csr),
        .halt(dec_halt),
        .illegal(dec_illegal),
        .uses_rs1(dec_uses_rs1),
        .uses_rs2(dec_uses_rs2),
        .vector_control(dec_vector)
    );

    stage_id id_dut (
        .if_id_reg(if_id_reg),
        .id_ex_reg(id_ex_reg),
        .ex_mem_reg(ex_mem_reg),
        .rf_read_data(rf_read_data),
        .issue_enable(issue_enable),
        .rf_read_idx(rf_read_idx),
        .id_packet(id_packet),
        .raw_hazard(raw_hazard),
        .serial(serial),
        .issue_count(issue_count)
    );

    function automatic DATA arithmetic(input integer fn, vm, vs2, vs1, f3, vd);
        return (DATA'(fn) << 26) | (DATA'(vm) << 25) | (DATA'(vs2) << 20) |
               (DATA'(vs1) << 15) | (DATA'(f3) << 12) | (DATA'(vd) << 7) | 32'h57;
    endfunction

    function automatic DATA memory_op(input logic store, input integer width);
        integer f3;
        f3 = width == 8 ? 0 : width == 16 ? 5 : 6;
        return (32'b1 << 25) | (32'd5 << 15) | (DATA'(f3) << 12) |
               (32'd8 << 7) | (store ? 32'h27 : 32'h07);
    endfunction

    function automatic DATA addi(input integer rd, rs1, immediate_value);
        return (DATA'(immediate_value & 4095) << 20) | (DATA'(rs1) << 15) |
               (DATA'(rd) << 7) | 32'h13;
    endfunction

    function automatic DATA scalar_add(input integer rd, rs1, rs2);
        return (DATA'(rs2) << 20) | (DATA'(rs1) << 15) | (DATA'(rd) << 7) | 32'h33;
    endfunction

    function automatic DATA csr(input integer address, f3, source, destination);
        return (DATA'(address) << 20) | (DATA'(source) << 15) | (DATA'(f3) << 12) |
               (DATA'(destination) << 7) | 32'h73;
    endfunction

    task automatic check(input logic condition, input string description);
        checks++;
        if (condition !== 1'b1)
            $fatal(1, "%s", description);
    endtask

    task automatic expect_vector(
        input DATA instruction,
        input VECTOR_OP operation,
        input VECTOR_CONFIG config_kind,
        input logic scalar_operand, immediate_operand,
        input logic uses_scalar1, uses_scalar2, writes_scalar,
        input MEM_SIZE access_size,
        input string description
    );
        dec_inst = instruction;
        dec_valid = 1;
        #1;
        check(!dec_illegal && dec_vector.operation == operation,
              {description, ": instruction operation"});
        check(dec_vector.config_kind == config_kind,
              {description, ": configuration kind"});
        check(dec_vector.scalar_operand == scalar_operand &&
              dec_vector.immediate_operand == immediate_operand,
              {description, ": operand selection"});
        check(dec_uses_rs1 == uses_scalar1 && dec_uses_rs2 == uses_scalar2 &&
              dec_has_dest == writes_scalar,
              {description, ": scalar register dependency metadata"});
        check(!(dec_rd_mem || dec_wr_mem || dec_mult || dec_cond_branch ||
                dec_uncond_branch || dec_halt),
              {description, ": no scalar execution/memory side effects"});
        if (operation == V_LOAD || operation == V_STORE)
            check(dec_vector.mem_size == access_size, {description, ": memory element width"});
        vector_instructions++;
    endtask

    task automatic expect_illegal(input DATA instruction, input string description);
        dec_inst = instruction;
        dec_valid = 1;
        #1;
        check(dec_illegal && dec_vector.operation == V_NONE, description);
        check(!(dec_has_dest || dec_rd_mem || dec_wr_mem || dec_uses_rs1 || dec_uses_rs2),
              {description, ": no scalar dependencies or writes"});
    endtask

    task automatic clear_id;
        if_id_reg = '0;
        id_ex_reg = '0;
        ex_mem_reg = '0;
        rf_read_data[0] = 32'h11111111;
        rf_read_data[1] = 32'h22222222;
        rf_read_data[2] = 32'h33333333;
        rf_read_data[3] = 32'h44444444;
        issue_enable = 1;
    endtask

    task automatic queue(input integer lane, input DATA instruction);
        if_id_reg[lane].inst = instruction;
        if_id_reg[lane].PC = 32'h100 + DATA'(lane * 4);
        if_id_reg[lane].NPC = 32'h104 + DATA'(lane * 4);
        if_id_reg[lane].exception = NO_ERROR;
        if_id_reg[lane].valid = 1;
    endtask

    task automatic pending_ex(input integer lane, destination);
        id_ex_reg[lane].valid = 1;
        id_ex_reg[lane].dest_reg_idx = REG_IDX'(destination);
        id_ex_reg[lane].exception = NO_ERROR;
    endtask

    task automatic forwarding_mem(input integer lane, destination, input DATA value);
        ex_mem_reg[lane].valid = 1;
        ex_mem_reg[lane].dest_reg_idx = REG_IDX'(destination);
        ex_mem_reg[lane].alu_result = value;
        ex_mem_reg[lane].exception = NO_ERROR;
    endtask

    initial begin
        dec_inst = `NOP;
        dec_valid = 0;
        clear_id();

        // Every newly supported vector encoding reaches the shared control
        // packet. Vector register numbers must never become integer hazards.
        expect_vector(32'h0002f457, V_CONFIG, V_CFG_VLI, 0, 0, 1, 0, 1, BYTE, "vsetvli");
        expect_vector(32'hc002f457, V_CONFIG, V_CFG_IVLI, 0, 0, 0, 0, 1, BYTE, "vsetivli");
        expect_vector(32'h8062f457, V_CONFIG, V_CFG_VL, 0, 0, 1, 1, 1, BYTE, "vsetvl");
        for (integer width = 8; width <= 32; width *= 2) begin
            expect_vector(memory_op(0, width), V_LOAD, V_CFG_NONE, 0, 0, 1, 0, 0,
                          width == 8 ? BYTE : width == 16 ? HALF : WORD, "vle");
            expect_vector(memory_op(1, width), V_STORE, V_CFG_NONE, 0, 0, 1, 0, 0,
                          width == 8 ? BYTE : width == 16 ? HALF : WORD, "vse");
        end
        expect_vector(arithmetic(0, 1, 6, 5, 0, 8), V_ADD, V_CFG_NONE, 0, 0, 0, 0, 0, BYTE, "vadd.vv");
        expect_vector(arithmetic(2, 0, 6, 5, 0, 8), V_SUB, V_CFG_NONE, 0, 0, 0, 0, 0, BYTE, "vsub.vv masked");
        expect_vector(arithmetic(0, 1, 6, 5, 4, 8), V_ADD, V_CFG_NONE, 1, 0, 1, 0, 0, BYTE, "vadd.vx");
        expect_vector(arithmetic(2, 0, 6, 5, 4, 8), V_SUB, V_CFG_NONE, 1, 0, 1, 0, 0, BYTE, "vsub.vx masked");
        expect_vector(arithmetic(0, 1, 6, 31, 3, 8), V_ADD, V_CFG_NONE, 0, 1, 0, 0, 0, BYTE, "vadd.vi -1");
        expect_vector(arithmetic(23, 1, 0, 16, 3, 8), V_MOVE, V_CFG_NONE, 0, 1, 0, 0, 0, BYTE, "vmv.v.i -16");
        expect_vector(arithmetic(24, 0, 6, 5, 0, 8), V_EQ, V_CFG_NONE, 0, 0, 0, 0, 0, BYTE, "vmseq.vv masked");
        expect_vector(arithmetic(27, 1, 6, 5, 0, 8), V_LT, V_CFG_NONE, 0, 0, 0, 0, 0, BYTE, "vmslt.vv");
        expect_vector(arithmetic(25, 1, 6, 5, 2, 8), V_AND, V_CFG_NONE, 0, 0, 0, 0, 0, BYTE, "vmand.mm");
        expect_vector(arithmetic(26, 1, 6, 5, 2, 8), V_OR, V_CFG_NONE, 0, 0, 0, 0, 0, BYTE, "vmor.mm");
        check(vector_instructions == 19, "all nineteen RVV instructions decoded");

        // Vector CSR register forms use scalar rs1; immediate forms use zimm.
        for (integer f3 = 1; f3 < 8; f3++) begin
            if (f3 != 4) begin
                dec_inst = csr('h008, f3, 5, 8);
                #1;
                check(!dec_illegal && dec_vector.operation == V_CSR && dec_has_dest,
                      "vector CSR operation and scalar destination");
                check(dec_uses_rs1 == (f3 < 4) && !dec_uses_rs2,
                      "vector CSR register/immediate source distinction");
                check(!dec_vector.scalar_operand && !dec_vector.immediate_operand,
                      "CSR source handled by CSR controls, not arithmetic flags");
            end
        end
        // Unsupported configurations remain configuration operations. The
        // engine applies dynamic vtype/vill and register-group legality rules.
        dec_inst = 32'h0182f457;
        #1;
        check(!dec_illegal && dec_vector.operation == V_CONFIG, "dynamic vtype validation stays in vector engine");
        dec_inst = csr('hc20, 1, 5, 8);
        #1;
        check(!dec_illegal && dec_vector.operation == V_CSR, "read-only CSR write legality stays in vector engine");

        expect_illegal(arithmetic(23, 1, 1, 5, 3, 8), "vmv reserved vs2 encoding");
        expect_illegal(arithmetic(25, 0, 6, 5, 2, 8), "mask logical vm must be one");
        expect_illegal(arithmetic(0, 1, 6, 5, 1, 8), "unsupported vector funct3");
        expect_illegal(memory_op(0, 8) | 32'h20000000, "unsupported segmented vector memory");
        expect_illegal(memory_op(0, 8) | 32'h10000000, "unsupported vector memory mew");
        expect_illegal(memory_op(0, 8) | 32'h04000000, "unsupported strided vector memory");
        expect_illegal(memory_op(0, 8) | 32'h00100000, "unsupported vector lumop");
        expect_illegal(32'h8262f457, "reserved vector config function");
        expect_illegal(32'hffffffff, "unknown opcode");
        dec_inst = arithmetic(0, 1, 6, 5, 4, 8);
        dec_valid = 0;
        #1;
        check(!dec_illegal && dec_vector.operation == V_NONE &&
              !dec_has_dest && !dec_uses_rs1 && !dec_uses_rs2,
              "invalid instruction produces inactive controls");

        // Scalar instructions retain their original decode and share the same
        // two-wide ID stage and four external register-file read addresses.
        dec_valid = 1;
        dec_inst = scalar_add(8, 5, 6);
        #1;
        check(dec_vector.operation == V_NONE && !dec_illegal && dec_has_dest &&
              dec_uses_rs1 && dec_uses_rs2 && dec_alu == ALU_ADD,
              "scalar ADD decode remains active");
        dec_inst = 32'h0002a403;
        #1;
        check(dec_rd_mem && dec_has_dest && dec_uses_rs1 && !dec_uses_rs2 &&
              dec_vector.operation == V_NONE, "scalar load decode remains active");
        dec_inst = csr('h51e, 1, 5, 0);
        #1;
        check(dec_csr && dec_uses_rs1 && !dec_has_dest && dec_vector.operation == V_NONE,
              "legacy scalar CSR convention retained");

        clear_id();
        queue(0, addi(5, 0, 1));
        queue(1, addi(6, 0, 2));
        #1;
        check(issue_count == 2 && raw_hazard == 0 && serial == 0, "two independent scalar instructions issue");
        check(id_packet[0].rs1_value == rf_read_data[0] &&
              id_packet[1].rs1_value == rf_read_data[2], "four scalar RF read paths");
        issue_enable = 0;
        #1;
        check(issue_count == 0, "upstream backpressure disables issue");

        clear_id();
        queue(0, addi(5, 0, 1));
        queue(1, scalar_add(6, 5, 7));
        #1;
        check(issue_count == 1, "same-pair scalar RAW serializes");
        queue(1, addi(5, 0, 2));
        #1;
        check(issue_count == 1, "same-pair scalar WAW serializes");
        queue(0, scalar_add(7, 5, 6));
        queue(1, addi(5, 0, 2));
        #1;
        check(issue_count == 2, "same-pair WAR safe after operand capture");

        clear_id();
        queue(0, arithmetic(0, 1, 6, 5, 4, 8));
        queue(1, addi(9, 0, 2));
        #1;
        check(serial[0] && issue_count == 1 && id_packet[0].dest_reg_idx == 0,
              "vector VX serializes without scalar vector-destination WAW");
        check(rf_read_idx[0] == 5 && id_packet[0].uses_rs1 &&
              !id_packet[0].uses_rs2 && id_packet[0].vector_control.operation == V_ADD,
              "vector VX scalar source and control reach ID packet");
        check(id_packet[0].PC == if_id_reg[0].PC && id_packet[0].NPC == if_id_reg[0].NPC &&
              id_packet[0].inst == if_id_reg[0].inst, "ID packet preserves instruction and PCs");
        pending_ex(1, 5);
        #1;
        check(raw_hazard[0] && issue_count == 0, "VX waits for older scalar producer in either lane");
        id_ex_reg = '0;
        forwarding_mem(0, 5, 32'h12345678);
        #1;
        check(!raw_hazard[0] && issue_count == 1 && id_packet[0].rs1_value == 32'h12345678,
              "MEM scalar result forwards to vector VX operand");
        ex_mem_reg[0].take_branch = 1;
        ex_mem_reg[0].NPC = 32'h80;
        #1;
        check(id_packet[0].rs1_value == 32'h80, "branch link forwards instead of target address");
        ex_mem_reg[0].take_branch = 0;
        ex_mem_reg[0].rd_mem = 1;
        #1;
        check(raw_hazard[0] && issue_count == 0, "vector VX does not consume unfinished scalar load");

        clear_id();
        queue(0, 32'h8062f457);
        #1;
        check(id_packet[0].dest_reg_idx == 8 && id_packet[0].uses_rs1 && id_packet[0].uses_rs2,
              "vsetvl has two scalar dependencies and a scalar destination");
        pending_ex(0, 6);
        #1;
        check(raw_hazard[0] && issue_count == 0, "vsetvl waits for scalar rs2 vtype producer");
        id_ex_reg = '0;
        forwarding_mem(0, 5, 32'd4);
        forwarding_mem(1, 6, 32'h12);
        #1;
        check(!raw_hazard[0] && id_packet[0].rs1_value == 4 && id_packet[0].rs2_value == 32'h12,
              "both MEM lanes forward AVL and vtype into vsetvl");
        ex_mem_reg[1].rd_mem = 1;
        #1;
        check(raw_hazard[0] && issue_count == 0, "vsetvl scalar rs2 load-use hazard");

        clear_id();
        queue(0, 32'h0002f457);
        pending_ex(0, 5);
        #1;
        check(raw_hazard[0], "vsetvli tracks scalar AVL source");
        queue(0, 32'hc002f457);
        #1;
        check(!raw_hazard[0] && issue_count == 1, "vsetivli AVL immediate is not a scalar register");
        queue(0, arithmetic(0, 1, 6, 5, 0, 8));
        pending_ex(1, 6);
        #1;
        check(!raw_hazard[0] && issue_count == 1, "VV vector source numbers never create scalar RAW hazards");
        queue(0, arithmetic(0, 1, 6, 5, 3, 8));
        #1;
        check(!raw_hazard[0], "VI immediate never creates scalar RAW hazards");

        clear_id();
        queue(0, memory_op(0, 32));
        pending_ex(0, 5);
        #1;
        check(raw_hazard[0] && id_packet[0].vector_control.operation == V_LOAD,
              "vector load base-address dependency comes from shared ID");
        queue(0, memory_op(1, 16));
        #1;
        check(raw_hazard[0] && !id_packet[0].uses_rs2 && id_packet[0].dest_reg_idx == 0,
              "vector store tracks scalar base, not vector data as scalar rs2");

        clear_id();
        queue(0, csr('h008, 1, 5, 8));
        pending_ex(0, 5);
        #1;
        check(raw_hazard[0] && serial[0], "vector CSR register source participates in hazards");
        queue(0, csr('h008, 5, 5, 8));
        #1;
        check(!raw_hazard[0] && issue_count == 1, "vector CSR immediate does not create a false dependency");

        clear_id();
        queue(0, addi(9, 0, 2));
        queue(1, arithmetic(0, 1, 6, 5, 4, 8));
        #1;
        check(issue_count == 1 && serial[1] &&
              id_packet[0].vector_control.operation == V_NONE &&
              id_packet[1].vector_control.operation == V_ADD,
              "scalar and vector decode together; scalar issues before serialized vector");
        if_id_reg[0].exception = INST_ADDR_MISALIGN;
        #1;
        check(id_packet[0].exception == INST_ADDR_MISALIGN && serial[0],
              "fetch exception propagates through shared ID and serializes");

        $display("PASS vector_decode_test: all 19 vector controls, scalar decode, two-wide ID hazards/forwarding (%0d checks)", checks);
        $finish;
    end

    initial begin
        #10000;
        $fatal(1, "vector decoder test timeout");
    end
endmodule
