/////////////////////////////////////////////////////////////////////////
//                                                                     //
//   Modulename :  vector_unit.sv                                      //
//                                                                     //
//  Description :  Serialized integer RVV execution and vector state.  //
//                                                                     //
/////////////////////////////////////////////////////////////////////////

`include "sys_defs.svh"
`include "ISA.svh"

// Serialized, restartable integer RVV subset. The CPU starts this unit only
// after older instructions have drained and holds younger instructions until
// its response retires. This makes incremental vector writes precise without
// vector renaming or a second vector write port.
module vector_unit #(
    parameter integer VLEN = `RVV_VREG_WIDTH
) (
    // Clock & Reset
    input  logic          clock,
    input  logic          reset,

    // Core Interface Request
    input  logic          req_valid,
    output logic          req_ready,
    input  VECTOR_CONTROL req_control,
    input  INST           req_inst,
    input  DATA           req_rs1,
    input  DATA           req_rs2,

    // Core Interface Response
    output logic          busy,
    output logic          resp_valid,
    input  logic          resp_ready,
    output DATA           resp_data,
    output logic          resp_write_scalar,
    output logic          resp_illegal,
    output EXCEPTION_CODE resp_exception,

    // Memory Interface
    output logic          mem_valid,
    output logic          mem_write,
    output ADDR           mem_addr,
    output MEM_SIZE       mem_size,
    output DATA           mem_wdata,
    input  logic          mem_ready,
    input  logic          mem_resp_valid,
    input  DATA           mem_rdata
);

    // =========================================================================
    // Vector CSR Address Definitions
    // =========================================================================
    localparam logic [11:0] CSR_VSTART = 12'h008; // Vector start element index
    localparam logic [11:0] CSR_VXSAT  = 12'h009; // Fixed-point saturate flag
    localparam logic [11:0] CSR_VXRM   = 12'h00a; // Fixed-point rounding mode
    localparam logic [11:0] CSR_VCSR   = 12'h00f; // Vector control and status
    localparam logic [11:0] CSR_VL     = 12'hc20; // Vector length (Read-Only)
    localparam logic [11:0] CSR_VTYPE  = 12'hc21; // Vector data type (Read-Only)
    localparam logic [11:0] CSR_VLENB  = 12'hc22; // VLEN in bytes (Read-Only)

    // =========================================================================
    // Types & Signal Declarations
    // =========================================================================
    typedef enum logic [1:0] {
        V_IDLE,
        V_EXEC,
        V_RESP
    } VECTOR_STATE;

    VECTOR_STATE state;
    VECTOR_OP    operation, decoded_operation;

    // Architectural Vector State & CSRs
    logic [VLEN-1:0] vregs [0:31];
    DATA             vl, vtype, vstart;
    logic [1:0]      vxrm;
    logic            vxsat;

    // Execution Tracking Registers
    INST             instruction;
    DATA             scalar_operand, base_addr;
    integer          element, element_bits;
    logic            is_scalar, is_immediate;

    // Operand Field Extraction & Intermediate Control Logic
    logic            config_inst, csr_inst, recognized, decoded_scalar, decoded_immediate;
    logic            bad_instruction, cfg_bad, csr_write, csr_readonly, csr_supported;
    DATA             cfg_type, cfg_avl, cfg_vl, csr_old, csr_new, csr_source;
    integer          cfg_exp, cfg_max, current_max, emul_exp, group_count;
    integer          cfg_bits, decoded_bits;
    logic [4:0]      rd, vs1, vs2;
    logic [11:0]     csr_address;
    logic [2:0]      funct3;

    // Execution & Memory Generation Logic Signals
    integer          destination_reg, source1_reg, source2_reg, bit_offset;
    DATA             operand1, operand2, operation_result;
    logic            active_element, memory_operation, address_bad, address_misaligned;

    // =========================================================================
    // Helper Functions
    // =========================================================================
    function automatic integer lmul_exponent(input logic [2:0] encoding);
        case (encoding)
            3'b000:  return 0;
            3'b001:  return 1;
            3'b010:  return 2;
            3'b011:  return 3;
            3'b110:  return -2;
            3'b111:  return -1;
            default: return -99;
        endcase
    endfunction

    function automatic integer max_elements(input DATA type_value);
        integer count, exponent;
        begin
            count    = VLEN / (8 << type_value[5:3]);
            exponent = lmul_exponent(type_value[2:0]);

            if (exponent >= 0)
                count = count << exponent;
            else if (exponent >= -2)
                count = count >> (-exponent);
            else                     count = 0;

            return count;
        end
    endfunction

    function automatic logic legal_group(
        input logic [4:0] reg_num,
        input integer     exponent
    );
        integer count;
        begin
            count = (exponent > 0) ? (1 << exponent) : 1;
            return (exponent >= -3) && (exponent <= 3) &&
                   (int'(reg_num) % count == 0) &&
                   (int'(reg_num) + count <= 32);
        end
    endfunction

    // =========================================================================
    // Direct Interface Assignments
    // =========================================================================
    assign req_ready   = (state == V_IDLE);
    assign busy        = (state != V_IDLE);
    assign resp_valid  = (state == V_RESP);

    assign rd          = req_inst[11:7];
    assign vs1         = req_inst[19:15];
    assign vs2         = req_inst[24:20];
    assign funct3      = req_inst[14:12];
    assign csr_address = req_inst[31:20];

    // =========================================================================
    // Decoded Request & Architectural Validation
    // =========================================================================
    always_comb begin
        config_inst       = (req_control.operation == V_CONFIG);
        csr_inst          = (req_control.operation == V_CSR);
        recognized        = (req_control.operation != V_NONE);
        decoded_operation = req_control.operation;
        decoded_scalar    = req_control.scalar_operand;
        decoded_immediate = req_control.immediate_operand;
        decoded_bits      = 8 << vtype[5:3];
        cfg_type          = 0;

        case (req_control.config_kind)
            V_CFG_VLI:  cfg_type = {21'b0, req_inst[30:20]};
            V_CFG_IVLI: cfg_type = {22'b0, req_inst[29:20]};
            V_CFG_VL:   cfg_type = req_rs2;
            default:    cfg_type = 0;
        endcase

        if (decoded_operation == V_LOAD || decoded_operation == V_STORE)
            decoded_bits = 8 << req_control.mem_size;

        cfg_bits    = 8 << cfg_type[5:3];
        cfg_exp     = lmul_exponent(cfg_type[2:0]);
        cfg_max     = max_elements(cfg_type);
        current_max = max_elements(vtype);
        cfg_bad     = (cfg_type[31:8] != 0) || (cfg_type[5:3] > 2) || (cfg_exp < -2);

        if (cfg_exp < 0 && cfg_bits > (32 >> (-cfg_exp)))
            cfg_bad = 1'b1;
        if (cfg_max == 0)
            cfg_bad = 1'b1;

        if (req_control.config_kind == V_CFG_IVLI) begin
            cfg_avl = {27'b0, vs1};
        end else if (vs1 != 0) begin
            cfg_avl = req_rs1;
        end else if (rd != 0) begin
            cfg_avl = 32'hffffffff;
        end else begin
            cfg_avl = vl;
            if (vtype[31] || cfg_max != current_max)
                cfg_bad = 1'b1;
        end
        cfg_vl = cfg_bad ? 0 : ((cfg_avl < DATA'(cfg_max)) ? cfg_avl : DATA'(cfg_max));

        csr_old       = 0;
        csr_readonly  = 1'b0;
        csr_supported = 1'b1;
        case (csr_address)
            CSR_VSTART: csr_old = vstart;
            CSR_VXSAT:  csr_old = {31'b0, vxsat};
            CSR_VXRM:   csr_old = {30'b0, vxrm};
            CSR_VCSR:   csr_old = {29'b0, vxrm, vxsat};
            CSR_VL:    begin
                csr_old      = vl;
                csr_readonly = 1'b1;
            end
            CSR_VTYPE: begin
                csr_old      = vtype;
                csr_readonly = 1'b1;
            end
            CSR_VLENB: begin
                csr_old      = VLEN/8;
                csr_readonly = 1'b1;
            end
            default: csr_supported = 1'b0;
        endcase

        csr_source = funct3[2] ? {27'b0, vs1} : req_rs1;
        csr_write  = (funct3[1:0] == 1) || (vs1 != 0);

        case (funct3[1:0])
            2'b01:   csr_new = csr_source;
            2'b10:   csr_new = csr_old | csr_source;
            2'b11:   csr_new = csr_old & ~csr_source;
            default: csr_new = csr_old;
        endcase

        bad_instruction = !recognized;
        emul_exp        = lmul_exponent(vtype[2:0]);

        if (decoded_operation == V_LOAD || decoded_operation == V_STORE) begin
            if (decoded_bits == 16)
                emul_exp = emul_exp + 1;
            if (decoded_bits == 32)
                emul_exp = emul_exp + 2;
            emul_exp = emul_exp - int'(vtype[5:3]);
        end

        group_count = (emul_exp > 0 && emul_exp <= 3) ? (1 << emul_exp) : 1;

        if (csr_inst) begin
            if (!csr_supported || (csr_readonly && csr_write))
                bad_instruction = 1'b1;
        end else if (!config_inst) begin
            if (vtype[31])
                bad_instruction = 1'b1;

            if (decoded_operation == V_AND || decoded_operation == V_OR) begin
                // Mask operands each occupy one register, independent of LMUL.
            end else if (decoded_operation == V_LOAD || decoded_operation == V_STORE) begin
                if (!legal_group(rd, emul_exp))
                    bad_instruction = 1'b1;
                if (!req_inst[25] && rd == 0)
                    bad_instruction = 1'b1;
            end else begin
                if (decoded_operation != V_MOVE && !legal_group(vs2, emul_exp))
                    bad_instruction = 1'b1;
                if (!decoded_scalar && !decoded_immediate && !legal_group(vs1, emul_exp))
                    bad_instruction = 1'b1;

                if (decoded_operation == V_EQ || decoded_operation == V_LT) begin
                    if (int'(rd) > int'(vs2) && int'(rd) < int'(vs2) + group_count)
                        bad_instruction = 1'b1;
                    if (int'(rd) > int'(vs1) && int'(rd) < int'(vs1) + group_count)
                        bad_instruction = 1'b1;
                end else begin
                    if (!legal_group(rd, emul_exp))
                        bad_instruction = 1'b1;
                    if (!req_inst[25] && rd == 0)
                        bad_instruction = 1'b1;
                end

                if (!req_inst[25] && (vs2 == 0 || (!decoded_scalar && !decoded_immediate && vs1 == 0)))
                    begin
                    bad_instruction = 1'b1;
                end
            end
        end
    end

    // =========================================================================
    // Execution Data Path & Memory Address Calculation Logic
    // =========================================================================
    always_comb begin
        memory_operation = (operation == V_LOAD) || (operation == V_STORE);
        bit_offset       = (element * element_bits) % VLEN;
        destination_reg  = int'(instruction[11:7])  + (element * element_bits) / VLEN;
        source1_reg      = int'(instruction[19:15]) + (element * element_bits) / VLEN;
        source2_reg      = int'(instruction[24:20]) + (element * element_bits) / VLEN;
        operand1         = 0;
        operand2         = 0;

        if (state == V_EXEC && element < int'(vl) && !memory_operation &&
            operation != V_AND && operation != V_OR) begin
            case (element_bits)
                8: begin
                    if (!is_scalar && !is_immediate)
                        operand1 = {24'b0, vregs[source1_reg][bit_offset +: 8]};
                    if (operation != V_MOVE)
                        operand2 = {24'b0, vregs[source2_reg][bit_offset +: 8]};
                end
                16: begin
                    if (!is_scalar && !is_immediate)
                        operand1 = {16'b0, vregs[source1_reg][bit_offset +: 16]};
                    if (operation != V_MOVE)
                        operand2 = {16'b0, vregs[source2_reg][bit_offset +: 16]};
                end
                default: begin
                    if (!is_scalar && !is_immediate)
                        operand1 = vregs[source1_reg][bit_offset +: 32];
                    if (operation != V_MOVE)
                        operand2 = vregs[source2_reg][bit_offset +: 32];
                end
            endcase
        end

        if (is_scalar || is_immediate)
            operand1 = scalar_operand;

        operation_result = 0;
        case (operation)
            V_ADD:  operation_result = operand2 + operand1;
            V_SUB:  operation_result = operand2 - operand1;
            V_MOVE: operation_result = operand1;
            V_EQ:   operation_result = {31'b0, (operand2 == operand1)};
            V_LT: begin
                case (element_bits)
                    8:       operation_result = {31'b0, ($signed(operand2[7:0])  <$signed(operand1[7:0]))};
                    16:      operation_result = {31'b0, ($signed(operand2[15:0]) <$signed(operand1[15:0]))};
                    default: operation_result = {31'b0, ($signed(operand2)       <$signed(operand1))};
                endcase
            end
            default: begin end
        endcase

        active_element = 1'b0;
        if (state == V_EXEC && element < int'(vl)) begin
            active_element = instruction[25] || vregs[0][element];
        end

        mem_addr = base_addr + DATA'(element * (element_bits / 8));
        mem_size = (element_bits == 8) ? BYTE : ((element_bits == 16) ? HALF : WORD);
        address_misaligned = (element_bits == 16 && mem_addr[0]) ||
                             (element_bits == 32 && mem_addr[1:0] != 0);
        address_bad        = {1'b0, mem_addr} + 33'(element_bits / 8) > 33'(`MEM_SIZE_IN_BYTES);

        mem_valid = (state == V_EXEC) && memory_operation && active_element &&
                    !address_bad && !address_misaligned;
        mem_write = (operation == V_STORE);

        mem_wdata = 0;
        if (state == V_EXEC && operation == V_STORE && element < int'(vl)) begin
            case (element_bits)
                8:       mem_wdata = {24'b0, vregs[destination_reg][bit_offset +: 8]};
                16:      mem_wdata = {16'b0, vregs[destination_reg][bit_offset +: 16]};
                default: mem_wdata = vregs[destination_reg][bit_offset +: 32];
            endcase
        end
    end

    // =========================================================================
    // Sequential Control & Register Update State Machine
    // =========================================================================
    always_ff @(posedge clock) begin
        if (reset) begin
            state             <= V_IDLE;
            vl                <= 0;
            vtype             <= 32'h80000000;
            vstart            <= 0;
            vxrm              <= 0;
            vxsat             <= 0;
            instruction       <= `NOP;
            operation         <= V_ADD;
            scalar_operand    <= 0;
            base_addr         <= 0;
            element           <= 0;
            element_bits      <= 8;
            is_scalar         <= 0;
            is_immediate      <= 0;
            resp_data         <= 0;
            resp_write_scalar <= 0;
            resp_illegal      <= 0;
            resp_exception    <= NO_ERROR;
            for (integer r = 0; r < 32; r = r + 1) begin
                vregs[r] <= 0;
            end
        end else begin
            case (state)
                V_IDLE: begin
                    if (req_valid) begin
                        resp_data         <= 0;
                        resp_write_scalar <= 0;
                        resp_illegal      <= bad_instruction;
                        resp_exception    <= bad_instruction ? ILLEGAL_INST : NO_ERROR;

                        if (bad_instruction) begin
                            state <= V_RESP;
                        end else if (config_inst) begin
                            vtype             <= cfg_bad ? 32'h80000000 : cfg_type;
                            vl                <= cfg_vl;
                            vstart            <= 0;
                            resp_data         <= cfg_vl;
                            resp_write_scalar <= 1'b1;
                            state             <= V_RESP;
                        end else if (csr_inst) begin
                            resp_data         <= csr_old;
                            resp_write_scalar <= 1'b1;
                            if (csr_write) begin
                                case (csr_address)
                                    CSR_VSTART: vstart <= csr_new & DATA'(VLEN-1);
                                    CSR_VXSAT:  vxsat  <= csr_new[0];
                                    CSR_VXRM:   vxrm   <= csr_new[1:0];
                                    CSR_VCSR:   begin
                                        vxrm  <= csr_new[2:1];
                                        vxsat <= csr_new[0];
                                    end
                                    default: begin end
                                endcase
                            end
                            state <= V_RESP;
                        end else begin
                            instruction    <= req_inst;
                            operation      <= decoded_operation;
                            scalar_operand <= decoded_immediate ? {{27{req_inst[19]}}, req_inst[19:15]} :
                                req_rs1;
                            base_addr      <= req_rs1;
                            element        <= int'(vstart);
                            element_bits   <= decoded_bits;
                            is_scalar      <= decoded_scalar;
                            is_immediate   <= decoded_immediate;
                            state          <= V_EXEC;
                        end
                    end
                end

                V_EXEC: begin
                    if (element >= int'(vl)) begin
                        vstart <= 0;
                        state  <= V_RESP;
                    end else if (!active_element) begin
                        element <= element + 1;
                    end else if (memory_operation) begin
                        if (address_bad || address_misaligned) begin
                            vstart <= DATA'(element);
                            if (operation == V_LOAD)
                                resp_exception <= address_misaligned ? LOAD_ADDR_MISALIGN :
                                    LOAD_ACCESS_FAULT;
                            else
                                resp_exception <= address_misaligned ? STORE_ADDR_MISALIGN :
                                    STORE_ACCESS_FAULT;
                            state <= V_RESP;
                        end else if (mem_ready && (operation == V_STORE || mem_resp_valid)) begin
                            if (operation == V_LOAD) begin
                                case (element_bits)
                                    8:       vregs[destination_reg][bit_offset +: 8]  <= mem_rdata[7:0];
                                    16:      vregs[destination_reg][bit_offset +: 16] <= mem_rdata[15:0];
                                    default: vregs[destination_reg][bit_offset +: 32] <= mem_rdata;
                                endcase
                            end
                            element <= element + 1;
                        end
                    end else begin
                        if (operation == V_AND)
                            vregs[instruction[11:7]][element] <= vregs[instruction[24:20]][element] &
                                vregs[instruction[19:15]][element];
                        else if (operation == V_OR)
                            vregs[instruction[11:7]][element] <= vregs[instruction[24:20]][element] |
                                vregs[instruction[19:15]][element];
                        else if (operation == V_EQ || operation == V_LT)
                            vregs[instruction[11:7]][element] <= operation_result[0];
                        else begin
                            case (element_bits)
                                8:       vregs[destination_reg][bit_offset +: 8]  <= operation_result[7:0];
                                16:      vregs[destination_reg][bit_offset +: 16] <= operation_result[15:0];
                                default: vregs[destination_reg][bit_offset +: 32] <= operation_result;
                            endcase
                        end
                        element <= element + 1;
                    end
                end

                V_RESP: begin
                    if (resp_ready)
                        state <= V_IDLE;
                end

                default: state <= V_IDLE;
            endcase
        end
    end

endmodule
