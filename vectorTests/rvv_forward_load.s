# Vector load-use, ALU-to-store, and store-to-load RAW chains at every EEW.
# There are no nops between dependent vector operations. Correct results test
# readiness/stalls; they do not prove a bypass in the serialized vector engine.
    li x1, 0x1100
    li x2, 0x1110
    li x3, 0x1120
    li x4, 0x1130
    li x5, 0x1140
    li x6, 0x1150
    li x7, 4
    la x8, byte_input
    la x9, half_input
    la x10, word_input

# Byte arithmetic wraps independently in each element.
    vsetvli x0, x7, e8, m1, tu, mu
    vle8.v v1, (x8)
    vadd.vi v1, v1, 1
    vadd.vv v2, v1, v1
    vse8.v v2, (x1)       # 0x1100: 0x00040200
    vle8.v v3, (x1)
    vsub.vv v4, v3, v1
    vse8.v v4, (x2)       # 0x1110: 0x80028100

# Halfword load destinations are consumed and overwritten immediately.
    vsetivli x0, 2, e16, m1, tu, mu
    vle16.v v5, (x9)
    vadd.vi v5, v5, 1
    vadd.vv v6, v5, v5
    vse16.v v6, (x3)      # 0x1120: 0x00040000
    vle16.v v7, (x3)
    vsub.vv v7, v7, v5
    vse16.v v7, (x4)      # 0x1130: 0x00020000

# Four word loads span multiple D-cache lines and use aligned m4 groups.
# A younger consumer must wait for every element, including any refill stalls.
    vsetivli x0, 4, e32, m4, tu, mu
    vle32.v v8, (x10)
    vadd.vi v12, v8, 1
    vsub.vv v12, v12, v8
    vse32.v v12, (x5)     # 0x1140..0x114c: four words 0x00000001
    vle32.v v16, (x5)
    vadd.vv v16, v16, v12
    vse32.v v16, (x6)     # 0x1150..0x115c: four words 0x00000002
    wfi

    .align 2
byte_input:
    .word 0x7f0180ff
half_input:
    .word 0x0001ffff
word_input:
    .word 0x7fffffff, 0x80000000, 0xffffffff, 0x00000000
