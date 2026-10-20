"""Build and run the self-checking RTL benches with Verilator (no DPI).

Linux/macOS: python3 test/run_verification.py
Windows: python test/run_verification.py --verilator path/to/verilator_bin.exe
Windows uses the installed Visual Studio C++20 compiler. No packages are needed
by this script. Tool downloads and installation are intentionally separate.
"""
from __future__ import annotations
import argparse
import datetime
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[1]
RTL = ["cpu", "regfile", "stage_if", "stage_id", "stage_ex", "stage_mem", "stage_wb", "icache", "dcache", "vector_unit"]
BENCHES = {
    "dcache_test": ["verilog/dcache.sv", "test/dcache_test.sv"],
    "icache_test": ["verilog/icache.sv", "test/icache_test.sv"],
    "vector_test": ["verilog/stage_id.sv", "verilog/vector_unit.sv", "vectorTests/vector_test.sv"],
    "vector_decode_test": ["verilog/stage_id.sv", "vectorTests/vector_decode_test.sv"],
    "mem_test": ["test/mem.sv", "test/mem_test.sv"],
    "cpu_dual_test": [*(f"verilog/{name}.sv" for name in RTL), "test/cpu_dual_test.sv"],
    "cpu_exception_test": [*(f"verilog/{name}.sv" for name in RTL), "test/mem.sv", "test/cpu_exception_test.sv"],
    "cpu_program_test": [*(f"verilog/{name}.sv" for name in RTL), "test/mem.sv", "test/cpu_program_test.sv"],
}

def run(command: list[str], log: Path, env=None, cwd=ROOT) -> str:
    print("+", subprocess.list2cmdline([str(c) for c in command]), flush=True)
    result = subprocess.run(command, cwd=cwd, env=env, stdout=subprocess.PIPE,
                            stderr=subprocess.STDOUT, text=True, errors="replace")
    log.parent.mkdir(parents=True, exist_ok=True)
    log.write_text(result.stdout, encoding="utf-8")
    print(result.stdout, end="", flush=True)
    if result.returncode:
        raise RuntimeError(f"exit {result.returncode}: {command[0]} (see {log})")
    return result.stdout

def msvc_environment() -> dict[str, str]:
    env = os.environ.copy()
    if shutil.which("cl.exe"):
        return env
    candidates = list(Path("C:/Program Files/Microsoft Visual Studio").glob("*/**/VC/Auxiliary/Build/vcvars64.bat"))
    if not candidates:
        raise RuntimeError("C++20 compiler unavailable: run from a Visual Studio x64 developer prompt")
    setup = f'call "{candidates[-1]}" >nul && set'
    # Pass the command line directly: Python's list2cmdline escaping of the
    # embedded quotes is incompatible with cmd's batch-file quoting rules.
    command_line=f'"{os.environ.get("COMSPEC", "cmd.exe")}" /d /s /c "{setup}"'
    result = subprocess.run(command_line,
                            capture_output=True, text=True, check=True)
    for line in result.stdout.splitlines():
        key, sep, value = line.partition("=")
        if sep and key:
            env[key.upper()] = value
    return env

def find_verilator(requested: str | None) -> tuple[Path, dict[str, str]]:
    found = requested or os.environ.get("VERILATOR") or shutil.which("verilator")
    if not found:
        candidate = ROOT / "build/tools/verilator/bin/verilator_bin.exe"
        if candidate.exists():
            found = str(candidate)
    if not found:
        raise RuntimeError("Verilator is required; use --verilator to select the executable")
    executable = Path(found).resolve()
    env = os.environ.copy()
    # Native Windows Verilator's internal preprocessor requires a root without
    # spaces. A repository-relative root works even when the checkout has spaces.
    if os.name == "nt":
        home = executable.parent.parent
        env["VERILATOR_ROOT"] = os.path.relpath(home, ROOT).replace("\\", "/")
    return executable, env

def build(top: str, args, source_override=None, include="verilog", suffix="") -> Path:
    directory = ROOT / "build" / (top + suffix)
    directory.mkdir(parents=True, exist_ok=True)
    executable = directory / (top + (".exe" if os.name == "nt" else ""))
    if args.no_build:
        if not executable.exists():
            raise RuntimeError(f"missing executable {executable}")
        return executable
    verilator, env = find_verilator(args.verilator)
    sources = source_override or BENCHES[top]
    cmd = [str(verilator), "--cc", "--timing", "--main", "--assert",
           f"-I{include}", "--top-module", top, "--Mdir", str(directory.relative_to(ROOT))]
    if suffix == "_baseline":
        # Preserve the original source and display its two understood warnings:
        # scalar SLT/SLTU comparisons implicitly zero-extend one bit to DATA32.
        cmd.append("-Wno-fatal")
    if top == "mem_test":
        cmd.append("-DMEM_LATENCY_IN_CYCLES=32")
    if top == "cpu_program_test":
        cmd.append(f"-DMEM_LATENCY_IN_CYCLES={0 if suffix else 3}")
    if top == "cpu_exception_test":
        cmd.append("-DMEM_LATENCY_IN_CYCLES=4")
    if os.name != "nt":
        cmd += ["--build", "-j", str(args.jobs), "-o", top]
    run([*cmd, *sources], directory / "elaborate.log", env)
    if os.name == "nt":
        compiler_env = msvc_environment()
        home = verilator.parent.parent
        cpp = sorted(directory.glob("*.cpp"))
        cpp += [home / "include" / f"{name}.cpp" for name in ("verilated", "verilated_threads", "verilated_timing")]
        compiler = shutil.which("cl.exe", path=compiler_env.get("PATH"))
        if not compiler:
            raise RuntimeError("vcvars64 did not provide cl.exe")
        cmd = [compiler, "/nologo", "/std:c++20", "/EHsc", "/MD", "/O1", "/bigobj",
               f"/MP{args.jobs}", "/DVL_TIME_CONTEXT", f"/I{home / 'include'}", f"/I{home / 'include/vltstd'}",
               f"/Fo{directory}{os.sep}", f"/Fe{executable}", *map(str, cpp)]
        run(cmd, directory / "compile.log", compiler_env)
    return executable

def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--verilator")
    parser.add_argument("--tests", nargs="+", choices=BENCHES, default=[name for name in BENCHES if name!="cpu_program_test"])
    parser.add_argument("--jobs", type=int, default=4)
    parser.add_argument("--no-build", action="store_true")
    parser.add_argument("--programs", action="store_true", help="also run repository scalar assembly regressions")
    parser.add_argument("--baseline", action="store_true", help="also test the preserved/reconstructed original scalar snapshot")
    args = parser.parse_args()
    source_paths = sorted([*ROOT.glob("verilog/*.sv"), *ROOT.glob("verilog/*.svh"),
                           *(ROOT/"test").rglob("*.sv"), *(ROOT/"test").rglob("*.py"),
                           *(ROOT/"vectorTests").rglob("*.sv"), *(ROOT/"vectorTests").rglob("*.py")])
    if args.baseline:
        source_paths += sorted((ROOT/"build/baseline/verilog").glob("*.sv*"))
    fingerprint=lambda: {str(path.relative_to(ROOT)):hashlib.sha256(path.read_bytes()).hexdigest() for path in source_paths}
    source_hashes=fingerprint()
    manifest={"started_utc":datetime.datetime.now(datetime.timezone.utc).isoformat(),
              "command":[sys.executable,*sys.argv],"status":"running","source_sha256":source_hashes}
    manifest_path=ROOT/"build/verification_manifest.json"
    manifest_path.parent.mkdir(parents=True,exist_ok=True)
    manifest_path.write_text(json.dumps(manifest,indent=2)+"\n",encoding="utf-8")
    results=[]
    for top in args.tests:
        if top=="cpu_program_test":
            continue
        exe=build(top,args)
        for option in (["+LATENCY=0", "+LATENCY=3"] if top=="cpu_dual_test" else [""]):
            start=time.monotonic()
            log=exe.parent / ("run"+("_"+option.split("=")[-1] if option else "")+".log")
            output=run([str(exe), *([option] if option else [])],log)
            if "PASS" not in output:
                raise RuntimeError(f"{top} completed without a PASS marker")
            results.append({"test":top,"option":option,"passed":True,"seconds":round(time.monotonic()-start,3)})
    if args.programs or args.baseline or "cpu_program_test" in args.tests:
        import scalar_regression
        results.extend(scalar_regression.run_regressions(args,build,run))
    if fingerprint()!=source_hashes:
        raise RuntimeError("RTL/test source changed during verification; rerun against the final sources")
    (ROOT/"build/verification_results.json").write_text(json.dumps(results,indent=2)+"\n",encoding="utf-8")
    manifest.update(status="passed",simulator_runs=len(results),finished_utc=datetime.datetime.now(datetime.timezone.utc).isoformat())
    manifest_path.write_text(json.dumps(manifest,indent=2)+"\n",encoding="utf-8")
    print(f"PASS: {len(results)} simulator runs; results: build/verification_results.json")
    return 0

if __name__=="__main__":
    try:
        sys.exit(main())
    except (RuntimeError, subprocess.SubprocessError) as error:
        manifest_path=ROOT/"build/verification_manifest.json"
        if manifest_path.exists():
            manifest=json.loads(manifest_path.read_text(encoding="utf-8"))
            manifest.update(status="failed",error=str(error))
            manifest_path.write_text(json.dumps(manifest,indent=2)+"\n",encoding="utf-8")
        print(f"FAIL: {error}",file=sys.stderr)
        sys.exit(1)
