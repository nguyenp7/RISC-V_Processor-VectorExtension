/////////////////////////////////////////////////////////////////////////
//                                                                     //
//   Modulename :  stage_if.sv                                         //
//                                                                     //
//  Description :  instruction fetch (IF) stage of the pipeline;       //
//                 fetch instruction, compute next PC location, and    //
//                 send them down the pipeline.                        //
//                                                                     //
/////////////////////////////////////////////////////////////////////////

`include "sys_defs.svh"

module stage_if (
    input           clock,          // system clock
    input           reset,          // system reset
    input           if_valid,       // only go to next PC when true
    input           take_branch,    // taken-branch signal
    input ADDR      branch_target,  // target pc: use if take_branch is TRUE
    input MEM_BLOCK Imem_data,      // data coming back from Instruction memory

    output IF_ID_PACKET if_packet,
    output ADDR         Imem_addr // address sent to Instruction memory
);

    ADDR PC_reg; // PC we are currently fetching

    always_ff @(posedge clock) begin
        if (reset) begin
            PC_reg <= 0;             // initial PC value is 0 (the memory address where our program starts)
        end else if (take_branch) begin
            PC_reg <= branch_target; // update to a taken branch (does not depend on valid bit)
        end else if (if_valid) begin
            PC_reg <= PC_reg + 4;    // or transition to next PC if valid
        end
    end

    // address of the instruction we're fetching (64 bit memory lines)
    // mem always gives us 8=2^3 bytes, so ignore the last 3 bits
    assign Imem_addr = {PC_reg[31:3], 3'b0};

    // index into the word (32-bits) of memory that matches this instruction
    assign if_packet.inst = (if_valid) ? Imem_data.word_level[PC_reg[2]] : `NOP;

    assign if_packet.PC  = PC_reg;
    assign if_packet.NPC = PC_reg + 4; // pass PC+4 down pipeline w/instruction

    assign if_packet.valid = if_valid;
    assign if_packet.exception = NO_ERROR;

endmodule // stage_if

module stage_if_dual (
    input clock, reset,
    input logic [1:0] advance,
    input logic redirect,
    input ADDR redirect_pc,
    input MEM_BLOCK line_data,
    input logic line_valid,
    output ADDR PC_reg,
    output ADDR Imem_addr,
    output IF_ID_PACKET [1:0] if_packet
);
    always_ff @(posedge clock) begin
        if (reset) PC_reg <= 0;
        else if (redirect) PC_reg <= redirect_pc;
        else PC_reg <= PC_reg + {28'b0, advance, 2'b0};
    end
    assign Imem_addr = {PC_reg[31:3], 3'b0};
    always_comb begin
        if_packet = '0;
        for (int lane=0; lane<2; lane++) begin
            if_packet[lane].PC = PC_reg + 32'(lane*4);
            if_packet[lane].NPC = PC_reg + 32'(lane*4+4);
            if_packet[lane].exception = NO_ERROR;
        end
        if_packet[0].inst = line_data.word_level[PC_reg[2]];
        if_packet[1].inst = line_data.word_level[1];
        if_packet[0].valid = line_valid;
        if_packet[1].valid = line_valid && !PC_reg[2];
        if (PC_reg[1:0] != 0 || PC_reg >= `MEM_SIZE_IN_BYTES) begin
            if_packet[0].valid = 1;
            if_packet[1].valid = 0;
            if_packet[0].inst = `NOP;
            if_packet[0].exception = PC_reg[1:0] != 0 ?
                                    INST_ADDR_MISALIGN : INST_ACCESS_FAULT;
        end
    end
endmodule
