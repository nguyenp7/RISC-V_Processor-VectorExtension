"""Execute RVV assembly programs against an oracle for the implemented subset.

Uses the existing DPI-free CPU program checker. The local assembler lowers the
implemented standard RVV mnemonics to instruction words, then delegates scalar
assembly to scalar_regression. No production compiler or RTL edits are needed.
The test data and model target this processor's default VLEN=32/ELEN=32.
Semantics: https://github.com/riscv/riscv-v-spec/blob/v1.0/v-spec.adoc

Examples:
    python3 vectorTests/vector_program_regression.py --prepare-only
    python3 vectorTests/vector_program_regression.py --both-latencies
"""
from __future__ import annotations

import argparse
from collections import Counter
import hashlib
import json
from pathlib import Path
import re
import subprocess
import sys

# The shared CPU build helpers and scalar assembler remain in test/.
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "test"))
import run_verification as runner
import scalar_regression as scalar

ROOT=runner.ROOT
MASK=scalar.MASK
VLEN=32
VECTOR_OPS={
    "vadd.vv":(0,0), "vsub.vv":(2,0),
    "vadd.vx":(0,4), "vsub.vx":(2,4), "vadd.vi":(0,3),
    "vmv.v.i":(23,3), "vmseq.vv":(24,0), "vmslt.vv":(27,0),
    "vmand.mm":(25,2), "vmor.mm":(26,2),
}
MEMORY_OPS={f"v{kind}{bits}.v":(kind=="se",bits) for kind in ("le","se") for bits in (8,16,32)}
REQUIRED=set(VECTOR_OPS)|set(MEMORY_OPS)|{"vsetvli","vsetivli","vsetvl"}
CSR={"vstart":0x008,"vxsat":0x009,"vxrm":0x00a,"vcsr":0x00f,"vl":0xc20,"vtype":0xc21,"vlenb":0xc22}
LMUL={"m1":0,"m2":1,"m4":2,"m8":3,"mf4":6,"mf2":7}

# Hand-calculated output words are a second oracle, independent of instruction
# decoding and the element interpreter. Addresses match the program comments.
# Lists name consecutive little-endian words starting at the dictionary key.
EXPECTED={
    "rvv_arithmetic_e8":{
        0x1000:[0x008082ff],0x1020:[0xfe7e7e01],0x1040:[0x02828303],
        0x1060:[0xfc7c7dfd],0x1080:[0xef6f70f0],0x10a0:[0xffffffff]},
    "rvv_arithmetic_e16":{
        0x1000:[0x8002ffff,0x00008000],0x1020:[0x7ffe0001,0xfffe7ffe],
        0x1040:[0x80030003,0x00028002],0x1060:[0x7ffdfffd,0xfffc7ffc],
        0x1080:[0x7ff0fff0,0xffef7fef],0x10a0:[0xffffffff,0xffffffff]},
    "rvv_arithmetic_e32":{
        0x1000:[0xffffffff,0x80000002,0x80000000,0],
        0x1020:[1,0x7ffffffe,0x7ffffffe,0xfffffffe],
        0x1040:[3,0x80000003,0x80000002,2],
        0x1060:[0xfffffffd,0x7ffffffd,0x7ffffffc,0xfffffffc],
        0x1080:[0xfffffff0,0x7ffffff0,0x7fffffef,0xffffffef],
        0x10a0:[0xffffffff]*4},
    "rvv_config":{
        0x1000:[0x00070707],0x1010:[3],0x1020:[0xfffefffe],0x1030:[2],
        0x1040:[0xffffffff]*4,0x1050:[4],0x1060:[0x00030003]*2,
        0x1070:[4],0x1080:[0x00070707],0x1090:[0]},
    "rvv_grouping":{
        0x1000:[1,2,0x80000000,0,0x80000001,16,0xffffffff,0x12345679],
        0x1040:[0x00000606],0x1050:[0x0000fff9],0x1060:[0x000000fb],
        0x1070:[1,2,0x80000000,0]},
    "rvv_masks":{
        0x1000:[0x09008081],0x1010:[5],0x1020:[2],0x1030:[0],0x1040:[7],0x1050:[0xff008081]},
    "rvv_vl_tail":{
        0x1000:[0x0909ffff],0x1010:[0x0909ffff],0x1020:[0x0a0affff],0x1028:[0],0x1030:[0x0a0b0000]},
    "rvv_forward_alu":{
        0x1000:[0x0a0a0a0a],0x1010:[0x03030303],0x1020:[0x07070707],0x1030:[0x07070707],
        0x1040:[0xffffffef]*4,0x1050:[0xfffffffb]*4},
    "rvv_forward_load":{
        0x1100:[0x00040200],0x1110:[0x80028100],0x1120:[0x00040000],0x1130:[0x00020000],
        0x1140:[1]*4,0x1150:[2]*4},
    "rvv_forward_mask":{
        0x1200:[0x09090900],0x1210:[0x09090000],0x1220:[0x09090500],
        0x1230:[0x0a0a0601],0x1240:[0x01010101],0x1250:[0x0a0a0603]},
}

def check_expected(name,memory):
    if name not in EXPECTED:raise ValueError(f"{name}: add hand-calculated output expectations")
    for address,words in EXPECTED[name].items():
        for index,expected in enumerate(words):
            target=address+4*index;actual=int.from_bytes(memory[target:target+4],"little")
            if actual!=expected:
                raise ValueError(f"{name}: hand-calculated output {target:04x} expected {expected:08x}, oracle produced {actual:08x}")

def integer(token):
    return int(token,0)

def vector_register(token):
    match=re.fullmatch(r"v(\d+)",token)
    if not match or not 0<=int(match[1])<32:
        raise ValueError(f"invalid vector register {token}")
    return int(match[1])

def scalar_register(token):
    try:return scalar.REG[token]
    except KeyError:raise ValueError(f"invalid scalar register {token}") from None

def type_immediate(tokens):
    if len(tokens)!=4 or tokens[0] not in ("e8","e16","e32") or tokens[1] not in LMUL or tokens[2] not in ("tu","ta") or tokens[3] not in ("mu","ma"):
        raise ValueError(f"unsupported vtype {','.join(tokens)}")
    sew={"e8":0,"e16":1,"e32":2}[tokens[0]]
    return (int(tokens[3]=="ma")<<7)|(int(tokens[2]=="ta")<<6)|(sew<<3)|LMUL[tokens[1]]

def csr_address(token):
    return CSR[token] if token in CSR else integer(token)

def encode_vector(op,args):
    if op in ("vsetvli","vsetivli"):
        if len(args)!=6:raise ValueError(f"{op} needs rd, AVL, SEW, LMUL, tail, mask")
        rd=scalar_register(args[0]);vt=type_immediate(args[2:])
        avl=integer(args[1]) if op=="vsetivli" else scalar_register(args[1])
        if not 0<=avl<32:raise ValueError("vsetivli AVL must fit unsigned five bits")
        return (0xc0000000 if op=="vsetivli" else 0)|(vt<<20)|(avl<<15)|(7<<12)|(rd<<7)|0x57
    if op=="vsetvl":
        if len(args)!=3:raise ValueError("vsetvl needs rd, rs1, rs2")
        return (0x40<<25)|(scalar_register(args[2])<<20)|(scalar_register(args[1])<<15)|(7<<12)|(scalar_register(args[0])<<7)|0x57
    if op in VECTOR_OPS:
        fn,f3=VECTOR_OPS[op];masked=args[-1:]==["v0.t"]
        if masked:args=args[:-1]
        if op=="vmv.v.i":
            if len(args)!=2 or masked:raise ValueError("vmv.v.i requires vd, simm5")
            rd=vector_register(args[0]);vs2=0;source=integer(args[1])
        else:
            if len(args)!=3:raise ValueError(f"{op} requires three operands")
            rd=vector_register(args[0]);vs2=vector_register(args[1])
            source=integer(args[2]) if f3==3 else scalar_register(args[2]) if f3==4 else vector_register(args[2])
        if f3==3 and not -16<=source<=15:raise ValueError("vector immediate must fit signed five bits")
        if masked and f3==2:raise ValueError("mask logical instructions are unmasked")
        return (fn<<26)|(int(not masked)<<25)|(vs2<<20)|((source&31)<<15)|(f3<<12)|(rd<<7)|0x57
    if op in MEMORY_OPS:
        write,bits=MEMORY_OPS[op];masked=args[-1:]==["v0.t"]
        if masked:args=args[:-1]
        if len(args)!=2:raise ValueError(f"{op} requires vector register, (base)")
        match=re.fullmatch(r"(?:0)?\((\w+)\)",args[1])
        if not match:raise ValueError("vector unit-stride memory has no immediate displacement")
        return (int(not masked)<<25)|(scalar_register(match[1])<<15)|({8:0,16:5,32:6}[bits]<<12)|(vector_register(args[0])<<7)|(0x27 if write else 7)
    # Only vector CSRs are accepted; scalar platform CSR behavior is outside
    # this test oracle. Pseudoinstructions lower to the standard six CSR forms.
    if op=="csrr":op,args="csrrs",[args[0],args[1],"x0"]
    elif op=="csrw":op,args="csrrw",["x0",args[0],args[1]]
    elif op=="csrwi":op,args="csrrwi",["x0",args[0],args[1]]
    elif op=="csrs":op,args="csrrs",["x0",args[0],args[1]]
    elif op=="csrc":op,args="csrrc",["x0",args[0],args[1]]
    elif op=="csrsi":op,args="csrrsi",["x0",args[0],args[1]]
    elif op=="csrci":op,args="csrrci",["x0",args[0],args[1]]
    forms={"csrrw":1,"csrrs":2,"csrrc":3,"csrrwi":5,"csrrsi":6,"csrrci":7}
    if op in forms:
        if len(args)!=3:raise ValueError(f"{op} requires rd, csr, source")
        address=csr_address(args[1]);f3=forms[op]
        if address not in CSR.values():raise ValueError("only vector CSRs are supported")
        source=integer(args[2]) if f3&4 else scalar_register(args[2])
        if not 0<=source<32:raise ValueError("CSR source out of range")
        return (address<<20)|(source<<15)|(f3<<12)|(scalar_register(args[0])<<7)|0x73
    return None

def assemble(path,directory):
    source=re.sub(r"/\*.*?\*/","",path.read_text(),flags=re.S)
    lowered=[]
    for number,line in enumerate(source.splitlines(),1):
        line=line.split("#",1)[0].strip()
        if not line:continue
        prefix=""
        if ":" in line:
            label,line=line.split(":",1);prefix=label.strip()+": ";line=line.strip()
            if not line:lowered.append(prefix);continue
        op,*tail=line.split(None,1);args=[part.strip() for part in tail[0].split(",")] if tail else []
        try:word=encode_vector(op.lower(),args)
        except ValueError as error:raise ValueError(f"{path.name}:{number}: {error}") from error
        lowered.append(prefix+(f".word 0x{word:08x}" if word is not None else line))
    target=directory/f"{path.stem}.lowered.s"
    target.write_text("\n".join(lowered)+"\n",encoding="ascii")
    return scalar.assemble(target)

class Reference:
    def __init__(self,image):
        self.memory=bytearray(image);self.regs=[0]*32;self.vectors=[0]*32
        self.pc=0;self.vl=0;self.vtype=1<<31;self.vstart=0;self.vxrm=0;self.vxsat=0
        self.coverage=Counter();self.trace=[]

    def read(self,address,count):
        if address%count or not 0<=address<=len(self.memory)-count:
            raise ValueError(f"reference invalid access {address:08x}/{count} at PC {self.pc:08x}")
        return int.from_bytes(self.memory[address:address+count],"little")

    @staticmethod
    def exponent(vtype):
        return {0:0,1:1,2:2,3:3,6:-2,7:-1}.get(vtype&7,-99)

    @classmethod
    def vlmax(cls,vtype):
        exponent=cls.exponent(vtype);sew=(vtype>>3)&7
        if vtype>>8 or sew>2 or exponent==-99:return 0
        numerator=VLEN*(1<<max(0,exponent));denominator=(8<<sew)*(1<<max(0,-exponent))
        return numerator//denominator

    @staticmethod
    def element(vectors,base,index,bits):
        register,offset=base+(index*bits)//VLEN,(index*bits)%VLEN
        if not 0<=register<32:raise ValueError("vector register group exceeds v31")
        return (vectors[register]>>offset)&((1<<bits)-1)

    def write_element(self,base,index,bits,value):
        register,offset=base+(index*bits)//VLEN,(index*bits)%VLEN;mask=((1<<bits)-1)<<offset
        if not 0<=register<32:raise ValueError("vector register group exceeds v31")
        self.vectors[register]=(self.vectors[register]&~mask)|((value<<offset)&mask)

    @staticmethod
    def legal_group(base,exponent):
        count=1<<max(exponent,0)
        return -3<=exponent<=3 and base%count==0 and base+count<=32

    def vector_step(self,ins):
        opcode=ins&127;rd=ins>>7&31;f3=ins>>12&7;rs1=ins>>15&31;rs2=ins>>20&31;fn=ins>>26;vm=ins>>25&1
        a,b=self.regs[rs1],self.regs[rs2];dest=0;result=0
        if opcode==0x57 and f3==7:
            if ins>>30==3:name="vsetivli";vtype=ins>>20&1023;avl=rs1
            elif ins>>31==0:name="vsetvli";vtype=ins>>20&2047;avl=a if rs1 else MASK if rd else self.vl
            elif ins>>25==0x40:name="vsetvl";vtype=b;avl=a if rs1 else MASK if rd else self.vl
            else:raise ValueError("reserved vector configuration encoding")
            maximum=self.vlmax(vtype)
            if name!="vsetivli" and rs1==0 and rd==0 and (self.vlmax(self.vtype)!=maximum or self.vtype>>31):maximum=0
            self.vtype=vtype if maximum else 1<<31;self.vl=min(avl,maximum);self.vstart=0
            self.coverage[name]+=1;return rd,self.vl
        if opcode==0x73:
            address=ins>>20;source=rs1 if f3&4 else a
            values={0x008:self.vstart,0x009:self.vxsat,0x00a:self.vxrm,0x00f:(self.vxrm<<1)|self.vxsat,0xc20:self.vl,0xc21:self.vtype,0xc22:VLEN//8}
            if address not in values:raise ValueError("unimplemented reference CSR")
            old=values[address];write=(f3&3)==1 or rs1!=0
            if write and address>=0xc00:raise ValueError("write to read-only vector CSR")
            if write:
                new=source if f3&3==1 else old|source if f3&3==2 else old&~source
                if address==0x008:self.vstart=new&(VLEN-1)
                elif address==0x009:self.vxsat=new&1
                elif address==0x00a:self.vxrm=new&3
                else:self.vxsat=new&1;self.vxrm=new>>1&3
            self.coverage["vector_csr"]+=1;return rd,old
        if self.vtype>>31:raise ValueError("vector execution with vill=1")
        sew=8<<((self.vtype>>3)&7);exponent=self.exponent(self.vtype);old=self.vectors.copy()
        if opcode in (7,0x27):
            bits={0:8,5:16,6:32}.get(f3)
            if bits is None or ins>>26 or rs2:raise ValueError("unsupported vector memory encoding")
            emul=exponent+(bits.bit_length()-1)-(sew.bit_length()-1)
            if not self.legal_group(rd,emul) or not vm and rd==0:raise ValueError("illegal vector memory grouping")
            name=f"v{'se' if opcode==0x27 else 'le'}{bits}.v";self.coverage[name]+=1
            for element in range(self.vstart,self.vl):
                if not vm and not(old[0]>>element&1):continue
                address=(a+element*(bits//8))&MASK;count=bits//8
                self.read(address,count)
                if opcode==7:self.write_element(rd,element,bits,self.read(address,count))
                else:self.memory[address:address+count]=self.element(old,rd,element,bits).to_bytes(count,"little")
        else:
            name=next((name for name,fields in VECTOR_OPS.items() if fields==(fn,f3)),None)
            if name is None or name=="vmv.v.i" and (not vm or rs2!=0):raise ValueError("unsupported vector arithmetic encoding")
            if f3==2:
                if not vm:raise ValueError("masked mask logical encoding")
            else:
                if name!="vmv.v.i" and not self.legal_group(rs2,exponent):raise ValueError("illegal vs2 grouping")
                if f3==0 and not self.legal_group(rs1,exponent):raise ValueError("illegal vs1 grouping")
                if name not in ("vmseq.vv","vmslt.vv") and (not self.legal_group(rd,exponent) or not vm and rd==0):raise ValueError("illegal vector destination grouping")
                if not vm and (rs2==0 or f3==0 and rs1==0):raise ValueError("v0 EEW/mask source overlap")
            self.coverage[name]+=1
            for element in range(self.vstart,self.vl):
                if not vm and not(old[0]>>element&1):continue
                if f3==2:
                    x=old[rs2]>>element&1;y=old[rs1]>>element&1
                    value=x&y if name=="vmand.mm" else x|y
                    self.write_element(rd,element,1,value);continue
                x=self.element(old,rs2,element,sew)
                y=a if f3==4 else scalar.signed(rs1,5) if f3==3 else self.element(old,rs1,element,sew)
                y&=(1<<sew)-1
                if name.startswith("vadd"):value=x+y
                elif name.startswith("vsub"):value=x-y
                elif name=="vmv.v.i":value=y
                elif name=="vmseq.vv":value=int(x==y)
                else:value=int(scalar.signed(x,sew)<scalar.signed(y,sew))
                self.write_element(rd,element,1 if name in ("vmseq.vv","vmslt.vv") else sew,value)
        # This implementation's permitted deterministic ta/ma choice is to
        # retain prestart, inactive and tail contents. Active semantics above
        # come from the architecture, independently of cycle-by-cycle RTL.
        self.vstart=0
        return dest,result

    def execute(self):
        for _ in range(2000000):
            pc=self.pc;ins=self.read(pc,4);opcode=ins&127;rd=ins>>7&31;f3=ins>>12&7;rs1=ins>>15&31;rs2=ins>>20&31;f7=ins>>25
            a,b=self.regs[rs1],self.regs[rs2];imm=scalar.signed(ins>>20,12);nextpc=pc+4;dest=0;result=0;halt=0
            if opcode in (0x57,7,0x27) or opcode==0x73 and f3:
                dest,result=self.vector_step(ins)
            elif opcode==0x13:
                dest=rd
                if f3==0:result=a+imm
                elif f3==2:result=int(scalar.signed(a)<imm)
                elif f3==3:result=int(a<(imm&MASK))
                elif f3==4:result=a^(imm&MASK)
                elif f3==6:result=a|(imm&MASK)
                elif f3==7:result=a&(imm&MASK)
                elif f3==1:result=a<<rs2
                elif f3==5:result=(scalar.signed(a) if ins>>30&1 else a)>>rs2
            elif opcode==0x33:
                dest=rd
                if f7==1:
                    if f3==0:result=a*b
                    elif f3==1:result=scalar.signed(a)*scalar.signed(b)>>32
                    elif f3==2:result=scalar.signed(a)*b>>32
                    elif f3==3:result=a*b>>32
                    else:raise ValueError("reference division unsupported")
                elif f3==0:result=a-b if f7==32 else a+b
                elif f3==1:result=a<<(b&31)
                elif f3==2:result=int(scalar.signed(a)<scalar.signed(b))
                elif f3==3:result=int(a<b)
                elif f3==4:result=a^b
                elif f3==5:result=(scalar.signed(a) if f7==32 else a)>>(b&31)
                elif f3==6:result=a|b
                else:result=a&b
            elif opcode in (0x37,0x17):dest=rd;result=(ins&0xfffff000)+(pc if opcode==0x17 else 0)
            elif opcode==3:
                dest=rd;count=1<<(f3&3);result=self.read((a+imm)&MASK,count)
                if f3<4:result=scalar.signed(result,count*8)
            elif opcode==0x23:
                offset=scalar.signed((ins>>25<<5)|(ins>>7&31),12);address=(a+offset)&MASK;count=1<<f3
                self.read(address,count);self.memory[address:address+count]=(b&((1<<(count*8))-1)).to_bytes(count,"little")
            elif opcode==0x63:
                offset=scalar.signed(((ins>>31)<<12)|((ins>>7&1)<<11)|((ins>>25&63)<<5)|((ins>>8&15)<<1),13)
                take={0:a==b,1:a!=b,4:scalar.signed(a)<scalar.signed(b),5:scalar.signed(a)>=scalar.signed(b),6:a<b,7:a>=b}[f3]
                if take:nextpc=pc+offset
            elif opcode==0x6f:
                dest=rd;result=pc+4;nextpc=pc+scalar.signed(((ins>>31)<<20)|((ins>>12&255)<<12)|((ins>>20&1)<<11)|((ins>>21&1023)<<1),21)
            elif opcode==0x67:dest=rd;result=pc+4;nextpc=(a+imm)&0xfffffffe
            elif ins==0x10500073:halt=1
            elif opcode==0x0f:pass
            else:raise ValueError(f"unsupported instruction {ins:08x} at PC {pc:08x}")
            result&=MASK
            if dest:self.regs[dest]=result
            self.trace.append((pc,dest,result if dest else 0,halt));self.pc=nextpc&MASK
            if halt:return self.trace,self.memory
        raise ValueError("reference timeout")

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--no-build",action="store_true")
    parser.add_argument("--prepare-only",action="store_true",help="prepare images and goldens without building/running a simulator")
    parser.add_argument("--program-dir",type=Path,default=Path(__file__).resolve().parent,help="directory containing rvv_*.s (default: vectorTests)")
    parser.add_argument("--both-latencies",action="store_true",help="also build/run a zero-latency memory variant")
    parser.add_argument("--verilator")
    parser.add_argument("--jobs",type=int,default=4)
    args=parser.parse_args()
    configured=re.search(r"`define\s+RVV_VREG_WIDTH\s+(\d+)",(ROOT/"verilog/ISA.svh").read_text())
    if configured is None or int(configured[1])!=VLEN:
        raise ValueError("these assembly output expectations require the default VLEN=32")
    program_directory=args.program_dir.resolve()
    programs=sorted(program_directory.glob("rvv_*.s"))
    if not programs:raise ValueError(f"no rvv_*.s tests found in {program_directory}")
    directory=ROOT/"build/vector_programs";directory.mkdir(parents=True,exist_ok=True)
    source_paths=[*programs,Path(__file__),ROOT/"test/scalar_regression.py",ROOT/"test/cpu_program_test.sv",*sorted((ROOT/"verilog").glob("*.sv*"))]
    fingerprint=lambda:{str(path.relative_to(ROOT)):hashlib.sha256(path.read_bytes()).hexdigest() for path in source_paths}
    hashes=fingerprint();coverage=Counter();prepared=[]
    for path in programs:
        image=assemble(path,directory);model=Reference(image);trace,final=model.execute();coverage.update(model.coverage)
        check_expected(path.stem,final)
        prefix=directory/path.stem;scalar.write_image(prefix.with_suffix(".mem"),image);scalar.write_image(prefix.with_suffix(".final.mem"),final)
        prefix.with_suffix(".trace").write_text("".join(f"{pc:08x} {rd:08x} {value:08x} {halt:08x}\n" for pc,rd,value,halt in trace),encoding="ascii")
        prepared.append((path.stem,prefix,len(trace),dict(model.coverage)))
    missing=REQUIRED-set(coverage)
    if missing:raise ValueError(f"assembly suite does not execute all 19 RVV instructions: missing {sorted(missing)}")
    if args.prepare_only:
        if fingerprint()!=hashes:raise ValueError("vector programs or RTL changed while preparing fixtures")
        manifest={"source_sha256":hashes,"coverage":dict(sorted(coverage.items())),"programs":[name for name,_,_,_ in prepared]}
        (directory/"prepared.json").write_text(json.dumps(manifest,indent=2)+"\n",encoding="utf-8")
        print(f"PASS prepared {len(prepared)} vector programs; all 19 RVV instructions covered; no simulator required")
        return 0
    results=[]
    for suffix,latency in ([('',3),('_vector_zero',0)] if args.both_latencies else [('',3)]):
        executable=runner.build("cpu_program_test",args,suffix=suffix)
        for name,prefix,count,operations in prepared:
            runner.run([str(executable),f"+MEMORY={prefix.with_suffix('.mem').relative_to(ROOT).as_posix()}",
                        f"+TRACE={prefix.with_suffix('.trace').relative_to(ROOT).as_posix()}",
                        f"+FINAL={prefix.with_suffix('.final.mem').relative_to(ROOT).as_posix()}"],directory/f"{name}_latency{latency}.log")
            results.append({"program":name,"memory_latency":latency,"passed":True,"retirements":count,"operations":operations})
    if fingerprint()!=hashes:raise ValueError("vector programs or RTL changed during the run; rerun final sources")
    (ROOT/"build/vector_program_results.json").write_text(json.dumps({"source_sha256":hashes,"coverage":dict(sorted(coverage.items())),"runs":results},indent=2)+"\n",encoding="utf-8")
    print(f"PASS vector assembly: {len(results)} CPU runs; all 19 RVV instructions executed; full memory and retirement traces match")
    return 0

if __name__=="__main__":
    try:sys.exit(main())
    except (ValueError,RuntimeError,OSError,subprocess.SubprocessError) as error:
        print(f"FAIL: {error}",file=sys.stderr);sys.exit(1)
