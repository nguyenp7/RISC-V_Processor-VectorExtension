/////////////////////////////////////////////////////////////////////////
//                                                                     //
//   Modulename :  stage_id.sv                                          //
//                                                                     //
//  Description :  Shared scalar/vector decode, operand capture, and   //
//                 two-wide in-order issue and dependency checking.    //
//                                                                     //
/////////////////////////////////////////////////////////////////////////

`include "sys_defs.svh"
`include "ISA.svh"

// Combinational scalar/vector instruction and operand-form decode.
module decoder (
    input  INST           inst,
    input  logic          valid, // when low, output NOP controls

    output ALU_OPA_SELECT opa_select,
    output ALU_OPB_SELECT opb_select,
    output logic          has_dest, // if there is a destination register
    output ALU_FUNC       alu_func,
    output logic          mult, rd_mem, wr_mem, cond_branch, uncond_branch,
    output logic          csr_op,
    output logic          halt,
    output logic          illegal,
    output logic          uses_rs1,
    output logic          uses_rs2,
    output VECTOR_CONTROL vector_control
);

    function automatic logic vector_csr(input logic [11:0] address);
        case (address)
            12'h008, 12'h009, 12'h00a, 12'h00f,
            12'hc20, 12'hc21, 12'hc22: return 1'b1;
            default:                 return 1'b0;
        endcase
    endfunction

    always_comb begin
        // Default control values (looks like a NOP)
        opa_select     = OPA_IS_RS1;
        opb_select     = OPB_IS_RS2;
        alu_func       = ALU_ADD;
        has_dest       = `FALSE;
        csr_op         = `FALSE;
        mult           = `FALSE;
        rd_mem         = `FALSE;
        wr_mem         = `FALSE;
        cond_branch    = `FALSE;
        uncond_branch  = `FALSE;
        halt           = `FALSE;
        illegal        = `FALSE;
        uses_rs1       = `FALSE;
        uses_rs2       = `FALSE;
        vector_control = '0;

        if (valid) begin
            casez (inst)
                `RV32_LUI: begin
                    has_dest   = `TRUE;
                    opa_select = OPA_IS_ZERO;
                    opb_select = OPB_IS_U_IMM;
                end
                `RV32_AUIPC: begin
                    has_dest   = `TRUE;
                    opa_select = OPA_IS_PC;
                    opb_select = OPB_IS_U_IMM;
                end
                `RV32_JAL: begin
                    has_dest      = `TRUE;
                    opa_select    = OPA_IS_PC;
                    opb_select    = OPB_IS_J_IMM;
                    uncond_branch = `TRUE;
                end
                `RV32_JALR: begin
                    has_dest      = `TRUE;
                    opa_select    = OPA_IS_RS1;
                    opb_select    = OPB_IS_I_IMM;
                    uncond_branch = `TRUE;
                    uses_rs1      = `TRUE;  
                end
                `RV32_BEQ, `RV32_BNE, `RV32_BLT, `RV32_BGE,
                `RV32_BLTU, `RV32_BGEU: begin
                    opa_select  = OPA_IS_PC;
                    opb_select  = OPB_IS_B_IMM;
                    cond_branch = `TRUE;
                    uses_rs1    = `TRUE;  
                    uses_rs2    = `TRUE;  
                end
                `RV32_MUL, `RV32_MULH, `RV32_MULHSU, `RV32_MULHU: begin
                    has_dest   = `TRUE;
                    mult       = `TRUE;
                    uses_rs1   = `TRUE;  
                    uses_rs2   = `TRUE;  
                end
                `RV32_LB, `RV32_LH, `RV32_LW,
                `RV32_LBU, `RV32_LHU: begin
                    has_dest   = `TRUE;
                    opb_select = OPB_IS_I_IMM;
                    rd_mem     = `TRUE;
                    uses_rs1   = `TRUE;  
                end
                `RV32_SB, `RV32_SH, `RV32_SW: begin
                    opb_select = OPB_IS_S_IMM;
                    wr_mem     = `TRUE;
                    uses_rs1   = `TRUE;  
                    uses_rs2   = `TRUE;  
                end
                `RV32_ADDI: begin
                    has_dest   = `TRUE;
                    opb_select = OPB_IS_I_IMM;
                    uses_rs1   = `TRUE;  
                end
                `RV32_SLTI: begin
                    has_dest   = `TRUE;
                    opb_select = OPB_IS_I_IMM;
                    alu_func   = ALU_SLT;
                    uses_rs1   = `TRUE;  
                end
                `RV32_SLTIU: begin
                    has_dest   = `TRUE;
                    opb_select = OPB_IS_I_IMM;
                    alu_func   = ALU_SLTU;
                    uses_rs1   = `TRUE;  
                end
                `RV32_ANDI: begin
                    has_dest   = `TRUE;
                    opb_select = OPB_IS_I_IMM;
                    alu_func   = ALU_AND;
                    uses_rs1   = `TRUE;  
                end
                `RV32_ORI: begin
                    has_dest   = `TRUE;
                    opb_select = OPB_IS_I_IMM;
                    alu_func   = ALU_OR;
                    uses_rs1   = `TRUE;  
                end
                `RV32_XORI: begin
                    has_dest   = `TRUE;
                    opb_select = OPB_IS_I_IMM;
                    alu_func   = ALU_XOR;
                    uses_rs1   = `TRUE;  
                end
                `RV32_SLLI: begin
                    has_dest   = `TRUE;
                    opb_select = OPB_IS_I_IMM;
                    alu_func   = ALU_SLL;
                    uses_rs1   = `TRUE;  
                end
                `RV32_SRLI: begin
                    has_dest   = `TRUE;
                    opb_select = OPB_IS_I_IMM;
                    alu_func   = ALU_SRL;
                    uses_rs1   = `TRUE;  
                end
                `RV32_SRAI: begin
                    has_dest   = `TRUE;
                    opb_select = OPB_IS_I_IMM;
                    alu_func   = ALU_SRA;
                    uses_rs1   = `TRUE;  
                end
                `RV32_ADD: begin
                    has_dest   = `TRUE;
                    uses_rs1   = `TRUE;  
                    uses_rs2   = `TRUE;  
                end
                `RV32_SUB: begin
                    has_dest   = `TRUE;
                    alu_func   = ALU_SUB;
                    uses_rs1   = `TRUE;  
                    uses_rs2   = `TRUE;  
                end
                `RV32_SLT: begin
                    has_dest   = `TRUE;
                    alu_func   = ALU_SLT;
                    uses_rs1   = `TRUE;  
                    uses_rs2   = `TRUE;  
                end
                `RV32_SLTU: begin
                    has_dest   = `TRUE;
                    alu_func   = ALU_SLTU;
                    uses_rs1   = `TRUE;  
                    uses_rs2   = `TRUE;  
                end
                `RV32_AND: begin
                    has_dest   = `TRUE;
                    alu_func   = ALU_AND;
                    uses_rs1   = `TRUE;  
                    uses_rs2   = `TRUE;  
                end
                `RV32_OR: begin
                    has_dest   = `TRUE;
                    alu_func   = ALU_OR;
                    uses_rs1   = `TRUE;  
                    uses_rs2   = `TRUE;  
                end
                `RV32_XOR: begin
                    has_dest   = `TRUE;
                    alu_func   = ALU_XOR;
                    uses_rs1   = `TRUE;  
                    uses_rs2   = `TRUE;  
                end
                `RV32_SLL: begin
                    has_dest   = `TRUE;
                    alu_func   = ALU_SLL;
                    uses_rs1   = `TRUE;  
                    uses_rs2   = `TRUE;  
                end
                `RV32_SRL: begin
                    has_dest   = `TRUE;
                    alu_func   = ALU_SRL;
                    uses_rs1   = `TRUE;  
                    uses_rs2   = `TRUE;  
                end
                `RV32_SRA: begin
                    has_dest   = `TRUE;
                    alu_func   = ALU_SRA;
                    uses_rs1   = `TRUE;  
                    uses_rs2   = `TRUE;  
                end
                `RV32_CSRRW, `RV32_CSRRS, `RV32_CSRRC: begin
                    csr_op  = `TRUE;
                    uses_rs1 = `TRUE;  
                end

                // Vector register indices are not scalar dependencies. Only
                // configuration, VX, memory bases, and register CSR operands
                // consume the scalar register-file ports.
                `RVV_VSETVLI: begin
                    vector_control.operation   = V_CONFIG;
                    vector_control.config_kind = V_CFG_VLI;
                    has_dest = `TRUE;
                    uses_rs1 = `TRUE;
                end
                `RVV_VSETIVLI: begin
                    vector_control.operation   = V_CONFIG;
                    vector_control.config_kind = V_CFG_IVLI;
                    has_dest = `TRUE;
                end
                `RVV_VSETVL: begin
                    vector_control.operation   = V_CONFIG;
                    vector_control.config_kind = V_CFG_VL;
                    has_dest = `TRUE;
                    uses_rs1 = `TRUE;
                    uses_rs2 = `TRUE;
                end
                `RVV_VLE8, `RVV_VLE16, `RVV_VLE32: begin
                    vector_control.operation = V_LOAD;
                    vector_control.mem_size  = inst.r.funct3 == 0 ? BYTE :
                                               (inst.r.funct3 == 5 ? HALF : WORD);
                    uses_rs1 = `TRUE;
                end
                `RVV_VSE8, `RVV_VSE16, `RVV_VSE32: begin
                    vector_control.operation = V_STORE;
                    vector_control.mem_size  = inst.r.funct3 == 0 ? BYTE :
                                               (inst.r.funct3 == 5 ? HALF : WORD);
                    uses_rs1 = `TRUE;
                end
                `RVV_VADD_VV: vector_control.operation = V_ADD;
                `RVV_VSUB_VV: vector_control.operation = V_SUB;
                `RVV_VADD_VX: begin
                    vector_control.operation      = V_ADD;
                    vector_control.scalar_operand = `TRUE;
                    uses_rs1 = `TRUE;
                end
                `RVV_VSUB_VX: begin
                    vector_control.operation      = V_SUB;
                    vector_control.scalar_operand = `TRUE;
                    uses_rs1 = `TRUE;
                end
                `RVV_VADD_VI: begin
                    vector_control.operation         = V_ADD;
                    vector_control.immediate_operand = `TRUE;
                end
                `RVV_VMV_V_I: begin
                    vector_control.operation         = V_MOVE;
                    vector_control.immediate_operand = `TRUE;
                end
                `RVV_VMSEQ_VV: vector_control.operation = V_EQ;
                `RVV_VMSLT_VV: vector_control.operation = V_LT;
                `RVV_VMAND_MM: vector_control.operation = V_AND;
                `RVV_VMOR_MM:  vector_control.operation = V_OR;
                `RV32_FENCE_, `RV32_FENCE_I: begin
                    // The in-order core drains older memory operations first.
                end
                `WFI: begin
                    halt = `TRUE;
                end
                default: begin
                    illegal = `TRUE;
                end
            endcase

            // The six vector CSR forms share scalar decode and operand capture.
            // Their architectural state and read-only checks live in the VEU.
            if (inst.r.opcode == `RV32_SYSTEM && inst.r.funct3 != 0 &&
                inst.r.funct3 != 4 && vector_csr(inst[31:20])) begin
                vector_control.operation = V_CSR;
                illegal  = `FALSE;
                csr_op   = `FALSE;
                has_dest = `TRUE;
                uses_rs1 = !inst[14];
            end
        end
    end

endmodule // decoder


module stage_id (
    input  IF_ID_PACKET  [1:0] if_id_reg,
    input  ID_EX_PACKET  [1:0] id_ex_reg,
    input  EX_MEM_PACKET [1:0] ex_mem_reg,
    input  DATA          [3:0] rf_read_data,
    input  logic               issue_enable,

    output REG_IDX       [3:0] rf_read_idx,
    output ID_EX_PACKET  [1:0] id_packet,
    output logic         [1:0] raw_hazard,
    output logic         [1:0] serial,
    output logic         [1:0] issue_count
);

    ID_EX_PACKET [1:0] controls;
    logic        [1:0] has_dest;

    // Four scalar read paths serve both instruction forms. The CPU's shared
    // register file supplies WB write-through on rf_read_data.
    for (genvar lane = 0; lane < 2; lane++) begin : decode_lanes
        assign rf_read_idx[lane*2]   = if_id_reg[lane].inst.r.rs1;
        assign rf_read_idx[lane*2+1] = if_id_reg[lane].inst.r.rs2;

        decoder decoder_0 (
            .inst          (if_id_reg[lane].inst),
            .valid         (if_id_reg[lane].valid),
            .opa_select    (controls[lane].opa_select),
            .opb_select    (controls[lane].opb_select),
            .alu_func      (controls[lane].alu_func),
            .has_dest      (has_dest[lane]),
            .mult          (controls[lane].mult),
            .rd_mem        (controls[lane].rd_mem),
            .wr_mem        (controls[lane].wr_mem),
            .cond_branch   (controls[lane].cond_branch),
            .uncond_branch (controls[lane].uncond_branch),
            .csr_op        (controls[lane].csr_op),
            .halt          (controls[lane].halt),
            .illegal       (controls[lane].illegal),
            .uses_rs1      (controls[lane].uses_rs1),
            .uses_rs2      (controls[lane].uses_rs2),
            .vector_control(controls[lane].vector_control)
        );

        assign controls[lane].inst         = if_id_reg[lane].inst;
        assign controls[lane].PC           = if_id_reg[lane].PC;
        assign controls[lane].NPC          = if_id_reg[lane].NPC;
        assign controls[lane].rs1_value    = rf_read_data[lane*2];
        assign controls[lane].rs2_value    = rf_read_data[lane*2+1];
        assign controls[lane].dest_reg_idx = has_dest[lane] ? if_id_reg[lane].inst.r.rd : `ZERO_REG;
        assign controls[lane].valid        = if_id_reg[lane].valid;
        assign controls[lane].exception    = if_id_reg[lane].exception;
    end

    // Capture scalar and vector scalar operands identically. ID/EX producers
    // stall consumers; MEM ALU results bypass here, while loads wait for WB.
    // Younger MEM lane wins a match. WAR is safe because operands are captured
    // before younger instructions execute and all issue remains in order.
    always_comb begin
        id_packet  = controls;
        raw_hazard = 0;
        serial     = 0;

        for (int lane = 0; lane < 2; lane++) begin
            for (int older = 0; older < 2; older++) begin
                if (ex_mem_reg[older].valid && ex_mem_reg[older].dest_reg_idx != 0) begin
                    if (controls[lane].uses_rs1 && ex_mem_reg[older].dest_reg_idx == rf_read_idx[lane*2]) begin
                        if (ex_mem_reg[older].rd_mem) begin
                            raw_hazard[lane] = 1;
                        end else begin
                            id_packet[lane].rs1_value = ex_mem_reg[older].take_branch ?
                                                        ex_mem_reg[older].NPC : ex_mem_reg[older].alu_result;
                        end
                    end
                    if (controls[lane].uses_rs2 && ex_mem_reg[older].dest_reg_idx == rf_read_idx[lane*2+1]) begin
                        if (ex_mem_reg[older].rd_mem) begin
                            raw_hazard[lane] = 1;
                        end else begin
                            id_packet[lane].rs2_value = ex_mem_reg[older].take_branch ?
                                                        ex_mem_reg[older].NPC : ex_mem_reg[older].alu_result;
                        end
                    end
                end
                if (id_ex_reg[older].valid && id_ex_reg[older].dest_reg_idx != 0 &&
                    ((controls[lane].uses_rs1 && id_ex_reg[older].dest_reg_idx == rf_read_idx[lane*2]) ||
                     (controls[lane].uses_rs2 && id_ex_reg[older].dest_reg_idx == rf_read_idx[lane*2+1]))) begin
                    raw_hazard[lane] = 1;
                end
            end

            serial[lane] = controls[lane].vector_control.operation != V_NONE ||
                           controls[lane].cond_branch || controls[lane].uncond_branch ||
                           controls[lane].wr_mem || controls[lane].csr_op ||
                           controls[lane].halt || controls[lane].illegal ||
                           controls[lane].exception != NO_ERROR ||
                           if_id_reg[lane].inst.r.opcode == `RV32_FENCE;
        end
    end

    // Serial classes issue alone. Same-pair RAW and WAW retain lane one for
    // the next cycle; independent scalar instructions can both issue.
    always_comb begin
        issue_count = 0;
        if (issue_enable && if_id_reg[0].valid && !raw_hazard[0]) begin
            issue_count = 1;
            if (if_id_reg[1].valid && !raw_hazard[1] && !serial[0] && !serial[1] &&
                !(id_packet[0].dest_reg_idx != 0 &&
                  ((id_packet[1].uses_rs1 && id_packet[0].dest_reg_idx == rf_read_idx[2]) ||
                   (id_packet[1].uses_rs2 && id_packet[0].dest_reg_idx == rf_read_idx[3]) ||
                   id_packet[0].dest_reg_idx == id_packet[1].dest_reg_idx))) begin
                issue_count = 2;
            end
        end
    end

endmodule // stage_id
