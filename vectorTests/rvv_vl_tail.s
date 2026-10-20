# Tail retention, zero vl, prestart retention and clearing of vector vstart.
.text
    li x10, 0x1000
    vsetivli x0, 4, e8, m1, tu, mu
    vmv.v.i v4, 9
    vsetivli x0, 2, e8, m1, tu, mu
    vmv.v.i v4, -1
    vsetivli x0, 4, e8, m1, tu, mu
    vse8.v v4, (x10)            # 0x1000: ff ff 09 09
    addi x10, x10, 16
    vsetivli x0, 0, e8, m1, tu, mu
    vadd.vi v4, v4, 1           # No element may change at vl=0.
    vsetivli x0, 4, e8, m1, tu, mu
    vse8.v v4, (x10)            # 0x1010: ff ff 09 09
    addi x10, x10, 16
    csrrwi x0, 0x008, 2         # vstart=2: skip the first two elements.
    vadd.vi v4, v4, 1
    csrrs x5, 0x008, x0
    vse8.v v4, (x10)            # 0x1020: ff ff 0a 0a
    sw x5, 8(x10)               # 0x1028: vstart was cleared to zero.
    addi x10, x10, 16
    vsetivli x0, 3, e8, m1, ta, ma
    vadd.vi v4, v4, 1
    vsetivli x0, 4, e8, m1, tu, mu
    vse8.v v4, (x10)            # 0x1030: 00 00 0b 0a; this core keeps agnostic tails.
    wfi
