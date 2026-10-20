/////////////////////////////////////////////////////////////////////////
//                                                                     //
//   Modulename :  stage_ex.sv                                         //
//                                                                     //
//  Description :  instruction execute (EX) stage of the pipeline;     //
//                 given the instruction command code CMD, select the  //
//                 proper input A and B for the ALU, compute the       //
//                 result, and compute the condition for branches, and //
//                 pass all the results down the pipeline.             //
//                                                                     //
/////////////////////////////////////////////////////////////////////////

`include "sys_defs.svh"
`include "ISA.svh"

// ALU: computes the result of FUNC applied with operands A and B
// This module is purely combinational
module alu (
    input DATA     opa,
    input DATA     opb,
    input ALU_FUNC alu_func,

    output DATA result
);

    always_comb begin
        case (alu_func)
            ALU_ADD:  result = opa + opb;
            ALU_SUB:  result = opa - opb;
            ALU_AND:  result = opa & opb;
            ALU_SLT:  result = {31'b0, (signed'(opa) < signed'(opb))};
            ALU_SLTU: result = {31'b0, (opa < opb)};
            ALU_OR:   result = opa | opb;
            ALU_XOR:  result = opa ^ opb;
            ALU_SRL:  result = opa >> opb[4:0];
            ALU_SLL:  result = opa << opb[4:0];
            ALU_SRA:  result = signed'(opa) >>> opb[4:0]; // arithmetic from logical shift
            // here to prevent latches:
            default:  result = 32'hfacebeec;
        endcase
    end

endmodule // alu


// Mult module: multiplies the registers
// We let verilog do the full 32-bit multiplication for us, but this gives a large clock period
// You will replace this with the p2 pipelined multiplier in final project
// This module is purely combinational
module mult (
    input DATA       rs1,
    input DATA       rs2,
    input MULT_FUNC3 func, // Specifies which operation to perform

    output DATA result
);

    logic signed [63:0] signed_mul, mixed_mul;
    logic [63:0] unsigned_mul;

    assign unsigned_mul = rs1 * rs2;
    assign signed_mul   = signed'(rs1) * signed'(rs2);
    assign mixed_mul    = signed'(rs1) * signed'({1'b0, rs2});
    // ^ Verilog only does signed multiplication if both arguments are signed
    // This was a long-standing bug with mixed_mul in VeriSimpleV

    always_comb begin
        case (func)
            M_MUL:     result = signed_mul[31:0];
            M_MULH:    result = signed_mul[63:32];
            M_MULHSU:  result = mixed_mul[63:32];
            M_MULHU:   result = unsigned_mul[63:32];
            default: result = 32'hfacebeec;
        endcase
    end

endmodule // mult


// Conditional branch module: compute whether to take conditional branches
// This module is purely combinational
module conditional_branch (
    input DATA  rs1,
    input DATA  rs2,
    input [2:0] func, // Which branch condition to check

    output logic take // True/False condition result
);

    always_comb begin
        case (func)
            3'b000:  take = signed'(rs1) == signed'(rs2); // BEQ
            3'b001:  take = signed'(rs1) != signed'(rs2); // BNE
            3'b100:  take = signed'(rs1) <  signed'(rs2); // BLT
            3'b101:  take = signed'(rs1) >= signed'(rs2); // BGE
            3'b110:  take = rs1 < rs2;                    // BLTU
            3'b111:  take = rs1 >= rs2;                   // BGEU
            default: take = `FALSE;
        endcase
    end

endmodule // conditional_branch


module stage_ex (
    input ID_EX_PACKET id_ex_reg,
    input EX_MEM_PACKET ex_mem_reg,
    input MEM_WB_PACKET mem_wb_reg,

    output EX_MEM_PACKET ex_packet
);

    DATA alu_result, mult_result, opa_mux_out, opb_mux_out;
    logic take_conditional;

    // Forwarding from MEM and WB:
    logic AvalidForwardMem, BvalidForwardMem;
    logic AvalidForwardWB,  BvalidForwardWB;

    logic [4:0] id_ex_rs1, id_ex_rs2;
    assign id_ex_rs1 = id_ex_reg.inst.r.rs1;
    assign id_ex_rs2 = id_ex_reg.inst.r.rs2;

    // Select correct forwarded data for taken branches (NPC for link)
    DATA forward_data_ex_mem, forward_data_mem_wb;
    assign forward_data_ex_mem = ex_mem_reg.take_branch ? ex_mem_reg.NPC : ex_mem_reg.alu_result;
    assign forward_data_mem_wb = mem_wb_reg.take_branch ? mem_wb_reg.NPC : mem_wb_reg.result;

    assign AvalidForwardMem = (ex_mem_reg.valid & ~ex_mem_reg.illegal) &
                              ~ex_mem_reg.rd_mem &
                              (ex_mem_reg.dest_reg_idx != `ZERO_REG) &
                              id_ex_reg.uses_rs1 &
                              (ex_mem_reg.dest_reg_idx == id_ex_rs1);

    assign BvalidForwardMem = (ex_mem_reg.valid & ~ex_mem_reg.illegal) &
                              ~ex_mem_reg.rd_mem &
                              (ex_mem_reg.dest_reg_idx != `ZERO_REG) &
                              id_ex_reg.uses_rs2 &
                              (ex_mem_reg.dest_reg_idx == id_ex_rs2);

    assign AvalidForwardWB = (mem_wb_reg.valid & ~mem_wb_reg.illegal) &
                             (mem_wb_reg.dest_reg_idx != `ZERO_REG) &
                             id_ex_reg.uses_rs1 &
                             (mem_wb_reg.dest_reg_idx == id_ex_rs1);

    assign BvalidForwardWB = (mem_wb_reg.valid & ~mem_wb_reg.illegal) &
                             (mem_wb_reg.dest_reg_idx != `ZERO_REG) &
                             id_ex_reg.uses_rs2 &
                             (mem_wb_reg.dest_reg_idx == id_ex_rs2);

    DATA rs1_forward, rs2_forward;
    assign rs1_forward = AvalidForwardMem ? forward_data_ex_mem :
                         AvalidForwardWB  ? forward_data_mem_wb :
                         id_ex_reg.rs1_value;

    assign rs2_forward = BvalidForwardMem ? forward_data_ex_mem :
                         BvalidForwardWB  ? forward_data_mem_wb :
                         id_ex_reg.rs2_value;

    // Pass-throughs
    assign ex_packet.NPC          = id_ex_reg.NPC;
    assign ex_packet.rd_mem       = id_ex_reg.rd_mem;
    assign ex_packet.wr_mem       = id_ex_reg.wr_mem;
    assign ex_packet.dest_reg_idx = id_ex_reg.dest_reg_idx;
    assign ex_packet.halt         = id_ex_reg.halt;
    assign ex_packet.illegal      = id_ex_reg.illegal;
    assign ex_packet.csr_op       = id_ex_reg.csr_op;
    assign ex_packet.valid        = id_ex_reg.valid;
    assign ex_packet.exception    = id_ex_reg.exception;

    // Send rs2_value to the mem stage as the data for a store
    assign ex_packet.rs2_value = rs2_forward;

    // Break out the signed/unsigned bit and memory read/write size
    assign ex_packet.rd_unsigned = id_ex_reg.inst.r.funct3[2];
    assign ex_packet.mem_size    = MEM_SIZE'(id_ex_reg.inst.r.funct3[1:0]);

    // Ultimate "take branch" signal
    assign ex_packet.take_branch = id_ex_reg.uncond_branch || (id_ex_reg.cond_branch && take_conditional);

    // ALU opA mux
    always_comb begin
        case (id_ex_reg.opa_select)
            OPA_IS_RS1:  opa_mux_out = rs1_forward;
            OPA_IS_NPC:  opa_mux_out = id_ex_reg.NPC;
            OPA_IS_PC:   opa_mux_out = id_ex_reg.PC;
            OPA_IS_ZERO: opa_mux_out = 0;
            default:     opa_mux_out = 32'hdeadface;
        endcase
    end

    // ALU opB mux
    always_comb begin
        case (id_ex_reg.opb_select)
            OPB_IS_RS2:   opb_mux_out = rs2_forward;
            OPB_IS_I_IMM: opb_mux_out = `RV32_signext_Iimm(id_ex_reg.inst);
            OPB_IS_S_IMM: opb_mux_out = `RV32_signext_Simm(id_ex_reg.inst);
            OPB_IS_B_IMM: opb_mux_out = `RV32_signext_Bimm(id_ex_reg.inst);
            OPB_IS_U_IMM: opb_mux_out = `RV32_signext_Uimm(id_ex_reg.inst);
            OPB_IS_J_IMM: opb_mux_out = `RV32_signext_Jimm(id_ex_reg.inst);
            default:      opb_mux_out = 32'hfacefeed;
        endcase
    end

    // We split the alu and mult here since they will be split in the final project
    assign ex_packet.alu_result = id_ex_reg.mult ? mult_result :
        (id_ex_reg.inst.r.opcode == `RV32_JALR_OP ? {alu_result[31:1],1'b0} : alu_result);

    // Instantiate the ALU
    alu alu_0 (
        .opa(opa_mux_out),
        .opb(opb_mux_out),
        .alu_func(id_ex_reg.alu_func),
        .result(alu_result)
    );

    // Instantiate the multiplier
    mult mult_0 (
        .rs1(opa_mux_out),
        .rs2(opb_mux_out),
        .func(MULT_FUNC3'(id_ex_reg.inst.r.funct3)),
        .result(mult_result)
    );

    // Instantiate the conditional branch module
    conditional_branch conditional_branch_0 (
        .rs1(rs1_forward),
        .rs2(rs2_forward),
        .func(id_ex_reg.inst.b.funct3),
        .take(take_conditional)
    );

endmodule // stage_ex
