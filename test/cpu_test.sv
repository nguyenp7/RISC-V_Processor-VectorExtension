/////////////////////////////////////////////////////////////////////////
//                                                                     //
//   Modulename :  cpu_test.sv                                         //
//                                                                     //
//  Description :  Testbench module for the VeriSimpleV processor.     //
//                                                                     //
/////////////////////////////////////////////////////////////////////////

`include "sys_defs.svh"

// these link to the pipe_print.c file in this directory, and are used below to print
// detailed output to the pipeline_output_file, initialized by open_pipeline_output_file()
import "DPI-C" function string decode_inst(int inst);
import "DPI-C" function void open_pipeline_output_file(string file_name);
import "DPI-C" function void print_header();
import "DPI-C" function void print_cycles(int clock_count);
import "DPI-C" function void print_stage(int inst, int npc, int valid_inst);
import "DPI-C" function void print_reg(int wb_data, int wb_idx, int wb_en);
import "DPI-C" function void print_membus(int proc2mem_command, int proc2mem_addr,
                                          int proc2mem_data_hi, int proc2mem_data_lo);
import "DPI-C" function void close_pipeline_output_file();


module testbench;
    // string inputs for loading memory and output files
    // run like: cd build && ./simv +MEMORY=../programs/mem/<my_program>.mem +OUTPUT=../output/<my_program>
    // this testbench will generate 4 output files based on the output
    // named OUTPUT.{out cpi, wb, ppln} for the memory, cpi, writeback, and pipeline outputs.
    string program_memory_file, output_name;
    string out_outfile, cpi_outfile, writeback_outfile, pipeline_outfile;
    int out_fileno, cpi_fileno, wb_fileno; // verilog uses integer file handles with $fopen and $fclose

    // variables used in the testbench
    logic        clock;
    logic        reset;
    logic [31:0] clock_count; // also used for terminating infinite loops
    logic [31:0] instr_count;

    MEM_COMMAND proc2mem_command;
    ADDR        proc2mem_addr;
    MEM_BLOCK   proc2mem_data;
    MEM_TAG     mem2proc_transaction_tag;
    MEM_BLOCK   mem2proc_data;
    MEM_TAG     mem2proc_data_tag;
`ifndef CACHE_MODE
    MEM_SIZE    proc2mem_size;
`endif

    COMMIT_PACKET [`N-1:0] committed_insts;
    EXCEPTION_CODE error_status = NO_ERROR;

    ADDR  if_NPC_dbg;
    DATA  if_inst_dbg;
    logic if_valid_dbg;
    ADDR  if_id_NPC_dbg;
    DATA  if_id_inst_dbg;
    logic if_id_valid_dbg;
    ADDR  id_ex_NPC_dbg;
    DATA  id_ex_inst_dbg;
    logic id_ex_valid_dbg;
    ADDR  ex_mem_NPC_dbg;
    DATA  ex_mem_inst_dbg;
    logic ex_mem_valid_dbg;
    ADDR  mem_wb_NPC_dbg;
    DATA  mem_wb_inst_dbg;
    logic mem_wb_valid_dbg;


    // Instantiate the Pipeline
    cpu verisimpleV (
        // Inputs
        .clock (clock),
        .reset (reset),
        .mem2proc_transaction_tag (mem2proc_transaction_tag),
        .mem2proc_data            (mem2proc_data),
        .mem2proc_data_tag        (mem2proc_data_tag),

        // Outputs
        .proc2mem_command (proc2mem_command),
        .proc2mem_addr    (proc2mem_addr),
        .proc2mem_data    (proc2mem_data),
        .proc2mem_size    (proc2mem_size),

        .committed_insts (committed_insts),

        .if_NPC_dbg       (if_NPC_dbg),
        .if_inst_dbg      (if_inst_dbg),
        .if_valid_dbg     (if_valid_dbg),
        .if_id_NPC_dbg    (if_id_NPC_dbg),
        .if_id_inst_dbg   (if_id_inst_dbg),
        .if_id_valid_dbg  (if_id_valid_dbg),
        .id_ex_NPC_dbg    (id_ex_NPC_dbg),
        .id_ex_inst_dbg   (id_ex_inst_dbg),
        .id_ex_valid_dbg  (id_ex_valid_dbg),
        .ex_mem_NPC_dbg   (ex_mem_NPC_dbg),
        .ex_mem_inst_dbg  (ex_mem_inst_dbg),
        .ex_mem_valid_dbg (ex_mem_valid_dbg),
        .mem_wb_NPC_dbg   (mem_wb_NPC_dbg),
        .mem_wb_inst_dbg  (mem_wb_inst_dbg),
        .mem_wb_valid_dbg (mem_wb_valid_dbg)
    );


    // Instantiate the Data Memory
    mem memory (
        // Inputs
        .clock            (clock),
        .proc2mem_command (proc2mem_command),
        .proc2mem_addr    (proc2mem_addr),
        .proc2mem_data    (proc2mem_data),
`ifndef CACHE_MODE
        .proc2mem_size    (proc2mem_size),
`endif

        // Outputs
        .mem2proc_transaction_tag (mem2proc_transaction_tag),
        .mem2proc_data            (mem2proc_data),
        .mem2proc_data_tag        (mem2proc_data_tag)
    );


    // Generate System Clock
    always begin
        #(`CLOCK_PERIOD/2.0);
        clock = ~clock;
    end


    initial begin
        $display("\n---- Starting CPU Testbench ----\n");

        // set paramterized strings, see comment at start of module
        if ($value$plusargs("MEMORY=%s", program_memory_file)) begin
            $display("Using memory file  : %s", program_memory_file);
        end else begin
            $display("Did not receive '+MEMORY=' argument. Exiting.\n");
            $finish;
        end
        if ($value$plusargs("OUTPUT=%s", output_name)) begin
            $display("Using output files : %s.{out, cpi, wb, ppln}", output_name);
            out_outfile       = {output_name,".out"}; // this is how you concatenate strings in verilog
            cpi_outfile       = {output_name,".cpi"};
            writeback_outfile = {output_name,".wb"};
            pipeline_outfile  = {output_name,".ppln"};
        end else begin
            $display("\nDid not receive '+OUTPUT=' argument. Exiting.\n");
            $finish;
        end

        clock = 1'b0;
        reset = 1'b0;

        $display("\n  %16t : Asserting Reset", $realtime);
        reset = 1'b1;

        @(posedge clock);
        @(posedge clock);

        $display("  %16t : Loading Unified Memory", $realtime);
        // load the compiled program's hex data into the memory module
        $readmemh(program_memory_file, memory.unified_memory);

        @(posedge clock);
        @(posedge clock);
        #1; // This reset is at an odd time to avoid the pos & neg clock edges
        $display("  %16t : Deasserting Reset", $realtime);
        reset = 1'b0;

        wb_fileno = $fopen(writeback_outfile);
        $fdisplay(wb_fileno, "Register writeback output (hexadecimal)");

        // Open pipeline output file AFTER throwing the reset otherwise the reset state is displayed
        open_pipeline_output_file(pipeline_outfile);
        print_header();

        $display("  %16t : Running Processor", $realtime);
    end


    always @(negedge clock) begin
        if (reset) begin
            // Count the number of cycles and number of instructions committed
            clock_count = 0;
            instr_count = 0;
        end else begin
            #2; // wait a short time to avoid a clock edge

            clock_count = clock_count + 1;

            if (clock_count % 10000 == 0) begin
                $display("  %16t : %d cycles", $realtime, clock_count);
            end

            // print the pipeline debug outputs via c code to the pipeline output file
            print_cycles(clock_count - 1);
            print_stage(if_inst_dbg,     if_NPC_dbg,     {31'b0,if_valid_dbg});
            print_stage(if_id_inst_dbg,  if_id_NPC_dbg,  {31'b0,if_id_valid_dbg});
            print_stage(id_ex_inst_dbg,  id_ex_NPC_dbg,  {31'b0,id_ex_valid_dbg});
            print_stage(ex_mem_inst_dbg, ex_mem_NPC_dbg, {31'b0,ex_mem_valid_dbg});
            print_stage(mem_wb_inst_dbg, mem_wb_NPC_dbg, {31'b0,mem_wb_valid_dbg});
            print_reg(committed_insts[0].data, {27'b0,committed_insts[0].reg_idx},
                      {31'b0,committed_insts[0].valid});
            print_membus({30'b0,proc2mem_command}, proc2mem_addr[31:0],
                         proc2mem_data[63:32], proc2mem_data[31:0]);

            output_reg_writeback_and_maybe_halt();

            // stop the processor
            if (error_status != NO_ERROR || clock_count > 50000000) begin

                $display("  %16t : Processor Finished", $realtime);

                // close the writeback and pipeline output files
                close_pipeline_output_file();
                $fclose(wb_fileno);

                // display the final memory and status
                show_final_mem_and_status(error_status);
                // output the final CPI
                output_cpi_file();

                $display("\n---- Finished CPU Testbench ----\n");

                #100 $finish;
            end
        end // if(reset)
    end


    // Task to output register writeback data and potentially halt the processor.
    task output_reg_writeback_and_maybe_halt;
        ADDR pc;
        DATA inst;
        MEM_BLOCK block;
        for (int n = 0; n < `N; ++n) begin
            if (committed_insts[n].valid) begin
                // update the count for every committed instruction
                instr_count = instr_count + 1;

                pc = committed_insts[n].NPC - 4;
                block = pc < `MEM_SIZE_IN_BYTES ?
                    memory.unified_memory[pc[$clog2(`MEM_64BIT_LINES)+2:3]] : MEM_BLOCK'(0);
                inst = block.word_level[pc[2]];
                // print the committed instructions to the writeback output file
                if (committed_insts[n].reg_idx == `ZERO_REG) begin
                    $fdisplay(wb_fileno, "PC %4x:%-8s| ---", pc, decode_inst(inst));
                end else begin
                    $fdisplay(wb_fileno, "PC %4x:%-8s| r%02d=%-8x",
                              pc,
                              decode_inst(inst),
                              committed_insts[n].reg_idx,
                              committed_insts[n].data);
                end

                // exit if we have an illegal instruction or a halt
                if (committed_insts[n].exception != NO_ERROR) begin
                    error_status = committed_insts[n].exception;
                    break;
                end else if (committed_insts[n].illegal) begin
                    error_status = ILLEGAL_INST;
                    break;
                end else if(committed_insts[n].halt) begin
                    error_status = HALTED_ON_WFI;
                    break;
                end
            end // if valid
        end
    endtask // task output_reg_writeback_and_maybe_halt


    // Task to output the final CPI and # of elapsed clock edges
    task output_cpi_file;
        real cpi;
        begin
            cpi = $itor(clock_count) / instr_count; // must convert int to real
            cpi_fileno = $fopen(cpi_outfile);
            $fdisplay(cpi_fileno, "@@@  %0d cycles / %0d instrs = %f CPI",
                      clock_count, instr_count, cpi);
            $fdisplay(cpi_fileno, "@@@  %4.2f ns total time to execute",
                      clock_count * `CLOCK_PERIOD);
            $fclose(cpi_fileno);
        end
    endtask // task output_cpi_file


    // Show contents of Unified Memory in both hex and decimal
    // Also output the final processor status
    task show_final_mem_and_status;
        input EXCEPTION_CODE final_status;
        int showing_data;
        begin
            out_fileno = $fopen(out_outfile);
            $fdisplay(out_fileno, "\nFinal memory state and exit status:\n");
            $fdisplay(out_fileno, "@@@ Unified Memory contents hex on left, decimal on right: ");
            $fdisplay(out_fileno, "@@@");
            showing_data = 0;
            for (int k = 0; k <= `MEM_64BIT_LINES - 1; k = k+1) begin
                if (memory.unified_memory[k] != 0) begin
                    $fdisplay(out_fileno, "@@@ mem[%5d] = %x : %0d", k*8, memory.unified_memory[k],
                                                             memory.unified_memory[k]);
                    showing_data = 1;
                end else if (showing_data != 0) begin
                    $fdisplay(out_fileno, "@@@");
                    showing_data = 0;
                end
            end
            $fdisplay(out_fileno, "@@@");

            case (final_status)
                LOAD_ACCESS_FAULT: $fdisplay(out_fileno, "@@@ System halted on memory error");
                HALTED_ON_WFI:     $fdisplay(out_fileno, "@@@ System halted on WFI instruction");
                ILLEGAL_INST:      $fdisplay(out_fileno, "@@@ System halted on illegal instruction");
                default:           $fdisplay(out_fileno, "@@@ System halted on unknown error code %x", final_status);
            endcase
            $fdisplay(out_fileno, "@@@");
            $fclose(out_fileno);
        end
    endtask // task show_final_mem_and_status


endmodule // module testbench
