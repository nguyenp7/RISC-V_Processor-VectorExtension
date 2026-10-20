##########################
# ---- Introduction ---- #
##########################

# Welcome to the Project 2 VeriSimpleV Processor makefile!
# this file will build and run a fully synthesizable RISC-V verilog processor
# and is an extended version of the EECS 472 standard makefile

# NOTE: this file should need no changes for project 2
# but it will be reused for the final project, where you will likely add your own new files and functionality

# reference table of all make targets:

# make  <- runs the default target, set explicitly below as 'make no_hazard.out'
.DEFAULT_GOAL = no_hazard.out
# ^ this overrides using the first listed target as the default

# CAEN self-checking simulation. The portable Verilator flow is optional.
PYTHON ?= python3
verify: module_tests vector_programs
.PHONY: verify

verify_verilator:
	$(PYTHON) test/run_verification.py --programs
.PHONY: verify_verilator

# ---- Module and Vector Verification ---- #
# make vector_test       <- VCS test of all implemented vector instructions
# make cache_tests       <- VCS I-cache, D-cache, and backing-memory tests
# make module_tests      <- all self-contained module/CPU testbenches
# make vector_programs   <- self-checking vector assembly programs on VCS
# make verify            <- module_tests and vector_programs together
# make verify_verilator  <- optional portable Verilator regression

# ---- Program Execution ---- #
# these are your main commands for running programs and generating output
# make <my_program>.out      <- run a program on simv and output .out, .cpi, .wb, and .ppln files
# make <my_program>.syn.out  <- run a program on syn.simv and do the same
# make simulate_all          <- run every program on simv at once (in parallel with -j)
# make simulate_all.syn      <- run every program on syn.simv at once (in parallel with -j)

# ---- Executable Compilation ---- #
# make build/simv      <- compiles simv from the TESTBENCH and SOURCES
# make build/syn.simv  <- compiles syn.simv from TESTBENCH and SYNTH_FILES
# make synth/*.vg      <- synthesize modules in SOURCES for use in syn.simv
# make slack           <- grep the slack status of any synthesized modules

# ---- Program Memory Compilation ---- #
# NOTE: programs to run are in the programs/ directory
# make programs/mem/<my_program>.mem  <- compiles a program to a RISC-V memory file for running on the processor
# make compile_all                    <- compile every program at once (in parallel with -j)

# ---- Dump Files ---- #
# make <my_program>.dump  <- disassembles <my_program>.mem into .dump_x and .dump_abi RISC-V assembly files
# make *.debug.dump       <- for a .c program, creates dump files after compiling with a debug flag
# make programs/<my_program>.dump_x    <- numeric dump files use x0-x31 as register names
# make programs/<my_program>.dump_abi  <- abi dump files use the abi register names (sp, a0, etc.)
# make dump_all  <- create all dump files at once (in parallel with -j)

# ---- Verdi ---- #
# make <my_program>.verdi     <- run a program in verdi via simv
# make <my_program>.syn.verdi <- run a program in verdi via syn.simv

# ---- Visual Debugger ---- #
# make <my_program>.vis  <- run a program on the project 2 vtuber visual debugger!
# make build/vis.simv    <- compile the vtuber executable from VTUBER and SOURCES

# ---- Cleanup ---- #
# make clean            <- remove per-run files and compiled executable files
# make nuke             <- remove all files created from make rules
# make clean_run_files  <- remove per-run output files
# make clean_exe        <- remove compiled executable files
# make clean_synth      <- remove generated synthesis files
# make clean_output     <- remove the entire output/ directory
# make clean_programs   <- remove program memory and dump files

# Credits:
# VeriSimpleV was adapted by Jielun Tan for RISC-V from the original 472 VeriSimple Alpha language processor
# however I cannot find the original authors or the major editors of the project :/
# so to everyone I can't credit: thank you!
# the current layout of the Makefile was made by Ian Wrzesinski in 2023
# VeriSimpleV has also been edited by at least:
# Nevil Pooniwala, Xueyang Liu, Cassie Jones, James Connolly

######################################################
# ---- Compilation Commands and Other Variables ---- #
######################################################

# these are various build flags for different parts of the makefile, VCS and LIB should be
# familiar, but there are new variables for supporting the compilation of assembly and C
# source programs into riscv machine code files to be loaded into the processor's memory

# don't be afraid to change these, but be diligent about testing changes and using git commits
# there should be no need to change anything for project 2

# this is a global clock period variable used in the tcl script and referenced in testbenches
# Clock period is in picoseconds.
export CLOCK_PERIOD = 5000

# the Verilog Compiler command and arguments
VCS_MDIR ?= build/csrc
VCS = module load vcs/2023.12-SP2-1 && \
	  vcs -sverilog -xprop=tmerge +vc -Mupdate -Mdir=$(VCS_MDIR) -line -full64 -kdb -lca -nc \
      -debug_access+all+reverse $(VCS_BAD_WARNINGS) +define+CLOCK_PERIOD=$(CLOCK_PERIOD) +incdir+verilog/
# a SYNTH define is added when compiling for synthesis that can be used in testbenches

# remove certain warnings that generate MB of text but can be safely ignored
VCS_BAD_WARNINGS = +warn=noTFIPC +warn=noDEBUG_DEP +warn=noENUMASSIGN +warn=noLCA_FEATURES_ENABLED

# a reference library of standard structural cells that we link against when synthesizing
LIB = $(wildcard /usr/caen/misc/class/eecs470/asap7sc7p5t_28/Verilog/*_RVT_TT_*.v)

# the EECS 472 synthesis script
TCL_SCRIPT = 472synth.tcl

# Set the shell's pipefail option: causes return values through pipes to match the last non-zero value
# (useful for, i.e. piping to `tee`)
SHELL := /bin/bash
.SHELLFLAGS := -o pipefail -c

# The following are new in project 2:

# you might need to update these build flags for the final project, but make sure you know what they do:
# https://gcc.gnu.org/onlinedocs/gcc/RISC-V-Options.html
CFLAGS     = -mno-relax -march=rv32im -mabi=ilp32 -nostartfiles -std=gnu11 -mstrict-align -mno-div
# adjust the optimization if you want programs to run faster; this may obfuscate/change their instructions
OFLAGS     = -O0
ASFLAGS    = -mno-relax -march=rv32im -mabi=ilp32 -nostartfiles -Wno-main -mstrict-align
OBJFLAGS   = -SD -M no-aliases
OBJCFLAGS  = --set-section-flags .bss=contents,alloc,readonly
OBJDFLAGS  = -SD -M numeric,no-aliases
DEBUG_FLAG = -g

# this is our RISC-V compiler toolchain
# NOTE: you can use a local riscv install to compile programs by setting CAEN to 0
CAEN = 1
ifeq (1, $(CAEN))
    GCC     = riscv gcc
    OBJCOPY = riscv objcopy
    OBJDUMP = riscv objdump
    AS      = riscv as
    ELF2HEX = riscv elf2hex
else
    GCC     = riscv64-unknown-elf-gcc
    OBJCOPY = riscv64-unknown-elf-objcopy
    OBJDUMP = riscv64-unknown-elf-objdump
    AS      = riscv64-unknown-elf-as
    ELF2HEX = elf2hex
endif

####################################
# ---- Executable Compilation ---- #
####################################

# NOTE: the executables are not the only things you need to compile
# you must also create a build/*.mem file for each program you run
# which will be loaded into test/mem.sv by the testbench on startup
# To run a program on simv or syn.simv, see the program execution section
# This is done automatically with 'make <my_program>.out'

HEADERS = verilog/sys_defs.svh \
          verilog/ISA.svh

TESTBENCH = test/cpu_test.sv \
            test/decode_inst.c \
            test/pipeline_print.c \
            test/mem.sv

# This could simplify to $(wildcard verilog/*.sv) - but the manual way is more explicit
SOURCES = verilog/cpu.sv \
          verilog/regfile.sv \
          verilog/stage_if.sv \
          verilog/stage_id.sv \
          verilog/stage_ex.sv \
          verilog/stage_mem.sv \
          verilog/stage_wb.sv \
          verilog/icache.sv \
          verilog/dcache.sv \
          verilog/vector_unit.sv

SYNTH_FILES = synth/cpu.vg

# the normal simulation executable will run your testbench on the original modules
build/simv: $(TESTBENCH) $(SOURCES) $(HEADERS) | build
	@$(call PRINT_COLOR, 5, compiling the simulation executable $@)
	$(VCS) $(filter-out $(HEADERS),$^) -o $@
	@$(call PRINT_COLOR, 6, finished compiling $@)

# a make pattern rule to generate the .vg synthesis files
# pattern rules use the % as a wildcard to match multiple possible targets
synth/%.vg: $(SOURCES) $(TCL_SCRIPT) $(HEADERS) | synth
	@$(call PRINT_COLOR, 5, synthesizing the $* module)
	@$(call PRINT_COLOR, 3, this might take a while...)
	cd synth && \
	MODULE=$* SOURCES="$(SOURCES)" \
	dc_shell-t -f ../$(TCL_SCRIPT) | tee $*-synth.out
	@$(call PRINT_COLOR, 6, finished synthesizing $@)

# the synthesis executable runs your testbench on the synthesized versions of your modules
build/syn.simv: $(TESTBENCH) $(SYNTH_FILES) $(HEADERS) | build
	@$(call PRINT_COLOR, 5, compiling the synthesis executable $@)
	$(VCS) +define+SYNTH $(filter-out $(HEADERS),$^) $(LIB) -o $@
	@$(call PRINT_COLOR, 6, finished compiling $@)

# a phony target to view the slack in the *.rep synthesis report file
slack:
	grep --color=auto "slack" synth/*.rep
.PHONY: slack

##########################################
# ---- CAEN Module and Vector Tests ---- #
##########################################

# Each executable has a separate VCS build directory so 'make -j' is safe.
# These benches use SystemVerilog only: no DPI C code or native C++ compiler.
MODULE_TEST_NAMES = vector_test vector_decode_test dcache_test icache_test mem_test \
                    cpu_dual_test cpu_exception_test cpu_program_test
MODULE_UNIT_TESTS = vector_test vector_decode_test dcache_test icache_test mem_test cpu_exception_test

MODULE_SOURCES_vector_test        = verilog/stage_id.sv verilog/vector_unit.sv vectorTests/vector_test.sv
MODULE_SOURCES_vector_decode_test = verilog/stage_id.sv vectorTests/vector_decode_test.sv
MODULE_SOURCES_dcache_test        = verilog/dcache.sv test/dcache_test.sv
MODULE_SOURCES_icache_test        = verilog/icache.sv test/icache_test.sv
MODULE_SOURCES_mem_test           = test/mem.sv test/mem_test.sv
MODULE_SOURCES_cpu_dual_test      = $(SOURCES) test/cpu_dual_test.sv
MODULE_SOURCES_cpu_exception_test = $(SOURCES) test/mem.sv test/cpu_exception_test.sv
MODULE_SOURCES_cpu_program_test   = $(SOURCES) test/mem.sv test/cpu_program_test.sv

MODULE_DEFINES_mem_test           = +define+MEM_LATENCY_IN_CYCLES=32
MODULE_DEFINES_cpu_exception_test = +define+MEM_LATENCY_IN_CYCLES=4
MODULE_DEFINES_cpu_program_test   = +define+MEM_LATENCY_IN_CYCLES=3

define MODULE_TEST_RULE
build/module_tests/$(1).simv: VCS_MDIR = build/module_tests/csrc_$(1)
build/module_tests/$(1).simv: $$(MODULE_SOURCES_$(1)) $$(HEADERS) | build/module_tests
	@$$(call PRINT_COLOR, 5, compiling the $(1) module test)
	$$(VCS) $$(MODULE_DEFINES_$(1)) -top $(1) $$(filter-out $$(HEADERS),$$^) -o $$@
endef
$(foreach name,$(MODULE_TEST_NAMES),$(eval $(call MODULE_TEST_RULE,$(name))))

$(MODULE_UNIT_TESTS): %: build/module_tests/%.simv | output/module_tests
	@$(call PRINT_COLOR, 5, running the $@ module test)
	./$< | tee output/module_tests/$@.log

cpu_dual_test: build/module_tests/cpu_dual_test.simv | output/module_tests
	./$< +LATENCY=0 | tee output/module_tests/cpu_dual_test_latency0.log
	./$< +LATENCY=3 | tee output/module_tests/cpu_dual_test_latency3.log

vector_tests: vector_test vector_decode_test
cache_tests: dcache_test icache_test mem_test
module_tests: vector_tests cache_tests cpu_dual_test cpu_exception_test
.PHONY: $(MODULE_UNIT_TESTS) cpu_dual_test vector_tests cache_tests module_tests

# Prepare ISA-encoded memory images and independent retirement/memory goldens.
# Python is used only to prepare data; CAEN VCS runs the processor simulation.
# Select programs/ to run the original copies instead of vectorTests/.
VECTOR_PROGRAM_DIR ?= vectorTests
VECTOR_ASSEMBLY = $(wildcard $(VECTOR_PROGRAM_DIR)/rvv_*.s)
VECTOR_PROGRAM_NAMES = $(notdir $(VECTOR_ASSEMBLY:.s=))
VECTOR_PREPARE = vector_fixtures

$(VECTOR_PREPARE): $(VECTOR_ASSEMBLY) vectorTests/vector_program_regression.py \
                  test/scalar_regression.py $(HEADERS) | build/vector_programs
	$(PYTHON) vectorTests/vector_program_regression.py --prepare-only --program-dir $(VECTOR_PROGRAM_DIR)

VECTOR_PROGRAM_LOGS = $(addprefix output/vector_programs/,$(addsuffix .log,$(VECTOR_PROGRAM_NAMES)))

$(VECTOR_PROGRAM_LOGS): output/vector_programs/%.log: $(VECTOR_PREPARE) build/module_tests/cpu_program_test.simv | output/vector_programs
	@$(call PRINT_COLOR, 5, checking vector program $*)
	./build/module_tests/cpu_program_test.simv \
		+MEMORY=build/vector_programs/$*.mem \
		+TRACE=build/vector_programs/$*.trace \
		+FINAL=build/vector_programs/$*.final.mem | tee $@

vector_programs: $(VECTOR_PREPARE) $(VECTOR_PROGRAM_LOGS)
	@$(call PRINT_COLOR, 6, checked $(words $(VECTOR_PROGRAM_NAMES)) vector programs)
.PHONY: vector_programs vector_fixtures $(VECTOR_PROGRAM_LOGS)

########################################
# ---- Program Memory Compilation ---- #
########################################

# this section will compile programs into .mem files to be loaded into memory
# you start with either an assembly or C program in the programs/ directory
# those compile into a .elf link file via the riscv assembler or compiler
# then that link file is converted to a .mem hex file

# find the test program files and separate them based on suffix of .s or .c
# filter out files that aren't themselves programs
NON_PROGRAMS = $(CRT)
ASSEMBLY = $(filter-out $(NON_PROGRAMS),$(wildcard programs/*.s))
C_CODE   = $(filter-out $(NON_PROGRAMS),$(wildcard programs/*.c))

# concatenate ASSEMBLY and C_CODE to list every program
PROGRAMS = $(ASSEMBLY:%.s=%) $(C_CODE:%.c=%)

# NOTE: this is Make's pattern substitution syntax
# see: https://www.gnu.org/software/make/manual/html_node/Text-Functions.html#Text-Functions
# this reads as: $(var:pattern=replacement)
# a percent sign '%' in pattern is as a wildcard, and can be reused in the replacement
# if you don't include the percent it automatically attempts to replace just the suffix of the input

# C and assembly compilation files. These link and setup the runtime for the programs
CRT        = programs/crt.s
LINKERS    = programs/linker.lds
ASLINKERS  = programs/aslinker.lds

# make elf files from assembly code
programs/mem/rvv_%.elf: ASFLAGS := $(filter-out -march=%,$(ASFLAGS)) -march=rv32imv

programs/mem/%.elf: programs/%.s $(ASLINKERS) | programs/mem
	@$(call PRINT_COLOR, 5, compiling assembly file $<)
	$(GCC) $(ASFLAGS) $< -T $(ASLINKERS) -o $@

# make elf files from C source code
programs/mem/%.elf: programs/%.c $(CRT) $(LINKERS) | programs/mem
	@$(call PRINT_COLOR, 5, compiling C code file $<)
	$(GCC) $(CFLAGS) $(OFLAGS) $(CRT) $< -T $(LINKERS) -o $@

# C programs can also be compiled in debug mode, this is solely meant for use in the .dump files below
programs/mem/%.debug.elf: programs/%.c $(CRT) $(LINKERS) | programs/mem
	@$(call PRINT_COLOR, 5, compiling debug C code file $<)
	$(GCC) $(CFLAGS) $(OFLAGS) $(CRT) $< -T $(LINKERS) -o $@
	$(GCC) $(DEBUG_FLAG) $(CFLAGS) $(OFLAGS) $(CRT) $< -T $(LINKERS) -o $@

# declare the .elf files as intermediate files.
# Make will automatically rm intermediate files after they're used in a recipe
# and it won't remake them until their sources are updated or they're needed again
.INTERMEDIATE: programs/mem/%.elf

# turn any elf file into a hex memory file ready for the testbench
programs/mem/%.mem: programs/mem/%.elf
	$(ELF2HEX) 8 8192 $< > $@
	@$(call PRINT_COLOR, 6, created memory file $@)
	@$(call PRINT_COLOR, 3, NOTE: to see RISC-V assembly run: '"make $*.dump"')
	@$(call PRINT_COLOR, 3, for \*.c sources also try: '"make $*.debug.dump"')

# compile all programs in one command (use 'make -j' to run multithreaded)
compile_all: $(PROGRAMS:programs/%=programs/mem/%.mem)
.PHONY: compile_all

########################
# ---- Dump Files ---- #
########################

# when debugging a program, the dump files will show you the disassembled RISC-V
# assembly code that your processor is actually running

# this creates the <my_program>.debug.elf targets, which can be used in: 'make <my_program>.debug.dump_*'
# these are useful for the C sources because the debug flag makes the assembly more understandable
# because it includes some of the original C operations and function/variable names

DUMP_PROGRAMS = $(ASSEMBLY:.s=) $(C_CODE:.c=.debug)

# 'make <my_program>.dump' will create both files at once!
./%.dump: programs/%.dump_x programs/%.dump_abi ;
.PHONY: ./%.dump
# Tell Make to treat the .dump_* files as "precious" and not to rm them as intermediaries to %.dump
.PRECIOUS: %.dump_x %.dump_abi

# use the numberic x0-x31 register names
programs/%.dump_x: programs/mem/%.elf
	@$(call PRINT_COLOR, 5, disassembling $<)
	$(OBJDUMP) $(OBJDFLAGS) $< > $@
	@$(call PRINT_COLOR, 6, created numeric dump file $@)

# use the Application Binary Interface register names (sp, a0, etc.)
programs/%.dump_abi: programs/mem/%.elf
	@$(call PRINT_COLOR, 5, disassembling $<)
	$(OBJDUMP) $(OBJFLAGS) $< > $@
	@$(call PRINT_COLOR, 6, created abi dump file $@)

# create all dump files in one command (use 'make -j' to run multithreaded)
dump_all: $(DUMP_PROGRAMS:=.dump_x) $(DUMP_PROGRAMS:=.dump_abi)
.PHONY: dump_all

###############################
# ---- Program Execution ---- #
###############################

# run one of the executables (simv/syn.simv) using the chosen program
# e.g. 'make sampler.out' does the following from a clean directory:
#   1. compiles simv
#   2. compiles programs/sampler.s into its .elf and then .mem files (in programs/)
#   3. runs cd build && ./simv +MEMORY=../programs/sampler.mem +OUTPUT=../output/sampler > ../output/sampler.out
#   4. which creates the sampler.out, sampler.cpi, sampler.wb, and sampler.ppln files in output/
# the same can be done for synthesis by doing 'make sampler.syn.out'
# which will also create .syn.cpi, .syn.wb, and .syn.ppln files in output/

# run a program and produce output files
output/%.out: programs/mem/%.mem build/simv | output
	@$(call PRINT_COLOR, 5, running simv on $<)
	cd build && ./simv +MEMORY=../$< +OUTPUT=../output/$*
	@$(call PRINT_COLOR, 6, finished running simv on $<)
	@$(call PRINT_COLOR, 2, output is in output/$*.{out finalmem cpi wb ppln})

# run synthesis with: 'make <my_program>.syn.out'
# this does the same as simv, but adds .syn to the output files and compiles syn.simv instead
output/%.syn.out: programs/mem/%.mem build/syn.simv | output
	@$(call PRINT_COLOR, 5, running syn.simv on $<)
	@$(call PRINT_COLOR, 3, this might take a while...)
	cd build && ./syn.simv +MEMORY=../$< +OUTPUT=../output/$*.syn
	@$(call PRINT_COLOR, 6, finished running syn.simv on $<)
	@$(call PRINT_COLOR, 2, output is in output/$*.syn.{out cpi wb ppln})

# Allow us to type 'make <my_program>.out' instead of 'make output/<my_program>.out'
./%.out: output/%.out ;
.PHONY: ./%.out

# Declare that creating a %.out file also creates both %.cpi, %.wb, and %.ppln files
%.cpi %.wb %.ppln: %.out ;

.PRECIOUS: %.out %.cpi %.wb %.ppln

# run all programs in one command (use 'make -j' to run multithreaded)
simulate_all: build/simv compile_all $(PROGRAMS:programs/%=output/%.out)
simulate_all.syn: build/syn.simv compile_all $(PROGRAMS:programs/%=output/%.syn.out)
.PHONY: simulate_all simulate_all.syn

###################
# ---- Verdi ---- #
###################

# run verdi on a program with: 'make <my_program>.verdi' or 'make <my_program>.syn.verdi'

# Options to launch Verdi when running the executable
RUN_VERDI_OPTS = -gui=verdi -verdi_opts "-ultra" -no_save
# Not sure why no_save is needed right now. Otherwise prints an error
VERDI_DIR = /tmp/$(USER)470
VERDI_TEMPLATE = /usr/caen/misc/class/eecs470/verdi-config/initialnovas.rc

# verdi hates us: we must use the /tmp folder for all verdi files or it will crash
# this adds much unecessary complexity in the makefile
# A directory for verdi, specified in the build/novas.rc file.
$(VERDI_DIR) $(VERDI_DIR)/verdiLog:
	mkdir -p $@
# Symbolic link from the build folder to VERDI_DIR in /tmp
build/verdiLog: $(VERDI_DIR) build
	ln --force -s $(VERDI_DIR)/verdiLog build
# make a custom novas.rc for your username matching VERDI_DIR
build/novas.rc: $(VERDI_TEMPLATE) | build
	sed s/UNIQNAME/$${USER}/ $< > $@

# now the actual targets to launch verdi
%.verdi: programs/mem/%.mem build/simv build/novas.rc build/verdiLog $(VERDI_DIR)
	cd build && ./simv $(RUN_VERDI_OPTS) +MEMORY=../$< +OUTPUT=../output/verdi_output

%.syn.verdi: programs/mem/%.mem build/syn.simv build/novas.rc build/verdiLog $(VERDI_DIR)
	cd build && ./syn.simv $(RUN_VERDI_OPTS) +MEMORY=../$< +OUTPUT=../output/syn_verdi_output

.PHONY: %.verdi

#############################
# ---- Visual Debugger ---- #
#############################

# this is the visual debugger for project 2, an extremely helpful tool, try it out!
# compile and run the visual debugger on a program with:
# 'make <my_program>.vis'

# Don't ask me why we spell VisUal TestBenchER like this...
VTUBER = test/vtuber_test.sv \
         test/vtuber.cpp \
		 test/mem.sv

VISFLAGS = -lncurses

build/vis.simv: $(HEADERS) $(VTUBER) $(SOURCES) | build
	@$(call PRINT_COLOR, 5, compiling visual debugger testbench)
	$(VCS) $(VISFLAGS) $^ -o $@
	@$(call PRINT_COLOR, 6, finished compiling visual debugger testbench)

%.vis:  programs/mem/%.mem build/vis.simv
	cd build && ./vis.simv +MEMORY=../$<
	@$(call PRINT_COLOR, 6, Fullscreen your terminal for the best VTUBER experience!)
.PHONY: %.vis

###############################
# ---- Build Directories ---- #
###############################

# Directories for holding build files or run outputs
# Targets that need these directories should add them after a pipe.
# ex: "target: dep1 dep2 ... | build"
build synth output programs/mem build/module_tests build/vector_programs output/module_tests output/vector_programs:
	mkdir -p $@
# Don't leave any files in these, they will be deleted by clean commands

#####################
# ---- Cleanup ---- #
#####################

# You should only clean your directory if you think something has built incorrectly
# or you want to prepare a clean directory for e.g. git (first check your .gitignore).
# Please avoid cleaning before every build. The point of a makefile is to
# automatically determine which targets have dependencies that are modified,
# and to re-build only those as needed; avoiding re-building everything everytime.

# 'make clean' removes build/output files, 'make nuke' removes all generated files
# 'make clean' does not remove .mem or .dump files
# clean_* commands remove certain groups of files

clean: clean_exe clean_run_files
	@$(call PRINT_COLOR, 6, note: clean is split into multiple commands you can call separately: $^)

# removes all extra synthesis files and the entire output directory
# use cautiously, this can cause hours of recompiling in final project
nuke: clean clean_synth clean_programs
	@$(call PRINT_COLOR, 6, note: nuke is split into multiple commands you can call separately: $^)

clean_exe:
	@$(call PRINT_COLOR, 3, removing compiled executable files)
	rm -rf build
	rm -rf *simv *.daidir csrc *.key      # created by simv/syn.simv/vis.simv
	rm -rf vcdplus.vpd vc_hdrs.h          # created by simv/syn.simv/vis.simv
	rm -rf unifiedInference.log xprop.log # created by simv/syn.simv/vis.simv

	rm -rf verdi* novas* *fsdb*           # verdi files
	rm -rf dve* inter.vpd DVEfiles        # old DVE debugger

clean_run_files:
	@$(call PRINT_COLOR, 3, removing per-run outputs)
	rm -rf output
	rm -rf output/*.out output/*.cpi output/*.wb output/*.ppln

clean_synth:
	@$(call PRINT_COLOR, 1, removing synthesis files)
	rm -rf synth
	rm -rf *.vg *_svsim.sv *.res *.rep *.ddc *.chk *.syn *-synth.out *.db *.svf *.mr *.pvl command.log

clean_programs:
	@$(call PRINT_COLOR, 3, removing program memory files)
	rm -rf programs/mem
	@$(call PRINT_COLOR, 3, removing dump files)
	rm -rf programs/*.dump*

.PHONY: clean nuke clean_%

######################
# ---- Printing ---- #
######################

# this is a GNU Make function with two arguments: PRINT_COLOR(color: number, msg: string)
# it does all the color printing throughout the makefile
PRINT_COLOR = if [ -t 0 ]; then tput setaf $(1) ; fi; echo $(2); if [ -t 0 ]; then tput sgr0; fi
# colors: 0:black, 1:red, 2:green, 3:yellow, 4:blue, 5:magenta, 6:cyan, 7:white
# other numbers are valid, but aren't specified in the tput man page

# Make functions are called like this:
# $(call PRINT_COLOR,3,Hello World!)
# NOTE: adding '@' to the start of a line avoids printing the command itself, only the output
