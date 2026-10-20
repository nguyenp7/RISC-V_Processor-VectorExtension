# Test all three configuration instructions and their scalar vl results.
# Scalar instructions only supply addresses/AVL/vtype and record vector CSRs.
.text
    li x10, 0x1000
    li x2, 3
    vsetvli x5, x2, e8, m1, tu, mu
    vmv.v.i v4, 7
    vse8.v v4, (x10)             # 0x1000: 07 07 07
    sw x5, 16(x10)              # 0x1010: vl=3
    addi x10, x10, 32
    vsetivli x6, 2, e16, m1, tu, mu
    vmv.v.i v8, -2
    vse16.v v8, (x10)           # 0x1020: fffe fffe
    sw x6, 16(x10)              # 0x1030: vl=2
    addi x10, x10, 32
    li x2, 4
    li x3, 0x12                 # vtype=e32,m4,tu,mu
    vsetvl x7, x2, x3
    vmv.v.i v12, -1
    vse32.v v12, (x10)          # 0x1040: four ffffffff words
    sw x7, 16(x10)              # 0x1050: vl=4
    addi x10, x10, 32
    vsetvli x8, x0, e8, m1, tu, mu
    vsetvli x0, x0, e16, m2, tu, mu  # Preserve vl: VLMAX stays four.
    vmv.v.i v20, 3
    vse16.v v20, (x10)          # 0x1060: four 0003 halfwords
    sw x8, 16(x10)              # 0x1070: VLMAX=4
    addi x10, x10, 32
    vsetivli x9, 0, e8, m1, tu, mu
    vmv.v.i v4, 0               # vl=0: must not overwrite the earlier sevens.
    vsetivli x0, 4, e8, m1, tu, mu
    vse8.v v4, (x10)            # 0x1080: 07 07 07 00
    sw x9, 16(x10)              # 0x1090: vl=0
    wfi
