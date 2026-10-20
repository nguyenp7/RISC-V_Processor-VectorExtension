# Mask-producer-to-v0-consumer RAW tests, mask logical chains, and VL updates.
# Adjacent consumers exercise the current engine's serialization and readiness;
# they are forwarding candidates, not evidence of an implemented vector bypass.
    li x1, 0x1200
    li x2, 0x1210
    li x3, 0x1220
    li x4, 0x1230
    li x5, 0x1240
    li x6, 0x1250
    la x7, compare_a
    la x8, compare_b
    li x9, 4
    li x10, 5

    vsetvli x0, x9, e8, m1, tu, mu
    vle8.v v1, (x7)
    vle8.v v2, (x8)
    vmv.v.i v3, 9
# Signed comparison produces mask 0001; the immediately following operation
# consumes the new v0 rather than its previous contents.
    vmslt.vv v0, v1, v2
    vadd.vi v3, v1, 1, v0.t
    vse8.v v3, (x1)       # 0x1200: 0x09090900

# Equality produces mask 0010. Inactive destination elements retain their data.
    vmseq.vv v0, v1, v2
    vsub.vv v3, v2, v1, v0.t
    vse8.v v3, (x2)       # 0x1210: 0x09090000
# A masked comparison may itself write v0, reading each old mask bit first.
    vmseq.vv v0, v1, v1, v0.t
    vmseq.vv v4, v1, v1
    vmand.mm v0, v4, v0
    vadd.vx v3, v3, x10, v0.t
    vse8.v v3, (x3)       # 0x1220: 0x09090500
    vmor.mm v0, v4, v0
    vadd.vi v3, v3, 1, v0.t
    vse8.v v3, (x4)       # 0x1230: 0x0a0a0601
# Materialize the mask as bytes, avoiding checks on agnostic mask-tail bits.
    vmv.v.i v5, 0
    vadd.vi v5, v5, 1, v0.t
    vse8.v v5, (x5)       # 0x1240: 0x01010101

# Configuration is consumed without a gap. With VL=2, element zero changes,
# masked element one and tail elements two/three remain undisturbed.
    vsetivli x0, 2, e8, m1, tu, mu
    vmslt.vv v0, v1, v2
    vadd.vi v3, v3, 2, v0.t
    vsetivli x0, 4, e8, m1, tu, mu
    vse8.v v3, (x6)       # 0x1250: 0x0a0a0603
    wfi

    .align 2
compare_a:
    .word 0x7f0180ff
compare_b:
    .word 0x02ff8001
