"""Small explicit RV32IM assembler/reference model for repository .s tests.

This is test infrastructure, not a replacement production assembler. Unsupported
directives/instructions raise an error. GNU-compatible li/la expansion and the
repository's scalar subset are sufficient for these hand-written programs.
"""
from __future__ import annotations
from pathlib import Path
import re
import random

ROOT=Path(__file__).resolve().parents[1]
MASK=0xffffffff
ABI="zero ra sp gp tp t0 t1 t2 s0 s1 a0 a1 a2 a3 a4 a5 a6 a7 s2 s3 s4 s5 s6 s7 s8 s9 s10 s11 t3 t4 t5 t6".split()
REG={name:index for index,name in enumerate(ABI)} | {f"x{i}":i for i in range(32)} | {"fp":8}
R_OP={"add":(0,0),"sub":(0,32),"sll":(1,0),"slt":(2,0),"sltu":(3,0),"xor":(4,0),"srl":(5,0),"sra":(5,32),"or":(6,0),"and":(7,0),"mul":(0,1),"mulh":(1,1),"mulhsu":(2,1),"mulhu":(3,1)}
I_OP={"addi":0,"slti":2,"sltiu":3,"xori":4,"ori":6,"andi":7,"slli":1,"srli":5,"srai":5}
LOAD={"lb":0,"lh":1,"lw":2,"lbu":4,"lhu":5}
STORE={"sb":0,"sh":1,"sw":2}
BRANCH={"beq":0,"bne":1,"blt":4,"bge":5,"bltu":6,"bgeu":7}

def signed(value,bits=32):
    value &= (1<<bits)-1
    return value-(1<<bits) if value & (1<<(bits-1)) else value

def expression(token,symbols):
    token=token.strip()
    if token in symbols:return symbols[token]
    try:return int(token,0)
    except ValueError:
        match=re.fullmatch(r"([A-Za-z_]\w*)([+-])(0x[0-9a-fA-F]+|\d+)",token)
        if match and match[1] in symbols:
            return symbols[match[1]]+(1 if match[2]=="+" else -1)*int(match[3],0)
        raise ValueError(f"unknown expression {token}")

def iword(op,f3,rd,rs1,imm):
    if not -2048<=imm<=2047:raise ValueError(f"12-bit immediate out of range: {imm}")
    return ((imm&4095)<<20)|(rs1<<15)|(f3<<12)|(rd<<7)|op

def assemble(path):
    text=re.sub(r"/\*.*?\*/","",path.read_text(),flags=re.S)
    lines=[line.split("#",1)[0].strip() for line in text.splitlines()]
    symbols={}
    records=[]
    pc=0
    for line in lines:
        if not line:continue
        if ":" in line:
            label,line=line.split(":",1); symbols[label.strip()]=pc; line=line.strip()
            if not line:continue
        if "=" in line:
            name,value=line.split("=",1);symbols[name.strip()]=expression(value,symbols);continue
        op,*tail=line.split(None,1);op=op.lower();args=[part.strip() for part in tail[0].split(",")] if tail else []
        if op in (".text",".section",".global",".globl",".option",".type",".size"):continue
        if op in (".align",".p2align"):
            end=(pc+(1<<expression(args[0],symbols))-1)&-(1<<expression(args[0],symbols))
            while pc<end:records.append((pc,"nop",[]));pc+=4
            continue
        if op in (".word",".dword"):
            for arg in args:records.append((pc,op,[arg]));pc+=4 if op==".word" else 8
            continue
        records.append((pc,op,args))
        if op=="la":pc+=8
        elif op=="li":
            imm=signed(expression(args[1],symbols))
            pc+=4 if -2048<=imm<=2047 or imm&4095==0 else 8
        else:pc+=4
    image=bytearray(65536)
    def put(pc,value,size=4):image[pc:pc+size]=(value&((1<<(size*8))-1)).to_bytes(size,"little")
    for pc,op,args in records:
        val=lambda index:expression(args[index],symbols)
        reg=lambda index:REG[args[index]]
        word=None
        if op in (".word",".dword"):
            put(pc,val(0),4 if op==".word" else 8);continue
        if op=="nop":word=0x13
        elif op=="wfi":word=0x10500073
        elif op=="li":
            imm=signed(val(1));rd=reg(0)
            if -2048<=imm<=2047:word=iword(0x13,0,rd,0,imm)
            else:
                upper=(imm+2048)>>12; lower=signed(imm,12)
                word=((upper&0xfffff)<<12)|(rd<<7)|0x37
                if lower:put(pc+4,iword(0x13,0,rd,rd,lower))
        elif op=="la":
            delta=val(1)-pc; upper=(delta+2048)>>12; lower=signed(delta,12);rd=reg(0)
            word=((upper&0xfffff)<<12)|(rd<<7)|0x17;put(pc+4,iword(0x13,0,rd,rd,lower))
        elif op=="mv":word=iword(0x13,0,reg(0),reg(1),0)
        elif op in R_OP:
            f3,f7=R_OP[op]
            if args[2] not in REG and op in ("slt","sltu"):
                word=iword(0x13,2 if op=="slt" else 3,reg(0),reg(1),val(2))
            else:word=(f7<<25)|(reg(2)<<20)|(reg(1)<<15)|(f3<<12)|(reg(0)<<7)|0x33
        elif op in I_OP:
            imm=val(2)
            if op in ("slli","srli","srai"):
                if not 0<=imm<32:raise ValueError("shift immediate")
                imm|=0x400 if op=="srai" else 0
            word=iword(0x13,I_OP[op],reg(0),reg(1),imm)
        elif op in ("lui","auipc"):
            word=((val(1)&0xfffff)<<12)|(reg(0)<<7)|(0x37 if op=="lui" else 0x17)
        elif op in LOAD or op in STORE:
            match=re.fullmatch(r"([^()]*)\((\w+)\)",args[1]);
            if not match:raise ValueError(f"memory operand {args[1]}")
            imm=expression(match[1] or "0",symbols);base=REG[match[2]]
            if op in LOAD:word=iword(3,LOAD[op],reg(0),base,imm)
            else:word=((imm>>5&127)<<25)|(reg(0)<<20)|(base<<15)|(STORE[op]<<12)|((imm&31)<<7)|0x23
        elif op in BRANCH:
            imm=val(2)-pc
            if imm%2 or not -4096<=imm<4096:raise ValueError("branch offset")
            word=((imm>>12&1)<<31)|((imm>>5&63)<<25)|(reg(1)<<20)|(reg(0)<<15)|(BRANCH[op]<<12)|((imm>>1&15)<<8)|((imm>>11&1)<<7)|0x63
        elif op in ("jal","j"):
            rd=0 if op=="j" else 1 if len(args)==1 else reg(0)
            imm=val(0 if op=="j" or len(args)==1 else 1)-pc
            word=((imm>>20&1)<<31)|((imm>>1&1023)<<21)|((imm>>11&1)<<20)|((imm>>12&255)<<12)|(rd<<7)|0x6f
        elif op=="jalr":
            if len(args)==3:word=iword(0x67,0,reg(0),reg(1),val(2))
            else:
                match=re.fullmatch(r"([^()]*)\((\w+)\)",args[-1]);rd=reg(0) if len(args)==2 else 1
                if not match:raise ValueError("jalr operand")
                word=iword(0x67,0,rd,REG[match[2]],expression(match[1] or "0",symbols))
        else:raise ValueError(f"{path.name}:{pc:x}: unsupported {op} {args}")
        put(pc,word)
    return image

def reference(initial):
    memory=bytearray(initial);regs=[0]*32;trace=[];pc=0
    def load(addr,count):
        if addr<0 or addr+count>len(memory) or addr%count:raise ValueError(f"bad load {addr:x}/{count}")
        return int.from_bytes(memory[addr:addr+count],"little")
    for step in range(2000000):
        ins=load(pc,4);op=ins&127;rd=ins>>7&31;f3=ins>>12&7;rs1=ins>>15&31;rs2=ins>>20&31;f7=ins>>25
        a,b=regs[rs1],regs[rs2];imm=signed(ins>>20,12);nextpc=pc+4;result=0;dest=0;halt=0
        if op==0x13:
            dest=rd
            if f3==0:result=a+imm
            elif f3==2:result=int(signed(a)<imm)
            elif f3==3:result=int(a<(imm&MASK))
            elif f3==4:result=a^(imm&MASK)
            elif f3==6:result=a|(imm&MASK)
            elif f3==7:result=a&(imm&MASK)
            elif f3==1:result=a<<rs2
            elif f3==5:result=(signed(a) if ins>>30&1 else a)>>rs2
        elif op==0x33:
            dest=rd
            if f7==1:
                if f3==0:result=a*b
                elif f3==1:result=signed(a)*signed(b)>>32
                elif f3==2:result=signed(a)*b>>32
                elif f3==3:result=a*b>>32
                else:raise ValueError("unsupported divide")
            elif f3==0:result=a-b if f7==32 else a+b
            elif f3==1:result=a<<(b&31)
            elif f3==2:result=int(signed(a)<signed(b))
            elif f3==3:result=int(a<b)
            elif f3==4:result=a^b
            elif f3==5:result=(signed(a) if f7==32 else a)>>(b&31)
            elif f3==6:result=a|b
            elif f3==7:result=a&b
        elif op in (0x37,0x17):dest=rd;result=(ins&0xfffff000)+(pc if op==0x17 else 0)
        elif op==3:
            dest=rd;count=1<<(f3&3);result=load((a+imm)&MASK,count)
            if f3<4:result=signed(result,count*8)
        elif op==0x23:
            offset=signed((ins>>25<<5)|(ins>>7&31),12);addr=(a+offset)&MASK;count=1<<f3
            load(addr,count);memory[addr:addr+count]=(b&((1<<(count*8))-1)).to_bytes(count,"little")
        elif op==0x63:
            offset=signed(((ins>>31)<<12)|((ins>>7&1)<<11)|((ins>>25&63)<<5)|((ins>>8&15)<<1),13)
            take={0:a==b,1:a!=b,4:signed(a)<signed(b),5:signed(a)>=signed(b),6:a<b,7:a>=b}[f3]
            if take:nextpc=pc+offset
        elif op==0x6f:
            dest=rd;result=pc+4;offset=signed(((ins>>31)<<20)|((ins>>12&255)<<12)|((ins>>20&1)<<11)|((ins>>21&1023)<<1),21);nextpc=pc+offset
        elif op==0x67:dest=rd;result=pc+4;nextpc=(a+imm)&0xfffffffe
        elif ins==0x10500073:halt=1
        elif op==0x0f:pass
        else:raise ValueError(f"illegal reference instruction {ins:08x} at {pc:x}")
        result &= MASK
        if dest:regs[dest]=result
        trace.append((pc,dest,result if dest else 0,halt));pc=nextpc&MASK
        if halt:return trace,memory
    raise ValueError("reference timeout")

def write_image(path,data):
    path.write_text("".join(f"{int.from_bytes(data[i:i+8],'little'):016x}\n" for i in range(0,65536,8)),encoding="ascii")

def golden_comparison(name,trace,memory):
    path=ROOT/f"correct_out/{name}.wb"
    if not path.exists():return "no supplied golden"
    golden=[]
    for line in path.read_text().splitlines():
        match=re.search(r"PC\s+([0-9a-fA-F]+):.*\|\s+(?:r(\d+)=([0-9a-fA-F]+)|---)",line)
        if match:golden.append((int(match[1],16),int(match[2]) if match[2] else 0,int(match[3],16) if match[3] else 0))
    actual=[row[:3] for row in trace]
    if actual!=golden:
        first=next((i for i,(a,b) in enumerate(zip(actual,golden)) if a!=b),min(len(actual),len(golden)))
        raise ValueError(f"{name}: supplied golden trace differs at record {first} ({len(golden)} vs {len(actual)} records)")
    final=ROOT/f"correct_out/{name}.out"
    for address,value in re.findall(r"@@@ mem\[\s*(\d+)\] = ([0-9a-fA-F]+)",final.read_text()):
        addr=int(address);expected=int(value,16);got=int.from_bytes(memory[addr:addr+8],"little")
        if got!=expected:raise ValueError(f"{name}: supplied golden memory differs at {addr:x}: {got:x}!={expected:x}")
    return "supplied retirement trace and memory match"

def run_regressions(args,build,run):
    programs="halt no_hazard copy copy_long evens evens_long fib fib_long fib_rec btest1 btest2 parallel mult mult_no_lsq haha insertion saxpy sampler test_1 test_2 test_3 test_4 test_5".split()
    directory=ROOT/"build/programs";directory.mkdir(parents=True,exist_ok=True)
    prepared=[]
    for name in programs:
        image=assemble(ROOT/f"programs/{name}.s");trace,final=reference(image)
        note=golden_comparison(name,trace,final)
        prefix=directory/name
        write_image(prefix.with_suffix(".mem"),image);write_image(prefix.with_suffix(".final.mem"),final)
        prefix.with_suffix(".trace").write_text("".join(f"{pc:08x} {rd:08x} {value:08x} {halt:08x}\n" for pc,rd,value,halt in trace),encoding="ascii")
        prepared.append((name,prefix,len(trace),note))
    # Dependency-heavy deterministic streams initialize every source register,
    # retain x31 as a data base, and keep writes away from instruction storage.
    # Coverage includes every implemented ALU/M operation and signed/unsigned
    # byte/half/word loads after mixed-size stores.
    for seed in (472,104729,20261018,0xdeadbeef):
        rng=random.Random(seed);name=f"random_{seed}"
        source=["li x31, 0x4000"]+[f"li x{reg}, {rng.randrange(-2048,2048)}" for reg in range(1,31)]
        for index in range(800):
            rd,rs1,rs2=[rng.randrange(1,31) for _ in range(3)]
            kind=rng.randrange(10)
            if kind<5:
                op=rng.choice(list(R_OP));source.append(f"{op} x{rd}, x{rs1}, x{rs2}")
            elif kind<7:
                op=rng.choice(list(I_OP));imm=rng.randrange(32) if op in ("slli","srli","srai") else rng.randrange(-2048,2048)
                source.append(f"{op} x{rd}, x{rs1}, {imm}")
            elif kind==7:
                op=rng.choice(list(LOAD));width=1<<(LOAD[op]&3);offset=rng.randrange(256//width)*width
                source.append(f"{op} x{rd}, {offset}(x31)")
            elif kind==8:
                op=rng.choice(list(STORE));width=1<<STORE[op];offset=rng.randrange(256//width)*width
                source.append(f"{op} x{rs2}, {offset}(x31)")
            else:
                op=rng.choice(list(BRANCH));source += [f"{op} x{rs1}, x{rs2}, skip_{index}",f"addi x{rd}, x{rs1}, 1",f"skip_{index}:"]
        source.append("wfi")
        source_path=directory/f"{name}.s";source_path.write_text("\n".join(source)+"\n",encoding="ascii")
        image=assemble(source_path);trace,final=reference(image);prefix=directory/name
        write_image(prefix.with_suffix(".mem"),image);write_image(prefix.with_suffix(".final.mem"),final)
        prefix.with_suffix(".trace").write_text("".join(f"{pc:08x} {rd:08x} {value:08x} {halt:08x}\n" for pc,rd,value,halt in trace),encoding="ascii")
        prepared.append((name,prefix,len(trace),f"deterministic seed {seed}; independent RV32IM model"))
    variants=[("",None,"verilog")]
    if args.baseline:
        baseline=ROOT/"build/baseline/verilog"
        if not (baseline/"cpu.sv").exists():raise RuntimeError("baseline snapshot unavailable")
        sources=[str((baseline/f"{name}.sv").relative_to(ROOT)) for name in ("cpu","regfile","stage_if","stage_id","stage_ex","stage_mem","stage_wb")]
        sources += ["test/mem.sv","test/cpu_program_test.sv"]
        variants.insert(0,("_baseline",sources,str(baseline.relative_to(ROOT))))
    results=[]
    for suffix,sources,include in variants:
        exe=build("cpu_program_test",args,source_override=sources,include=include,suffix=suffix)
        for name,prefix,count,note in prepared:
            output=run([str(exe),f"+MEMORY={prefix.with_suffix('.mem').relative_to(ROOT).as_posix()}",
                        f"+TRACE={prefix.with_suffix('.trace').relative_to(ROOT).as_posix()}",
                        f"+FINAL={prefix.with_suffix('.final.mem').relative_to(ROOT).as_posix()}"],exe.parent/f"{name}.log")
            results.append({"test":name,"variant":suffix or "upgraded","passed":True,"retirements":count,"oracle":note})
            print(f"  oracle: {note}")
    return results
