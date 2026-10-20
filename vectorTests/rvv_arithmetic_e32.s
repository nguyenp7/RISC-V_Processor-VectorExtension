# LMUL=4 supplies four e32 elements and exercises register-group boundaries.
# Results at 0x1000 + {0,0x20,0x40,0x60,0x80,0xa0}:
# vadd.vv, vsub.vv, vadd.vx, vsub.vx, vadd.vi -16, vmv.v.i -1.
.text
    la x1, input_a
    la x2, input_b
    li x3, 3
    li x10, 0x1000
    vsetivli x0, 4, e32, m4, tu, mu
    vle32.v v4, (x1)
    vle32.v v8, (x2)
    vadd.vv v12, v4, v8
    vse32.v v12, (x10)
    addi x10, x10, 32
    vsub.vv v12, v4, v8
    vse32.v v12, (x10)
    addi x10, x10, 32
    vadd.vx v12, v4, x3
    vse32.v v12, (x10)
    addi x10, x10, 32
    vsub.vx v12, v4, x3
    vse32.v v12, (x10)
    addi x10, x10, 32
    vadd.vi v12, v4, -16
    vse32.v v12, (x10)
    addi x10, x10, 32
    vmv.v.i v12, -1
    vse32.v v12, (x10)
    wfi
.align 2
input_a:
    .word 0x00000000, 0x80000000, 0x7fffffff, 0xffffffff
input_b:
    .word 0xffffffff, 0x00000002, 0x00000001, 0x00000001
