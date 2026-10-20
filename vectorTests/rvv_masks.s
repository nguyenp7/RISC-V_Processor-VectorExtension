# Signed compare, equality, mask AND/OR, masked arithmetic and masked stores.
# v1=0101, v2=0010, v3=0000, v0=0111 in their low four bits.
.text
    la x1, input_a
    la x2, input_b
    li x10, 0x1000
    vsetivli x0, 4, e8, m1, tu, mu
    vle8.v v4, (x1)
    vle8.v v8, (x2)
    vmslt.vv v1, v4, v8
    vmseq.vv v2, v4, v8
    vmand.mm v3, v1, v2
    vmv.v.i v12, 9
    vmor.mm v0, v1, v2
    vadd.vi v12, v4, 1, v0.t
    vse8.v v12, (x10)           # 0x1000: 81 80 00 09
    addi x10, x10, 16
    vse8.v v1, (x10)            # 0x1010: 05 00 00 00
    addi x10, x10, 16
    vse8.v v2, (x10)            # 0x1020: 02 00 00 00
    addi x10, x10, 16
    vse8.v v3, (x10)            # 0x1030: 00 00 00 00
    addi x10, x10, 16
    vse8.v v0, (x10)            # 0x1040: 07 00 00 00
    addi x10, x10, 16
    vmv.v.i v20, -1
    vse8.v v20, (x10)
    vse8.v v12, (x10), v0.t     # 0x1050: 81 80 00 ff (inactive store suppressed)
    wfi
.align 2
input_a:
    .word 0x00ff7f80
input_b:
    .word 0xff017f00
