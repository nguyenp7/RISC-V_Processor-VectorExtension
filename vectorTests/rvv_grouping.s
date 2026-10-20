# Integer/fractional LMUL and memory EEW different from arithmetic SEW.
.text
    la x1, input_words
    li x10, 0x1000
    vsetivli x0, 8, e32, m8, tu, mu
    vle32.v v8, (x1)
    vadd.vi v8, v8, 1           # Destructive RAW across all eight registers.
    vse32.v v8, (x10)
    addi x10, x10, 64
    vsetivli x0, 2, e8, mf2, tu, mu
    vmv.v.i v2, 5
    vadd.vi v2, v2, 1
    vse8.v v2, (x10)            # 0x1040: 06 06
    addi x10, x10, 16
    vsetivli x0, 1, e16, mf2, tu, mu
    vmv.v.i v3, 9
    vadd.vi v3, v3, -16
    vse16.v v3, (x10)           # 0x1050: fff9
    addi x10, x10, 16
    vsetivli x0, 1, e8, mf4, tu, mu
    vmv.v.i v1, -8
    vadd.vi v1, v1, 3
    vse8.v v1, (x10)            # 0x1060: fb
    addi x10, x10, 16
    vsetivli x0, 4, e8, m1, tu, mu
    vle32.v v16, (x1)          # EEW32/SEW8 -> EMUL=4, not LMUL=1.
    vsetvli x0, x0, e32, m4, tu, mu
    vadd.vi v20, v16, 1
    vse32.v v20, (x10)          # 0x1070: first four input words plus one.
    wfi
.align 2
input_words:
    .word 0, 1, 0x7fffffff, 0xffffffff
    .word 0x80000000, 15, 0xfffffffe, 0x12345678
