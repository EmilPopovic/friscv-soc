// Second stage, loaded into the OCM by the boot ROM. Brings up external memory,
// streams the image into RAM and enters it.
//
// Flash: this stage in the first block, then a length word, then the image.

#define SCB_HBCTL   0x40000008
#define SCB_LLCSEL  0x4000000C
#define UART0       0x10000000
#define UART_DLL    0x00
#define UART_DLM    0x04
#define UART_LCR    0x0c
#define UART_DIV    27              // 115200 baud from 50 MHz
#define SPI_STATUS  0x14
#define SPI_COMMAND 0x28
#define SPI_RXDATA  0x2c
#define SPI_TXDATA  0x30
#define RAM_BASE    0x80000000
#define BLOCK       512
#define RX_CSAAT    0x13ff          // csaat | RX | 512 bytes

    .section .text.init
    .globl _start
_start:
    // Ways stay scratchpad, this code runs from the OCM
    li      t0, SCB_HBCTL
    li      t1, 1
    sw      t1, 0(t0)

    // the apheleiaOS stub expects the divisor set
    li      t0, UART0
    li      t1, 0x80
    sw      t1, UART_LCR(t0)
    li      t1, UART_DIV
    sw      t1, UART_DLL(t0)
    sw      zero, UART_DLM(t0)
    li      t1, 0x03
    sw      t1, UART_LCR(t0)

    lui     t0, 0x60000

    // fresh read, the ROM released CS: 03 00 02 00 LSB first, address 0x200
    li      t1, 0x00020003
    sw      t1, SPI_TXDATA(t0)
    li      t1, 0x2203              // csaat | TX | 4 bytes
    sw      t1, SPI_COMMAND(t0)

    li      t1, RX_CSAAT
    sw      t1, SPI_COMMAND(t0)
    jal     rx_word
    mv      s0, a0                  // bytes still to move
    li      s1, BLOCK - 4           // words left in this block
    srli    s1, s1, 2
    li      a1, RAM_BASE

copy:
    beqz    s1, next_block
1:  jal     rx_word
    sw      a0, 0(a1)
    addi    a1, a1, 4
    addi    s0, s0, -4
    addi    s1, s1, -1
    blez    s0, done
    bnez    s1, 1b

next_block:
    li      t1, RX_CSAAT
    sw      t1, SPI_COMMAND(t0)
    li      s1, BLOCK/4
    j       copy

    // the cache cannot be enabled from the OCM, finish from RAM
done:
    mv      s0, a1                  // just past the image
    la      a1, tramp
    la      a2, tramp_end
    mv      a3, s0
1:  lw      t1, 0(a1)
    sw      t1, 0(a3)
    addi    a1, a1, 4
    addi    a3, a3, 4
    bltu    a1, a2, 1b
    fence.i
    jr      s0

tramp:
    li      t0, SCB_LLCSEL
    li      t1, 0xf                 // every way a cache way
    sw      t1, 0(t0)
    li      t0, RAM_BASE
    jr      t0
tramp_end:

// One word out of the rx fifo
rx_word:
1:  lw      a0, SPI_STATUS(t0)
    slli    a0, a0, 7               // rxempty is bit 24
    bltz    a0, 1b
    lw      a0, SPI_RXDATA(t0)
    ret
