/////////////////////////////////////////////////////////////////////////
//                                                                     //
//   Modulename :  dcache.sv                                            //
//                                                                     //
//  Description :  Two-read-port data cache with coherent array          //
//                 replicas, tagged refills, and write-through stores.   //
//                                                                     //
/////////////////////////////////////////////////////////////////////////
`include "sys_defs.svh"

// Two logical read ports backed by two replicated 1R1W arrays.
//
// - Both replicas receive every refill and byte-masked store update.
// - Asynchronous reads infer registers and muxes; FPGA block RAM may require
//   a target-specific synchronous-memory wrapper.
// - Requests are held until ready. Read ready is equivalent to rsp_valid.
// - Read data is zero-extended.
// - Stores are write-through and write-no-allocate; they complete when the
//   backing memory accepts the store.
// - At most one refill may be outstanding. Resident hits remain available
//   while a refill is pending.
// - Writes suppress both read responses, defining write-before-read conflict
//   semantics.

module dcache #(
    parameter integer LINES      = 32,
    parameter integer INDEX_BITS = $clog2(LINES),
    parameter integer TAG_BITS   = 32 - INDEX_BITS - 3
) (
    input  logic          clock,
    input  logic          reset,

    input  logic [1:0]    rvalid,
    input  ADDR [1:0]     raddr,
    input  MEM_SIZE [1:0] rsize,
    output logic [1:0]    rready,
    output logic [1:0]    rsp_valid,
    output DATA [1:0]     rdata,

    input  logic       wvalid,
    input  ADDR        waddr,
    input  MEM_SIZE    wsize,
    input  DATA        wdata,
    output logic       wready,

    output MEM_COMMAND mem_command,
    output ADDR        mem_addr,
    output MEM_BLOCK   mem_data,
    output MEM_SIZE    mem_size,

    input  MEM_TAG     mem_transaction_tag,
    input  MEM_BLOCK   mem_data_in,
    input  MEM_TAG     mem_data_tag
);

    // ---- Cache storage ---- //

    MEM_BLOCK            data_array  [0:1][0:LINES-1];
    logic [TAG_BITS-1:0]  tag_array   [0:1][0:LINES-1];
    logic                valid_array [0:1][0:LINES-1];

    // ---- Read-hit and refill tracking ---- //

    logic [1:0] hit;

    logic       miss_pending;
    ADDR        miss_addr;
    MEM_TAG     miss_tag;

    ADDR        selected_miss_addr;
    logic       selected_miss_valid;

    logic       fill_valid;
    ADDR        fill_addr;

    logic [INDEX_BITS-1:0] write_index, fill_index;
    logic [TAG_BITS-1:0]   write_tag, fill_tag;

    // ---- Read-data extraction ---- //

    function automatic DATA read_access(
        input MEM_BLOCK line_data,
        input logic [2:0] offset,
        input MEM_SIZE size
    );
        logic [63:0] shifted;

        begin
            shifted = line_data.dbbl_level >> (8 * offset);

            case (size)
                BYTE:    read_access = {24'b0, shifted[7:0]};
                HALF:    read_access = {16'b0, shifted[15:0]};
                default: read_access = shifted[31:0];
            endcase
        end
    endfunction

    // ---- Read ports ---- //
    // Each port accesses its own physical array replica, so simultaneous
    // reads do not conflict, even when their indices are identical.

    always_comb begin
        for (int p = 0; p < 2; p++) begin
            hit[p] =
                valid_array[p][raddr[p][INDEX_BITS+2:3]] &&
                (tag_array[p][raddr[p][INDEX_BITS+2:3]] ==
                 raddr[p][31:INDEX_BITS+3]);

            rsp_valid[p] =
                rvalid[p] && hit[p] && !wvalid && !reset;

            rready[p] = rsp_valid[p];

            rdata[p] = read_access(
                data_array[p][raddr[p][INDEX_BITS+2:3]],
                raddr[p][2:0],
                rsize[p]
            );
        end
    end

    // ---- Miss selection and backing-memory interface ---- //
    // Port 0 has priority when both ports miss.

    always_comb begin
        selected_miss_valid = 1'b0;
        selected_miss_addr  = '0;

        if (rvalid[0] && !hit[0]) begin
            selected_miss_valid = 1'b1;
            selected_miss_addr  = {raddr[0][31:3], 3'b0};
        end else if (rvalid[1] && !hit[1]) begin
            selected_miss_valid = 1'b1;
            selected_miss_addr  = {raddr[1][31:3], 3'b0};
        end

        mem_command = MEM_NONE;
        mem_addr    = '0;
        mem_data    = '0;
        mem_size    = DOUBLE;

        if (!reset && !miss_pending) begin
            if (wvalid) begin
                mem_command = MEM_STORE;
                mem_addr    = waddr;
                mem_data    = {32'b0, wdata};
                mem_size    = wsize;
            end else if (selected_miss_valid) begin
                mem_command = MEM_LOAD;
                mem_addr    = selected_miss_addr;
            end
        end

        // A store completes when the backing memory accepts it.
        wready =
            wvalid &&
            (mem_command == MEM_STORE) &&
            (mem_transaction_tag != 0);

        // A refill may return in the same cycle its request is accepted.
        fill_valid = 1'b0;
        fill_addr  = miss_addr;

        if (miss_pending) begin
            fill_valid =
                (miss_tag != 0) &&
                (mem_data_tag == miss_tag);
        end else if (
            (mem_command == MEM_LOAD) &&
            (mem_transaction_tag != 0)
        ) begin
            fill_valid = (mem_data_tag == mem_transaction_tag);
            fill_addr  = selected_miss_addr;
        end
    end

    // ---- Address decomposition ---- //

    assign write_index = waddr[INDEX_BITS+2:3];
    assign write_tag   = waddr[31:INDEX_BITS+3];

    assign fill_index  = fill_addr[INDEX_BITS+2:3];
    assign fill_tag    = fill_addr[31:INDEX_BITS+3];

    // ---- Cache state and data updates ---- //

    always_ff @(posedge clock) begin
        if (reset) begin
            miss_pending <= 1'b0;
            miss_addr    <= '0;
            miss_tag     <= '0;

            for (int p = 0; p < 2; p++) begin
                for (int l = 0; l < LINES; l++) begin
                    valid_array[p][l] <= 1'b0;
                    tag_array[p][l]   <= '0;
                    data_array[p][l]  <= '0;
                end
            end
        end else begin

            // Track the outstanding refill.
            if (
                (mem_command == MEM_LOAD) &&
                (mem_transaction_tag != 0)
            ) begin
                miss_pending <= !fill_valid;
                miss_addr    <= selected_miss_addr;
                miss_tag     <= mem_transaction_tag;
            end else if (fill_valid) begin
                miss_pending <= 1'b0;
                miss_tag     <= '0;
            end

            // Keep both replicas coherent.
            for (int p = 0; p < 2; p++) begin
                if (fill_valid) begin
                    data_array[p][fill_index]  <= mem_data_in;
                    tag_array[p][fill_index]   <= fill_tag;
                    valid_array[p][fill_index] <= 1'b1;

                end else if (
                    wready &&
                    valid_array[p][write_index] &&
                    (tag_array[p][write_index] == write_tag)
                ) begin
                    // Mirror the backing-memory byte-enable behavior.
                    for (int b = 0; b < 4; b++) begin
                        if (b < (1 << wsize)) begin
                            data_array[p][write_index]
                                .byte_level[int'(waddr[2:0]) + b]
                                <= wdata[8*b +: 8];
                        end
                    end
                end
            end
        end
    end

    // ---- Parameter validation ---- //

`ifndef SYNTH
    initial begin
        if (LINES < 2 || (1 << INDEX_BITS) != LINES) begin
            $fatal(1, "dcache LINES must be a power of two >= 2");
        end
    end
`endif

endmodule // dcache
