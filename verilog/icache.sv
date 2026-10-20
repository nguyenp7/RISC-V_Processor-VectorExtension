/////////////////////////////////////////////////////////////////////////
//                                                                     //
//   Modulename :  icache.sv                                            //
//                                                                     //
//  Description :  Blocking, direct-mapped instruction cache with       //
//                 tagged refills and explicit invalidation.            //
//                                                                     //
/////////////////////////////////////////////////////////////////////////

`include "sys_defs.svh"

// The saved refill address is independent of the current fetch address,
// so redirects cannot mis-tag returning data.
module icache #(
    parameter integer LINES      = 32,
    parameter integer INDEX_BITS = $clog2(LINES),
    parameter integer TAG_BITS   = 32 - INDEX_BITS - 3
) (
    input              clock,
    input              reset,
    input              request_valid,
    input              invalidate,

    // From memory
    input MEM_TAG      Imem2proc_transaction_tag,
    input MEM_BLOCK    Imem2proc_data,
    input MEM_TAG      Imem2proc_data_tag,

    // From fetch
    input ADDR         proc2Icache_addr,

    // To memory
    output MEM_COMMAND proc2Imem_command,
    output ADDR        proc2Imem_addr,

    // To fetch
    output MEM_BLOCK   Icache_data_out,
    output logic       Icache_valid_out
);

    // ---- Cache storage ---- //

    MEM_BLOCK            data_array  [0:LINES-1];
    logic [TAG_BITS-1:0]  tag_array   [0:LINES-1];
    logic                valid_array [0:LINES-1];

    // ---- Refill tracking ---- //

    logic                    pending;
    ADDR                     pending_addr;
    MEM_TAG                  pending_tag;
    logic                    fill_valid;
    ADDR                     fill_addr;
    logic [INDEX_BITS-1:0]    read_index, fill_index;

    // ---- Fetch lookup and memory request ---- //

    assign read_index        = proc2Icache_addr[INDEX_BITS+2:3];
    assign Icache_data_out   = data_array[read_index];
    assign Icache_valid_out  = request_valid && !reset && !invalidate &&
                               valid_array[read_index] &&
                               tag_array[read_index] == proc2Icache_addr[31:INDEX_BITS+3];
    assign proc2Imem_command = request_valid && !reset && !invalidate &&
                               !Icache_valid_out && !pending ? MEM_LOAD : MEM_NONE;
    assign proc2Imem_addr    = {proc2Icache_addr[31:3], 3'b0};

    // ---- Refill response matching ---- //

    always_comb begin
        fill_valid = 1'b0;
        fill_addr  = pending_addr;

        if (pending) begin
            fill_valid = pending_tag != 0 && pending_tag == Imem2proc_data_tag;
        end else if (proc2Imem_command == MEM_LOAD && Imem2proc_transaction_tag != 0) begin
            fill_valid = Imem2proc_data_tag == Imem2proc_transaction_tag;
            fill_addr  = proc2Imem_addr;
        end
    end

    assign fill_index = fill_addr[INDEX_BITS+2:3];

    // ---- Cache state and data updates ---- //

    always_ff @(posedge clock) begin
        if (reset || invalidate) begin
            pending      <= 1'b0;
            pending_addr <= '0;
            pending_tag  <= '0;

            for (int l = 0; l < LINES; l++) begin
                valid_array[l] <= 1'b0;
                tag_array[l]   <= '0;
                data_array[l]  <= '0;
            end
        end else begin
            if (proc2Imem_command == MEM_LOAD && Imem2proc_transaction_tag != 0) begin
                pending      <= !fill_valid;
                pending_addr <= proc2Imem_addr;
                pending_tag  <= Imem2proc_transaction_tag;
            end else if (fill_valid) begin
                pending     <= 1'b0;
                pending_tag <= '0;
            end

            if (fill_valid) begin
                data_array[fill_index]  <= Imem2proc_data;
                tag_array[fill_index]   <= fill_addr[31:INDEX_BITS+3];
                valid_array[fill_index] <= 1'b1;
            end
        end
    end

endmodule // icache
