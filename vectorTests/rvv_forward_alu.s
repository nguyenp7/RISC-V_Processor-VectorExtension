# Adjacent vector ALU producer/consumer and destructive-overlap RAW tests.
# These are forwarding candidates; the current vector engine resolves them by
# serializing complete instructions, and does not implement a vector bypass.
# Scalar instructions only establish output pointers, AVL and a .vx operand.
    li x1, 0x1000
    li x2, 0x1010
    li x3, 0x1020
    li x4, 0x1030
    li x5, 0x1040
    li x6, 0x1050
    li x7, 4
    li x8, 5

# Four byte elements. No nops separate dependent vector instructions.
    vsetvli x0, x7, e8, m1, tu, mu
    vmv.v.i v1, 7
    vadd.vi v2, v1, -3
    vadd.vv v3, v2, v1
    vsub.vv v3, v3, v2
    vadd.vx v4, v3, x8
    vsub.vx v4, v4, x8
    vsub.vv v2, v1, v2
    vadd.vv v1, v2, v1
    vse8.v v1, (x1)       # 0x1000: 0x0a0a0a0a
    vse8.v v2, (x2)       # 0x1010: 0x03030303
    vse8.v v3, (x3)       # 0x1020: 0x07070707
    vse8.v v4, (x4)       # 0x1030: 0x07070707

# Four 32-bit elements occupy four registers per group at VLEN=32.
# v8 and v12 are aligned groups. Both source/destination overlap directions
# above, and full-group destructive updates below, must preserve old operands.
    vsetivli x0, 4, e32, m4, tu, mu
    vmv.v.i v8, -16
    vadd.vi v12, v8, 15
    vadd.vv v8, v8, v12
    vsub.vx v12, v8, x8
    vsub.vv v12, v12, v8
    vse32.v v8, (x5)      # 0x1040..0x104c: four words 0xffffffef
    vse32.v v12, (x6)     # 0x1050..0x105c: four words 0xfffffffb
    wfi
