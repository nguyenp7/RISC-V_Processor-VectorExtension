`include "sys_defs.svh"
`include "ISA.svh"

// Two-wide in-order elastic pipeline. A memory bundle holds both lanes until
// complete. Completed reads are remembered while a sibling misses. Stores,
// control and vector instructions issue alone. Vectors drain older work first.
module cpu (
    input  logic                   clock,
    input  logic                   reset,

    // Memory Bus Interface
    input  MEM_TAG                 mem2proc_transaction_tag,
    input  MEM_BLOCK               mem2proc_data,
    input  MEM_TAG                 mem2proc_data_tag,
    output MEM_COMMAND             proc2mem_command,
    output ADDR                    proc2mem_addr,
    output MEM_BLOCK               proc2mem_data,
    output MEM_SIZE                proc2mem_size,

    // Architectural Commit Interface
    output COMMIT_PACKET [`N-1:0]  committed_insts,

    // Debug Interface Signals
    output ADDR                    if_NPC_dbg,
    output DATA                    if_inst_dbg,
    output logic                   if_valid_dbg,
    output ADDR                    if_id_NPC_dbg,
    output DATA                    if_id_inst_dbg,
    output logic                   if_id_valid_dbg,
    output ADDR                    id_ex_NPC_dbg,
    output DATA                    id_ex_inst_dbg,
    output logic                   id_ex_valid_dbg,
    output ADDR                    ex_mem_NPC_dbg,
    output DATA                    ex_mem_inst_dbg,
    output logic                   ex_mem_valid_dbg,
    output ADDR                    mem_wb_NPC_dbg,
    output DATA                    mem_wb_inst_dbg,
    output logic                   mem_wb_valid_dbg
);

    // =========================================================================
    // Pipeline Registers & Signals
    // =========================================================================
    IF_ID_PACKET   [1:0] if_packet, if_id_reg;
    ID_EX_PACKET   [1:0] id_packet, id_ex_reg;
    EX_MEM_PACKET  [1:0] ex_raw, ex_packet, ex_mem_reg;
    MEM_WB_PACKET  [1:0] mem_packet, mem_wb_reg;
    INST           [1:0] ex_mem_inst, mem_wb_inst;
    COMMIT_PACKET  [1:0] wb_packet;

    // Decode & Hazard Control Signals
    logic          [1:0] id_ex_vector;
    logic          [1:0] issue_count, fetch_advance;

    // Register File Signals
    REG_IDX        [3:0] rf_read_idx;
    DATA           [3:0] rf_read_data;
    REG_IDX        [1:0] rf_write_idx;
    DATA           [1:0] rf_write_data;
    logic          [1:0] rf_write_en;

    // Global Pipeline Control & Control Flow Signals
    logic                mem_stall, ex_hold, redirect, terminate_ex, fence_i, stop_pending, halted;
    ADDR                 fetch_pc, Imem_addr, redirect_pc;

    // Cache Interface Signals
    MEM_BLOCK            ic_data, dc_data;
    logic                ic_valid, dc_grant;
    MEM_COMMAND          ic_command, dc_command;
    ADDR                 ic_addr, dc_addr;
    MEM_SIZE             dc_size;

    // Data Cache Port Signals
    logic          [1:0] rvalid, rready, rsp_valid;
    ADDR           [1:0] raddr;
    MEM_SIZE       [1:0] rsize;
    DATA           [1:0] rdata;
    logic                wvalid, wready;
    ADDR                 waddr;
    MEM_SIZE             wsize;
    DATA                 wdata;

    // Load Buffer Signals
    logic          [1:0] load_done, lane_complete;
    DATA           [1:0] load_result;

    // Vector Co-processor Interface Signals
    logic                vreq_valid, vreq_ready, vbusy, vresp_valid, vresp_ready;
    logic                vresp_write_scalar, vresp_illegal, vector_started;
    DATA                 vresp_data;
    EXCEPTION_CODE       vresp_exception;
    logic                vmem_valid, vmem_write, vmem_ready, vmem_resp_valid;
    ADDR                 vmem_addr;
    MEM_SIZE             vmem_size;
    DATA                 vmem_wdata;

    // =========================================================================
    // Helper Functions
    // =========================================================================
    function automatic DATA extend_load(input DATA value, input MEM_SIZE size, input logic unsign);
        case (size)
            BYTE:    return unsign ? {24'b0, value[7:0]}  : {{24{value[7]}}, value[7:0]};
            HALF:    return unsign ? {16'b0, value[15:0]} : {{16{value[15]}}, value[15:0]};
            default: return value;
        endcase
    endfunction

    // =========================================================================
    // Memory Bus Arbitration
    // =========================================================================
    // Qualify acceptance tags by bus grant. Returning data tags are independently
    // matched by the caches, including a return in the acceptance cycle.
    assign dc_grant = (dc_command != MEM_NONE);

    always_comb begin
        proc2mem_command = dc_grant ? dc_command : ic_command;
        proc2mem_addr    = dc_grant ? dc_addr    : ic_addr;
        proc2mem_data    = dc_data;
        proc2mem_size    = dc_grant ? dc_size    : DOUBLE;
        if (reset || halted) begin
            proc2mem_command = MEM_NONE;
        end
    end

    // =========================================================================
    // Core Module Instantiations
    // =========================================================================
    icache icache_0 (
        .clock                    (clock),
        .reset                    (reset),
        .request_valid            (!stop_pending && !halted && fetch_pc[1:0] == 0 && fetch_pc < `MEM_SIZE_IN_BYTES),
        .invalidate               (fence_i),
        .proc2Icache_addr         (Imem_addr),
        .Imem2proc_transaction_tag(dc_grant ? MEM_TAG'(0) : mem2proc_transaction_tag),
        .Imem2proc_data           (mem2proc_data),
        .Imem2proc_data_tag       (mem2proc_data_tag),
        .proc2Imem_command        (ic_command),
        .proc2Imem_addr           (ic_addr),
        .Icache_data_out          (ic_data),
        .Icache_valid_out         (ic_valid)
    );

    stage_if_dual stage_if_0 (
        .clock      (clock),
        .reset      (reset),
        .advance    (fetch_advance),
        .redirect   (redirect),
        .redirect_pc(redirect_pc),
        .line_data  (ic_data),
        .line_valid (ic_valid),
        .PC_reg     (fetch_pc),
        .Imem_addr  (Imem_addr),
        .if_packet  (if_packet)
    );

    dcache dcache_0 (
        .clock               (clock),
        .reset               (reset),
        .rvalid              (rvalid),
        .raddr               (raddr),
        .rsize               (rsize),
        .rready              (rready),
        .rsp_valid           (rsp_valid),
        .rdata               (rdata),
        .wvalid              (wvalid),
        .waddr               (waddr),
        .wsize               (wsize),
        .wdata               (wdata),
        .wready              (wready),
        .mem_command         (dc_command),
        .mem_addr            (dc_addr),
        .mem_data            (dc_data),
        .mem_size            (dc_size),
        .mem_transaction_tag (dc_grant ? mem2proc_transaction_tag : MEM_TAG'(0)),
        .mem_data_in         (mem2proc_data),
        .mem_data_tag        (mem2proc_data_tag)
    );

    // Scalar and vector instructions share decode, operand forwarding, and
    // issue interlocks. Only execution dispatch differs after the ID/EX latch.
    stage_id stage_id_0 (
        .if_id_reg    (if_id_reg),
        .id_ex_reg    (id_ex_reg),
        .ex_mem_reg   (ex_mem_reg),
        .rf_read_data (rf_read_data),
        .issue_enable (!mem_stall && !ex_hold && !redirect && !terminate_ex &&
                       !stop_pending && !halted),
        .rf_read_idx  (rf_read_idx),
        .id_packet    (id_packet),
        .raw_hazard   (),
        .serial       (),
        .issue_count  (issue_count)
    );

    regfile_2wide regfile_0 (
        .clock     (clock),
        .read_idx  (rf_read_idx),
        .read_data (rf_read_data),
        .write_en  (rf_write_en),
        .write_idx (rf_write_idx),
        .write_data(rf_write_data)
    );

    vector_unit vector_unit_0 (
        .clock             (clock),
        .reset             (reset),
        .req_valid         (vreq_valid),
        .req_ready         (vreq_ready),
        .req_inst          (id_ex_reg[0].inst),
        .req_control       (id_ex_reg[0].vector_control),
        .req_rs1           (id_ex_reg[0].rs1_value),
        .req_rs2           (id_ex_reg[0].rs2_value),
        .busy              (vbusy),
        .resp_valid        (vresp_valid),
        .resp_ready        (vresp_ready),
        .resp_data         (vresp_data),
        .resp_write_scalar (vresp_write_scalar),
        .resp_illegal      (vresp_illegal),
        .resp_exception    (vresp_exception),
        .mem_valid         (vmem_valid),
        .mem_write         (vmem_write),
        .mem_addr          (vmem_addr),
        .mem_size          (vmem_size),
        .mem_wdata         (vmem_wdata),
        .mem_ready         (vmem_ready),
        .mem_resp_valid    (vmem_resp_valid),
        .mem_rdata         (rdata[0])
    );

    // =========================================================================
    // Dual Execution Lanes Setup
    // =========================================================================
    for (genvar lane = 0; lane < 2; lane++) begin : scalar_lanes
        assign id_ex_vector[lane] = id_ex_reg[lane].vector_control.operation != V_NONE;

        stage_ex stage_ex_0 (
            .id_ex_reg (id_ex_reg[lane]),
            .ex_mem_reg(EX_MEM_PACKET'('0)),
            .mem_wb_reg(MEM_WB_PACKET'('0)),
            .ex_packet (ex_raw[lane])
        );

        stage_wb stage_wb_0 (
            .mem_wb_reg(mem_wb_reg[lane]),
            .wb_packet (wb_packet[lane])
        );

        assign committed_insts[lane] = wb_packet[lane];
        assign rf_write_en[lane]     = wb_packet[lane].valid && !wb_packet[lane].illegal &&
                                       !wb_packet[lane].halt && wb_packet[lane].exception == NO_ERROR;
        assign rf_write_idx[lane]    = wb_packet[lane].reg_idx;
        assign rf_write_data[lane]   = wb_packet[lane].data;
    end

    // =========================================================================
    // Vector Control & Interlocks
    // =========================================================================
    assign vreq_valid = id_ex_reg[0].valid && id_ex_vector[0] && !vector_started &&
                        !ex_mem_reg[0].valid && !ex_mem_reg[1].valid &&
                        !mem_wb_reg[0].valid && !mem_wb_reg[1].valid && !halted;

    assign ex_hold     = id_ex_reg[0].valid && id_ex_vector[0] && !vresp_valid;
    assign vresp_ready = id_ex_reg[0].valid && id_ex_vector[0] && !mem_stall && vresp_valid;

    assign vmem_ready      = vmem_write ? wready : rready[0];
    assign vmem_resp_valid = rsp_valid[0] && vmem_valid && !vmem_write;

    // =========================================================================
    // Execution Stage & Exception Handling
    // =========================================================================
    // Faults precede memory side effects. Lane-zero faults cancel lane one;
    // lane-one faults preserve their older sibling. No younger store can escape.
    always_comb begin
        ex_packet = ex_raw;
        for (int lane = 0; lane < 2; lane++) begin
            if (id_ex_vector[lane]) begin
                ex_packet[lane]               = '0;
                ex_packet[lane].valid         = id_ex_reg[lane].valid && vresp_valid;
                ex_packet[lane].NPC           = id_ex_reg[lane].NPC;
                ex_packet[lane].alu_result    = vresp_data;
                ex_packet[lane].dest_reg_idx  = vresp_write_scalar ? id_ex_reg[lane].inst.r.rd : 5'b0;
                ex_packet[lane].illegal       = vresp_illegal;
                ex_packet[lane].exception     = vresp_exception;
            end else if (id_ex_reg[lane].valid) begin
                if (ex_packet[lane].illegal) begin
                    ex_packet[lane].exception = ILLEGAL_INST;
                end
                if (ex_packet[lane].exception == NO_ERROR && (ex_packet[lane].rd_mem || ex_packet[lane].wr_mem)) begin
                    if ((ex_packet[lane].mem_size == HALF && ex_packet[lane].alu_result[0]) ||
                        (ex_packet[lane].mem_size == WORD && ex_packet[lane].alu_result[1:0] != 0)) begin
                        ex_packet[lane].exception = ex_packet[lane].wr_mem ? STORE_ADDR_MISALIGN : LOAD_ADDR_MISALIGN;
                    end else if (ex_packet[lane].alu_result >= `MEM_SIZE_IN_BYTES) begin
                        ex_packet[lane].exception = ex_packet[lane].wr_mem ? STORE_ACCESS_FAULT : LOAD_ACCESS_FAULT;
                    end
                end
                if (ex_packet[lane].take_branch && ex_packet[lane].alu_result[1:0] != 0) begin
                    ex_packet[lane].exception = INST_ADDR_MISALIGN;
                end
            end

            if (ex_packet[lane].exception != NO_ERROR) begin
                ex_packet[lane].rd_mem       = 0;
                ex_packet[lane].wr_mem       = 0;
                ex_packet[lane].take_branch  = 0;
                ex_packet[lane].dest_reg_idx = 0;
            end
        end

        if (ex_packet[0].valid && (ex_packet[0].illegal || ex_packet[0].halt || ex_packet[0].exception != NO_ERROR)) begin
            ex_packet[1].valid = 0;
        end
    end

    always_comb begin
        terminate_ex = 0;
        for (int lane = 0; lane < 2; lane++) begin
            terminate_ex |= !mem_stall && !ex_hold && ex_packet[lane].valid &&
                            (ex_packet[lane].illegal || ex_packet[lane].halt || ex_packet[lane].exception != NO_ERROR);
        end

        fence_i = !mem_stall && !ex_hold && id_ex_reg[0].valid &&
                  id_ex_reg[0].inst.r.opcode == `RV32_FENCE && id_ex_reg[0].inst.r.funct3 == 1;

        redirect    = !mem_stall && !ex_hold && !terminate_ex &&
                      ((ex_packet[0].valid && ex_packet[0].take_branch) || fence_i);
        redirect_pc = fence_i ? id_ex_reg[0].NPC : ex_packet[0].alu_result;
    end

    // =========================================================================
    // Memory Stage & Cache Interfacing
    // =========================================================================
    // Exclusive vector memory ownership follows drain-before-start.
    always_comb begin
        rvalid = 0; raddr = 0; rsize = '0;
        wvalid = 0; waddr = 0; wsize = WORD; wdata = 0;

        for (int lane = 0; lane < 2; lane++) begin
            rvalid[lane] = ex_mem_reg[lane].valid && ex_mem_reg[lane].rd_mem && !load_done[lane];
            raddr[lane]  = ex_mem_reg[lane].alu_result;
            rsize[lane]  = ex_mem_reg[lane].mem_size;

            if (ex_mem_reg[lane].valid && ex_mem_reg[lane].wr_mem) begin
                wvalid = 1;
                waddr  = ex_mem_reg[lane].alu_result;
                wsize  = ex_mem_reg[lane].mem_size;
                wdata  = ex_mem_reg[lane].rs2_value;
            end
        end

        if (vbusy) begin
            rvalid   = {1'b0, vmem_valid && !vmem_write};
            raddr[0] = vmem_addr;
            rsize[0] = vmem_size;
            wvalid   = vmem_valid && vmem_write;
            waddr    = vmem_addr;
            wsize    = vmem_size;
            wdata    = vmem_wdata;
        end
    end

    always_comb begin
        mem_packet    = '0;
        lane_complete = '1;

        for (int lane = 0; lane < 2; lane++) begin
            mem_packet[lane].NPC          = ex_mem_reg[lane].NPC;
            mem_packet[lane].valid        = ex_mem_reg[lane].valid;
            mem_packet[lane].halt         = ex_mem_reg[lane].halt;
            mem_packet[lane].illegal      = ex_mem_reg[lane].illegal;
            mem_packet[lane].exception    = ex_mem_reg[lane].exception;
            mem_packet[lane].dest_reg_idx = ex_mem_reg[lane].dest_reg_idx;
            mem_packet[lane].take_branch  = ex_mem_reg[lane].take_branch;
            mem_packet[lane].result       = ex_mem_reg[lane].alu_result;

            if (ex_mem_reg[lane].valid && ex_mem_reg[lane].rd_mem) begin
                lane_complete[lane]    = load_done[lane] || rsp_valid[lane];
                mem_packet[lane].result = load_done[lane] ? load_result[lane] :
                                          extend_load(rdata[lane], ex_mem_reg[lane].mem_size, ex_mem_reg[lane].rd_unsigned);
            end

            if (ex_mem_reg[lane].valid && ex_mem_reg[lane].wr_mem) begin
                lane_complete[lane] = wready;
            end
        end

        mem_stall = !(&lane_complete);
    end

    always_comb begin
        fetch_advance = 0;
        if (!mem_stall && !ex_hold && !redirect && !terminate_ex && !stop_pending && !halted &&
            (!if_id_reg[0].valid || issue_count == (if_id_reg[1].valid ? 2 : 1))) begin
            fetch_advance = if_packet[0].valid ? (if_packet[1].valid ? 2 : 1) : 0;
        end
    end

    // =========================================================================
    // Pipeline Sequential Control State
    // =========================================================================
    always_ff @(posedge clock) begin
        if (reset) begin
            if_id_reg      <= '0;
            id_ex_reg      <= '0;
            ex_mem_reg     <= '0;
            mem_wb_reg     <= '0;
            ex_mem_inst    <= '0;
            mem_wb_inst    <= '0;
            load_done      <= 0;
            load_result    <= 0;
            stop_pending   <= 0;
            halted         <= 0;
            vector_started <= 0;
        end else begin
            // WB is consumed once even when the upstream pipeline is blocked.
            mem_wb_reg <= '0;

            for (int lane = 0; lane < 2; lane++) begin
                if (wb_packet[lane].valid && (wb_packet[lane].halt || wb_packet[lane].illegal ||
                    wb_packet[lane].exception != NO_ERROR)) begin
                    halted <= 1;
                end
                if (rvalid[lane] && rsp_valid[lane] && !vbusy) begin
                    load_done[lane]   <= 1;
                    load_result[lane] <= extend_load(rdata[lane], ex_mem_reg[lane].mem_size, ex_mem_reg[lane].rd_unsigned);
                end
            end

            if (vreq_valid && vreq_ready) begin
                vector_started <= 1;
            end
            if (terminate_ex) begin
                stop_pending <= 1;
            end

            if (!mem_stall && !halted) begin
                mem_wb_reg  <= mem_packet;
                mem_wb_inst <= ex_mem_inst;
                load_done   <= 0;
                ex_mem_reg  <= '0;

                if (!ex_hold) begin
                    ex_mem_reg     <= ex_packet;
                    ex_mem_inst[0] <= id_ex_reg[0].inst;
                    ex_mem_inst[1] <= id_ex_reg[1].inst;
                    id_ex_reg      <= '0;

                    if (id_ex_vector[0]) begin
                        vector_started <= 0;
                    end

                    if (redirect || terminate_ex) begin
                        if_id_reg <= '0;
                    end else if (!stop_pending) begin
                        if (issue_count != 0) begin
                            id_ex_reg[0]    <= id_packet[0];

                            if (issue_count == 2) begin
                                id_ex_reg[1]    <= id_packet[1];
                            end

                            if_id_reg <= '0;
                            if (issue_count == 1 && if_id_reg[1].valid) begin
                                if_id_reg[0] <= if_id_reg[1];
                            end
                        end

                        if (fetch_advance != 0) begin
                            if_id_reg <= if_packet;
                        end
                    end
                end
            end
        end
    end

    // =========================================================================
    // Debug Output Assignments
    // =========================================================================
    // Existing debug pins show the oldest lane; both lanes are visible in the
    // packed pipeline registers and architectural commit interface.
    assign if_NPC_dbg       = if_packet[0].NPC;
    assign if_inst_dbg      = if_packet[0].inst;
    assign if_valid_dbg     = if_packet[0].valid;
    assign if_id_NPC_dbg    = if_id_reg[0].NPC;
    assign if_id_inst_dbg   = if_id_reg[0].inst;
    assign if_id_valid_dbg  = if_id_reg[0].valid;
    assign id_ex_NPC_dbg    = id_ex_reg[0].NPC;
    assign id_ex_inst_dbg   = id_ex_reg[0].inst;
    assign id_ex_valid_dbg  = id_ex_reg[0].valid;
    assign ex_mem_NPC_dbg   = ex_mem_reg[0].NPC;
    assign ex_mem_inst_dbg  = ex_mem_inst[0];
    assign ex_mem_valid_dbg = ex_mem_reg[0].valid;
    assign mem_wb_NPC_dbg   = mem_wb_reg[0].NPC;
    assign mem_wb_inst_dbg  = mem_wb_inst[0];
    assign mem_wb_valid_dbg = mem_wb_reg[0].valid;

    // =========================================================================
    // Simulation Assertions
    // =========================================================================
    
`ifndef SYNTH
    always_ff @(posedge clock) if (!reset) begin
        assert (!(id_ex_reg[1].valid && !id_ex_reg[0].valid))
            else $fatal(1, "issue order");
        assert (!(ex_mem_reg[0].valid && ex_mem_reg[0].wr_mem && ex_mem_reg[1].valid && ex_mem_reg[1].wr_mem))
            else $fatal(1, "two stores");
        assert (!(vbusy && (ex_mem_reg[0].valid || ex_mem_reg[1].valid)))
            else $fatal(1, "vector must own memory exclusively");
        assert (!(rf_write_en[0] && rf_write_en[1] && rf_write_idx[0] != 0 && rf_write_idx[0] == rf_write_idx[1]))
            else $fatal(1, "same-pair WAW");
    end
`endif

endmodule