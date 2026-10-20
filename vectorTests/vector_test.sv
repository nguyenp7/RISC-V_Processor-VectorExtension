/////////////////////////////////////////////////////////////////////////
//                                                                     //
//   Modulename :  vector_test.sv                                      //
//                                                                     //
//  Description :  Self-checking RVV integer and memory regression.    //
//                                                                     //
/////////////////////////////////////////////////////////////////////////

`include "sys_defs.svh"
`include "ISA.svh"

// Standalone RVV architectural tests. No vector state is injected: all vector
// operands are initialized with architectural loads or vmv.v.i instructions.
module vector_test;
    logic            clock = 0, reset = 1;
    always #5 clock = ~clock;
    logic            req_valid, req_ready, busy, resp_valid, resp_ready;
    INST             req_inst;
    VECTOR_CONTROL   req_control;
    DATA             req_rs1, req_rs2, resp_data;
    logic            resp_write_scalar, resp_illegal;
    EXCEPTION_CODE   resp_exception;
    logic            mem_valid, mem_write, mem_ready, mem_resp_valid;
    ADDR             mem_addr;
    MEM_SIZE         mem_size;
    DATA             mem_wdata, mem_rdata;
    byte unsigned    memory [0:65535];
    integer          cycles = 0, transactions = 0, checks = 0;
    logic            stalled_memory = 0;
    ADDR             held_addr;
    MEM_SIZE         held_size;
    DATA             held_wdata;
    logic            held_write;
    DATA             returned;
    integer          width, count, tests;
    logic [31:0]     expected, pattern1, pattern2, mask_expected;

    // Exercise the same decode boundary used by the processor. The vector
    // engine consumes the shared ID control packet rather than decoding again.
    decoder instruction_decoder (
        .inst(req_inst),
        .valid(req_valid),
        .opa_select(),
        .opb_select(),
        .has_dest(),
        .alu_func(),
        .mult(),
        .rd_mem(),
        .wr_mem(),
        .cond_branch(),
        .uncond_branch(),
        .csr_op(),
        .halt(),
        .illegal(),
        .uses_rs1(),
        .uses_rs2(),
        .vector_control(req_control)
    );

    vector_unit dut (.*);

    // -----------------------------------------------------------------
    // Cache completion model
    // -----------------------------------------------------------------
    always_comb begin
        // A completion-style cache port: requests must remain stable until
        // ready. Deliberate stalls exercise every vector memory instruction.
        mem_ready      = mem_valid && cycles % 3 == 0;
        mem_resp_valid = mem_ready && !mem_write;
        mem_rdata      = 0;
        if (mem_valid && !mem_write) begin
            case (mem_size)
                BYTE: mem_rdata = {24'b0, memory[mem_addr]};
                HALF: mem_rdata = {16'b0, memory[mem_addr+1], memory[mem_addr]};
                default: mem_rdata = {memory[mem_addr+3], memory[mem_addr+2], memory[mem_addr+1],
                    memory[mem_addr]};
            endcase
        end
    end

    // -----------------------------------------------------------------
    // Request stability and memory updates
    // -----------------------------------------------------------------
    always @(posedge clock) begin
        cycles <= cycles + 1;
        if (!reset && stalled_memory &&
            (!mem_valid || mem_addr != held_addr || mem_size != held_size ||
             mem_wdata != held_wdata || mem_write != held_write))
            $fatal(1, "vector memory request changed before completion");
        stalled_memory <= !reset && mem_valid && !mem_ready;
        held_addr      <= mem_addr;
        held_size      <= mem_size;
        held_wdata     <= mem_wdata;
        held_write     <= mem_write;
        if (mem_valid && mem_ready) begin
            transactions <= transactions + 1;
            if (mem_write) begin
                memory[mem_addr] <= mem_wdata[7:0];
                if (mem_size != BYTE)
                    memory[mem_addr+1] <= mem_wdata[15:8];
                if (mem_size == WORD) begin
                    memory[mem_addr+2] <= mem_wdata[23:16];
                    memory[mem_addr+3] <= mem_wdata[31:24];
                end
            end
        end
        if (cycles > 20000)
            $fatal(1, "vector test timeout");
    end

    // -----------------------------------------------------------------
    // Instruction encoding helpers
    // -----------------------------------------------------------------
    function automatic DATA op(input integer funct6, vm, src2, src1, funct3, dest);
        op = (DATA'(funct6) << 26) | (DATA'(vm) << 25) |
             (DATA'(src2) << 20) | (DATA'(src1) << 15) |
             (DATA'(funct3) << 12) | (DATA'(dest) << 7) | 32'h57;
    endfunction

    function automatic DATA vmem(input logic store, input integer eew, dest, vm);
        integer f3;
        begin
            f3 = eew == 8 ? 0 : (eew == 16 ? 5 : 6);
            vmem = (DATA'(vm) << 25) | (32'd1 << 15) |
                   (DATA'(f3) << 12) | (DATA'(dest) << 7) |
                   (store ? 32'h27 : 32'h07);
        end
    endfunction

    function automatic DATA setivli(input integer avl, vtype_value);
        setivli = 32'hc00070d7 | (DATA'(vtype_value) << 20) | (DATA'(avl) << 15);
    endfunction

    function automatic DATA csr(input integer address, f3, source, dest);
        csr = (DATA'(address) << 20) | (DATA'(source) << 15) |
              (DATA'(f3) << 12) | (DATA'(dest) << 7) | 32'h73;
    endfunction

    function automatic DATA lowmask(input integer bits);
        lowmask = bits == 32 ? 32'hffffffff : ((32'd1 << bits)-1);
    endfunction

    // -----------------------------------------------------------------
    // Architectural checks and request driver
    // -----------------------------------------------------------------
    task automatic check(input logic condition, input string label_text);
        begin
            checks = checks + 1;
            if (condition !== 1'b1)
                $fatal(1, "%s", label_text);
        end
    endtask

    task automatic run(input DATA insn, a, b, input EXCEPTION_CODE exception_value);
        DATA held_data;
        logic held_response_write;
        begin
            @(negedge clock);
            while (!req_ready)
                @(negedge clock);
            req_inst  = insn;
            req_rs1   = a;
            req_rs2   = b;
            req_valid = 1;
            @(negedge clock);
            req_valid = 0;
            while (!resp_valid)
                @(negedge clock);
            check(resp_exception == exception_value, $sformatf("exception for %08x got %0d expected %0d",
                insn, resp_exception, exception_value));
            check(resp_illegal == (exception_value == ILLEGAL_INST), "illegal status");
            held_data           = resp_data;
            held_response_write = resp_write_scalar;
            returned            = resp_data;
            repeat (2) begin
                @(negedge clock);
                check(resp_valid && busy && resp_data == held_data &&
                    resp_write_scalar == held_response_write,
                    "response changed under backpressure");
            end
            resp_ready = 1;
            @(negedge clock);
            resp_ready = 0;
        end
    endtask

    task automatic configure(input integer avl, type_value);
        begin
            run(setivli(avl, type_value), 0, 0, NO_ERROR);
            check(resp_write_scalar, "vsetivli scalar writeback");
        end
    endtask

    // -----------------------------------------------------------------
    // Architectural instruction tests
    // -----------------------------------------------------------------
    initial begin
        req_valid  = 0;
        resp_ready = 0;
        req_inst   = `NOP;
        req_rs1    = 0;
        req_rs2    = 0;
        for (integer i = 0; i < 65536; i = i+1) memory[i] = 0;
        memory[256] = 8'hff;
        memory[257] = 8'h80;
        memory[258] = 8'h01;
        memory[259] = 8'h7f;
        memory[272] = 8'h01;
        memory[273] = 8'h80;
        memory[274] = 8'hff;
        memory[275] = 8'h02;
        memory[288] = 8'h05; // mask bits 0101
        memory[304] = 8'h02; // only element one active
        repeat (3) @(negedge clock);
        reset = 0;

        // All three configurations, AVL conventions, and read-only CSRs.
        run(32'h000170d7, 3, 0, NO_ERROR); // vsetvli x1,x2,e8,m1
        check(returned == 3 && dut.vl == 3, "vsetvli AVL");
        run(32'h803170d7, 99, 8, NO_ERROR); // vsetvl x1,x2,x3, rs2 value=e16,m1
        check(returned == 2 && dut.vtype == 8, "vsetvl register vtype");
        run(csr('hc20, 2, 0, 2), 0, 0, NO_ERROR);
        check(returned == 2, "vl CSR");
        run(csr('hc21, 2, 0, 2), 0, 0, NO_ERROR);
        check(returned == 8, "vtype CSR");
        run(csr('hc22, 2, 0, 2), 0, 0, NO_ERROR);
        check(returned == 4, "vlenb CSR");
        run(csr('hc20, 1, 1, 2), 0, 0, ILLEGAL_INST);
        configure(31, 0);
        check(returned == 4, "AVL capped at VLMAX");
        run(32'h00007057, 0, 0, NO_ERROR); // rd=rs1=x0, same ratio keeps vl
        check(dut.vl == 4, "vsetvli preserve vl");
        run(32'h000070d7, 0, 0, NO_ERROR); // rs1=x0, rd nonzero -> VLMAX
        check(returned == 4, "vsetvli x0 AVL");

        // All arithmetic instructions at every supported SEW, with overflow,
        // signed comparison, signed immediate, and back-to-back dependencies.
        for (integer sew = 0; sew < 3; sew = sew+1) begin
            width = 8 << sew;
            count = 32/width;
            configure(count, sew << 3);
            run(vmem(0, width, 2, 1), 256, 0, NO_ERROR);
            run(vmem(0, width, 3, 1), 272, 0, NO_ERROR);
            run(op(0, 1, 2, 3, 0, 4), 0, 0, NO_ERROR); // vadd.vv
            expected = 0;
            for (integer i = 0; i < count; i=i+1) begin
                pattern1 = (32'h7f0180ff >> (i*width)) & lowmask(width);
                pattern2 = (32'h02ff8001 >> (i*width)) & lowmask(width);
                expected = expected | (((pattern1+pattern2) & lowmask(width)) << (i*width));
            end
            check(dut.vregs[4] == expected, "vadd.vv elements");
            run(op(2, 1, 4, 3, 0, 5), 0, 0, NO_ERROR); // dependent vsub.vv
            check(dut.vregs[5] == 32'h7f0180ff, "vsub.vv dependency");
            run(op(0, 1, 2, 1, 4, 4), 32'hffffffff, 0, NO_ERROR); // vadd.vx
            expected = 0;
            for (integer i = 0; i < count; i=i+1)
                expected = expected | (((((32'h7f0180ff >> (i*width)) & lowmask(width))-1) & lowmask(width))
                    << (i*width));
            check(dut.vregs[4] == expected, "vadd.vx truncation");
            run(op(2, 1, 4, 1, 4, 5), 32'hffffffff, 0, NO_ERROR); // vsub.vx
            check(dut.vregs[5] == 32'h7f0180ff, "vsub.vx");
            run(op(0, 1, 2, 31, 3, 4), 0, 0, NO_ERROR); // vadd.vi -1
            check(dut.vregs[4] == expected, "vadd.vi signed immediate");
            run(op(23, 1, 0, 16, 3, 5), 0, 0, NO_ERROR); // vmv.v.i -16
            expected = 0;
            for (integer i = 0; i < count; i=i+1)
                expected = expected | ((32'hfffffff0 & lowmask(width)) << (i*width));
            check(dut.vregs[5] == expected, "vmv.v.i sign extension");
            run(op(24, 1, 2, 3, 0, 6), 0, 0, NO_ERROR); // vmseq.vv
            mask_expected = sew == 0 ? 2 : 0;
            check((dut.vregs[6] & lowmask(count)) == mask_expected, "vmseq.vv mask layout");
            run(op(27, 1, 2, 3, 0, 7), 0, 0, NO_ERROR); // vmslt.vv
            mask_expected = sew == 0 ? 1 : 0;
            check((dut.vregs[7] & lowmask(count)) == mask_expected, "vmslt.vv signed compare");
            run(op(25, 1, 6, 7, 2, 8), 0, 0, NO_ERROR); // vmand.mm
            check((dut.vregs[8] & lowmask(count)) == 0, "vmand.mm");
            run(op(26, 1, 6, 7, 2, 9), 0, 0, NO_ERROR); // vmor.mm
            check((dut.vregs[9] & lowmask(count)) == (sew == 0 ? 3 : mask_expected), "vmor.mm");

            run(vmem(0, 8, 0, 1), 288, 0, NO_ERROR); // predicate bits 0101
            for (integer operation_index = 0; operation_index < 4; operation_index=operation_index+1) begin
                run(op(23, 1, 0, 16, 3, 4), 0, 0, NO_ERROR);
                run(op(operation_index % 2 == 0 ? 0 : 2, 0, 2,
                       operation_index < 2 ? 3 : 1,
                       operation_index < 2 ? 0 : 4, 4), 3, 0, NO_ERROR);
                expected = 0;
                for (integer i = 0; i < count; i=i+1) begin
                    pattern1 = (32'h7f0180ff >> (i*width)) & lowmask(width);
                    pattern2 = operation_index < 2 ? ((32'h02ff8001 >> (i*width)) & lowmask(width)) : 3;
                    if ((i % 2) != 0)
                        pattern1 = 32'hfffffff0;
                    else if ((operation_index % 2) == 0)
                        pattern1 = pattern1+pattern2;
                    else pattern1 = pattern1-pattern2;
                    expected = expected | ((pattern1 & lowmask(width)) << (i*width));
                end
                check(dut.vregs[4] == expected, "masked vv/vx arithmetic at all SEWs");
            end
            run(op(23, 1, 0, 31, 3, 6), 0, 0, NO_ERROR);
            run(op(24, 0, 2, 3, 0, 6), 0, 0, NO_ERROR);
            check((dut.vregs[6] & lowmask(count)) == ((32'hfffffffa) & lowmask(count)),
                "masked vmseq preserves inactive bits");
            run(op(23, 1, 0, 31, 3, 7), 0, 0, NO_ERROR);
            run(op(27, 0, 2, 3, 0, 7), 0, 0, NO_ERROR);
            mask_expected = (32'hfffffffa | (sew == 0 ? 1 : 0)) & lowmask(count);
            check((dut.vregs[7] & lowmask(count)) == mask_expected, "masked vmslt preserves inactive bits");
            run(op(23, 1, 0, 16, 3, 10), 0, 0, NO_ERROR);
            run(vmem(0, width, 10, 0), 256, 0, NO_ERROR);
            expected = 0;
            for (integer i = 0; i < count; i=i+1) begin
                pattern1 = (i % 2) == 0 ? (32'h7f0180ff >> (i*width)) : 32'hfffffff0;
                expected = expected | ((pattern1 & lowmask(width)) << (i*width));
            end
            check(dut.vregs[10] == expected, "masked loads all EEWs");
            tests = transactions;
            run(vmem(1, width, 2, 1), 512, 0, NO_ERROR);
            check(transactions-tests == count, "one store per element despite stalls");
            check({memory[515],memory[514],memory[513],memory[512]} == 32'h7f0180ff, "vector store width");
            // Explicit negative-versus-positive inputs are necessary at SEW32;
            // the packed mixed-byte patterns above have a positive sign there.
            run(op(23, 1, 0, 31, 3, 2), 0, 0, NO_ERROR);
            run(op(23, 1, 0, 1, 3, 3), 0, 0, NO_ERROR);
            run(op(27, 1, 2, 3, 0, 6), 0, 0, NO_ERROR);
            check((dut.vregs[6] & lowmask(count)) == lowmask(count),
                "signed minus-one less than positive-one at all SEWs");
            run(op(0, 1, 2, 3, 0, 4), 0, 0, NO_ERROR);
            check(dut.vregs[4] == 0, "all-ones plus one wraps per element");
            run(op(24, 1, 2, 2, 0, 6), 0, 0, NO_ERROR);
            check((dut.vregs[6] & lowmask(count)) == lowmask(count), "all elements equal mask at all SEWs");
        end

        // Masked loads/stores and arithmetic, vl=0, tail preservation and
        // prestart preservation. ta/ma may legally retain inactive elements.
        configure(4, 0);
        run(vmem(0, 8, 0, 1), 288, 0, NO_ERROR);
        run(op(23, 1, 0, 9, 3, 10), 0, 0, NO_ERROR);
        run(vmem(0, 8, 10, 0), 256, 0, NO_ERROR);
        check(dut.vregs[10] == 32'h090109ff, "masked load");
        run(op(0, 0, 10, 1, 3, 10), 0, 0, NO_ERROR);
        check(dut.vregs[10] == 32'h09020900, "masked in-place vadd.vi");
        tests = transactions;
        run(vmem(1, 8, 10, 0), 528, 0, NO_ERROR);
        check(transactions-tests == 2 && memory[528] == 0 && memory[529] == 0 && memory[530] == 2 &&
            memory[531] == 0, "masked store accesses");
        configure(2, 192);
        run(op(23, 1, 0, 3, 3, 10), 0, 0, NO_ERROR);
        check(dut.vregs[10] == 32'h09020303, "tail retained with ta");
        run(csr('h008, 1, 1, 2), 1, 0, NO_ERROR);
        run(op(23, 1, 0, 4, 3, 10), 0, 0, NO_ERROR);
        check(dut.vregs[10] == 32'h09020403 && dut.vstart == 0, "vstart/prestart behavior");
        configure(0, 0);
        tests = transactions;
        run(vmem(0, 32, 12, 1), 65535, 0, NO_ERROR);
        check(transactions == tests && dut.vregs[12] == 0 && dut.vregs[10] == 32'h09020403,
            "vl zero has no accesses or writes");

        // Integer/fractional LMUL, mixed EEW/SEW, and group validation.
        configure(8, 1); // e8,m2
        run(op(23, 1, 0, 7, 3, 12), 0, 0, NO_ERROR);
        check(dut.vregs[12] == 32'h07070707 && dut.vregs[13] == 32'h07070707, "LMUL2 group");
        run(op(23, 1, 0, 7, 3, 13), 0, 0, ILLEGAL_INST);
        configure(31, 2); // e8,m4
        run(op(23, 1, 0, 31, 3, 16), 0, 0, NO_ERROR);
        check(dut.vregs[16] == 32'hffffffff && dut.vregs[19] == 32'hffffffff, "LMUL4 group");
        configure(31, 3); // e8,m8, vsetivli AVL31
        run(op(23, 1, 0, 1, 3, 24), 0, 0, NO_ERROR);
        check(dut.vregs[24] == 32'h01010101 && dut.vregs[31] == 32'h00010101, "LMUL8 group and tail");
        configure(31, 7); // e8,mf2
        check(dut.vl == 2, "fractional LMUL half");
        configure(31, 6); // e8,mf4
        check(dut.vl == 1, "fractional LMUL quarter");
        configure(4, 16); // e32,m1; vle8 uses EMUL=mf4, one element
        run(vmem(0, 8, 11, 1), 256, 0, NO_ERROR);
        check(dut.vregs[11][7:0] == 255, "memory EEW independent of SEW");
        configure(4, 0); // e8,m1; vle32 EMUL4
        run(vmem(0, 32, 12, 1), 256, 0, NO_ERROR);
        check(dut.vregs[12] == 32'h7f0180ff && dut.vregs[13] == 0, "memory EMUL group");
        configure(4, 3); // e8,m8 -> vle32 requires EMUL32 reserved
        run(vmem(0, 32, 0, 1), 256, 0, ILLEGAL_INST);

        // Unsupported configurations set vill and vl=0; later vector ops trap.
        configure(1, 24); // e64
        check(dut.vtype == 32'h80000000 && dut.vl == 0, "unsupported SEW vill");
        run(op(0, 1, 2, 3, 0, 4), 0, 0, ILLEGAL_INST);
        configure(1, 256); // reserved upper vtype bits
        check(dut.vtype == 32'h80000000, "reserved vtype bits");
        configure(1, 5); // mf8 unsupported for ELEN32
        check(dut.vtype[31], "unsupported fractional LMUL");
        configure(1, 0);
        run(op(23, 1, 1, 1, 3, 2), 0, 0, ILLEGAL_INST); // vmv vs2 must zero
        run(op(25, 0, 2, 3, 2, 4), 0, 0, ILLEGAL_INST); // mask logical vm=0
        run(vmem(0, 8, 0, 0), 256, 0, ILLEGAL_INST); // masked destination v0

        // CSR aliases, immediate CSR forms, read/modify/write and vstart fault.
        run(csr('h00f, 5, 7, 2), 0, 0, NO_ERROR);
        run(csr('h009, 2, 0, 2), 0, 0, NO_ERROR);
        check(returned == 1, "vcsr saturation alias");
        run(csr('h00a, 2, 0, 2), 0, 0, NO_ERROR);
        check(returned == 3, "vcsr rounding alias");
        run(csr('h00f, 7, 3, 2), 0, 0, NO_ERROR);
        run(csr('h00f, 6, 1, 2), 0, 0, NO_ERROR);
        run(csr('h00f, 2, 0, 2), 0, 0, NO_ERROR);
        check(returned == 5, "CSR immediate clear/set");
        run(csr('h00f, 3, 1, 2), 5, 0, NO_ERROR);
        run(csr('h00f, 2, 1, 2), 2, 0, NO_ERROR);
        run(csr('h00f, 2, 0, 2), 0, 0, NO_ERROR);
        check(returned == 2, "CSR register clear/set");
        configure(2, 8);
        run(vmem(0, 16, 2, 1), 257, 0, LOAD_ADDR_MISALIGN);
        check(dut.vstart == 0, "misaligned load vstart");
        run(vmem(1, 16, 2, 1), 257, 0, STORE_ADDR_MISALIGN);
        configure(2, 0);
        run(vmem(0, 8, 2, 1), 65535, 0, LOAD_ACCESS_FAULT);
        check(dut.vstart == 1, "partial vector fault element index");
        configure(2, 0);
        tests = transactions;
        run(vmem(1, 8, 2, 1), 65535, 0, STORE_ACCESS_FAULT);
        check(dut.vstart == 1 && transactions-tests == 1, "partial vector store fault element index");
        configure(4, 0);
        run(vmem(0, 8, 0, 1), 288, 0, NO_ERROR);
        tests = transactions;
        run(vmem(0, 8, 2, 0), 65533, 0, NO_ERROR);
        check(transactions-tests == 2 && dut.vstart == 0, "masked invalid addresses cause no exception");
        // Address generation is modulo XLEN, independent of the RAM mapping.
        // The invalid high first element is masked; the second wraps to zero.
        for (integer sew = 0; sew < 3; sew=sew+1) begin
            width = 8 << sew;
            configure(2, (sew << 3) | (sew == 2 ? 1 : 0));
            run(vmem(0, 8, 0, 1), 304, 0, NO_ERROR);
            run(op(23, 1, 0, 9, 3, 2), 0, 0, NO_ERROR);
            memory[0] = 8'h5a;
            memory[1] = 8'ha5;
            memory[2] = 8'hc3;
            memory[3] = 8'h3c;
            tests     = transactions;
            run(vmem(0, width, 2, 0), 0-DATA'(width/8), 0, NO_ERROR);
            check(transactions-tests == 1, "wrapped masked load issues exactly once");
            case (width)
                8: check(dut.vregs[2][15:0] == 16'h5a09, "byte address wrap and inactive preservation");
                16: check(dut.vregs[2] == 32'ha55a0009, "halfword address wrap and inactive preservation");
                default: check(dut.vregs[2] == 9 && dut.vregs[3] == 32'h3cc3a55a,
                    "word address wrap and inactive preservation");
            endcase
            run(op(23, 1, 0, 7, 3, 2), 0, 0, NO_ERROR);
            tests = transactions;
            run(vmem(1, width, 2, 0), 0-DATA'(width/8), 0, NO_ERROR);
            check(transactions-tests == 1 && memory[0] == 7, "wrapped masked store issues exactly once");
            check(memory[1] == (width >= 16 ? 0 : 8'ha5) &&
                  memory[2] == (width == 32 ? 0 : 8'hc3) &&
                  memory[3] == (width == 32 ? 0 : 8'h3c), "wrapped store byte enables");
        end
        $display("PASS vector_test: all 19 RVV instructions, CSR forms, widths, masking, grouping, memory stalls, exceptions (%0d checks)", checks);
        $finish;
    end
endmodule
