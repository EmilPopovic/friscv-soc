// Copyright 2026 FER, HPC Architecture and Application Research Center
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
//
// Licensed under the Solderpad Hardware License v 2.1 (the "License");
// you may not use this file except in compliance with the License, or,
// at your option, the Apache License version 2.0.
// You may obtain a copy of the License at
//
//     https://solderpad.org/licenses/SHL-2.1/
//
// Unless required by applicable law or agreed to in writing, any work
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

/*
Version history:

v 0.1.0     Mario Kovac, 2022, Initial design 
v 0.2.0     Matej Grzunov, Duje Strunje, 2022_06, pipeline debug, ALU debug,
              initial instruction set
v 0.5.0     Mario Kovac, 2024_05, memory debug & update, system update
v 0.9.0     Petra Kelkovic, Luka Kokic, 2024_06, cpu & system verification, external debug
              interface, PC & ARM SW, External IO board connections
v 1.0.0     Mario Kovac, 2025_02, some signals renaming, if update, v1.0.0 official
v 1.1.0     Franko Ciric, Karlo Milicic Juhas, 2025_06, HW and SW support for some peripherals
              on Embedded Artists LPCXpresso Base Board, toolkit for use of C
v 1.2.0     Leonel Maguitman, 2025_12, use of external DRAM throught Arm interface
v 2.0.0     Emil Popovic, Franko Ciric, 2026_03, AXI interface, combinatorial control unit,
              automation scripts, A extension, external timer interrupt
v 2.1.0     Emil Popovic, 2026_05, MMU, certification tests, boots os, modular interface
v 2.1.1     Emil Popovic, 2026_05, cleanup, Linux build and boot
v 2.2.0     Emil Popovic, 2026_05, file cleanup, reorganization, docs update
v 2.3.0     Borna Janezic, Emil Popovic 2026_06, new gpio, qspi, prepare for public release

*/

/*
 * This package defines common types, parameters and constants used throughout the FRISC-V design.
 * It should be imported in all modules to ensure consistent definitions.
 * Do not put any module definitions in this package, only types and parameters.
 */

package friscv_pkg;

localparam int unsigned ADDR_WIDTH = 32;
localparam int unsigned DATA_WIDTH = 32;

typedef logic [ADDR_WIDTH-1:0] addr_t;
typedef logic [DATA_WIDTH-1:0] data_t;

typedef enum logic [2:0] {
    WIDTH_I8  = 3'b000,
    WIDTH_U8  = 3'b100,
    WIDTH_I16 = 3'b001,
    WIDTH_U16 = 3'b101,
    WIDTH_I32 = 3'b010
} mem_width_e;

// Bit [1] is read enable, bit [0] is write enable
// 00 = no access, 01 = write, 10 = read, 11 is invalid
typedef enum logic [1:0] {
    RW_IDLE  = 2'b00,
    RW_WRITE = 2'b01,
    RW_READ  = 2'b10
} rw_cmd_e;

// Do not change to 64 yet, the core is still not parametrized everywhere correctly
localparam int unsigned XLEN = 32;

localparam int unsigned REG_SEL_WIDTH = 5;

localparam int unsigned NOP = 32'h00000013;  // addi x0,x0,0

typedef logic [31:0]              inst_t;
typedef logic [REG_SEL_WIDTH-1:0] reg_addr_t;

localparam addr_t END_ADDRESS     = 32'h50000000;  // FRISC convention

// Keep this in the same order as in the spec for easier reference
typedef enum logic [11:0] {
    CSR_ZERO = 12'h000,  // This is not a real CSR, indicates no CSR access in the control logic

    // Supervisor Trap Setup
    CSR_SSTATUS    = 12'h100,
    CSR_SCOUNTEREN = 12'h106,
    CSR_SIE        = 12'h104,
    CSR_STVEC      = 12'h105,
    CSR_SENVCFG    = 12'h10A,

    // Supervisor Trap Handling
    CSR_SSCRATCH   = 12'h140,
    CSR_SEPC       = 12'h141,
    CSR_SCAUSE     = 12'h142,
    CSR_STVAL      = 12'h143,
    CSR_SIP        = 12'h144,

    // Supervisor Timer (Sstc)
    CSR_STIMECMP   = 12'h14D,
    CSR_STIMECMPH  = 12'h15D,

    // Supervisor Protection and Translation
    CSR_SATP       = 12'h180,

    // Machine Information Registers
    CSR_MVENDORID  = 12'hF11,
    CSR_MARCHID    = 12'hF12,
    CSR_MIMPID     = 12'hF13,
    CSR_MHARTID    = 12'hF14,
    CSR_MCONFIGPTR = 12'hF15,

    // Machine Trap Setup
    CSR_MSTATUS    = 12'h300,
    CSR_MISA       = 12'h301,
    CSR_MEDELEG    = 12'h302,
    CSR_MIDELEG    = 12'h303,
    CSR_MIE        = 12'h304,
    CSR_MTVEC      = 12'h305,
    CSR_MCOUNTEREN = 12'h306,
    CSR_MSTATUSH   = 12'h310,
    CSR_MENVCFG    = 12'h30A,
    CSR_MENVCFGH   = 12'h31A,

    // Machine Trap Handling
    CSR_MSCRATCH = 12'h340,
    CSR_MEPC     = 12'h341,
    CSR_MCAUSE   = 12'h342,
    CSR_MTVAL    = 12'h343,
    CSR_MIP      = 12'h344,

    // Machine Memory Protection
    CSR_PMPCFG0   = 12'h3A0,
    CSR_PMPADDR0  = 12'h3B0,

    // Core Debug Registers
    CSR_DCSR      = 12'h7B0,
    CSR_DPC       = 12'h7B1,
    CSR_DSCRATCH0 = 12'h7B2,
    CSR_DSCRATCH1 = 12'h7B3,

    // Machine Counter/Timers
    CSR_MCYCLE    = 12'hB00,
    CSR_MINSTRET  = 12'hB02,
    CSR_MCYCLEH   = 12'hB80,
    CSR_MINSTRETH = 12'hB82,

    // Machine Counter Setup
    CSR_MCOUNTINHIBIT = 12'h320,

    // User/Supervisor Counter/Timers
    CSR_CYCLE     = 12'hC00,
    CSR_TIME      = 12'hC01,
    CSR_INSTRET   = 12'hC02,
    CSR_CYCLEH    = 12'hC80,
    CSR_TIMEH     = 12'hC81,
    CSR_INSTRETH  = 12'hC82
} csr_addr_e;

typedef logic [63:0] mtime_t;

typedef enum logic [1:0] {
    PMP_OFF   = 2'b00,  // Null region (disabled)
    PMP_TOR   = 2'b01,  // Top of range
    PMP_NA4   = 2'b10,  // Naturally aligned four-byte region
    PMP_NAPOT = 2'b11   // Naturally aligned power-of-two region, >= 8 bytes
} pmp_mode_e;

typedef struct packed {
    logic       l;
    pmp_mode_e  a;
    logic       x;
    logic       w;
    logic       r;
} pmp_cfg_t;

typedef struct packed {
    pmp_cfg_t cfg;
    addr_t    addr;
} pmp_entry_t;

// Do not change mappings, these are per-spec and directly used in decode
typedef enum logic [1:0] {
    U_MODE = 2'b00,
    S_MODE = 2'b01,
    H_MODE = 2'b10,
    M_MODE = 2'b11
} mode_e;

typedef struct packed {
    logic        sd;          // [31]    State Dirty (RO, OR of FS/XS/VS)
    logic [7:0]  wpri_30_23;  // [30:23] Reserved (WPRI)
    logic        tsr;         // [22]    Trap SRET (WPRI)
    logic        tw;          // [21]    Timeout Wait (WPRI)
    logic        tvm;         // [20]    Trap Virtual Memory
    logic        mxr;         // [19]    Make eXecutable Readable
    logic        sum;         // [18]    Supervisor User Memory access
    logic        mprv;        // [17]    Modify PRiVilege
    logic [1:0]  xs;          // [16:15] eXtension Status (WPRI)
    logic [1:0]  fs;          // [14:13] Floating-point Status (WPRI)
    mode_e       mpp;         // [12:11] M Previous Privilege
    logic [1:0]  vs;          // [10:9]  Vector Status (WPRI)
    logic        spp;         // [8]     S Previous Privilege
    logic        mpie;        // [7]     M Previous Interrupt Enable
    logic        ube;         // [6]     U Big-Endian (WPRI)
    logic        spie;        // [5]     S Previous Interrupt Enable
    logic        wpri_4;      // [4]     Reserved (WPRI)
    logic        mie;         // [3]     M Interrupt Enable
    logic        wpri_2;      // [2]     Reserved (WPRI)
    logic        sie;         // [1]     S Interrupt Enable
    logic        wpri_0;      // [0]     Reserved (WPRI)
} mstatus_t;

// Parametrization of the MMU for 32-bit and 64-bit modes
localparam int unsigned SATP_MODE_W = (XLEN == 32) ? 1  : 4;
localparam int unsigned SATP_ASID_W = (XLEN == 32) ? 9  : 16;
localparam int unsigned PTE_LEVEL_W = (XLEN == 32) ? 1  : 3;
localparam int unsigned VPN_W       = (XLEN == 32) ? 20 : 27;
localparam int unsigned PPN_W       = (XLEN == 32) ? 22 : 44;
localparam int unsigned PA_PPN_W    = ADDR_WIDTH - 12;

// Never use bare widths in the code
// Always use these typedefs to ensure correct generation in both modes
typedef logic [SATP_MODE_W-1:0] satp_mode_t;
typedef logic [SATP_ASID_W-1:0] asid_t;
typedef logic [PTE_LEVEL_W-1:0] pte_level_t;
typedef logic [VPN_W-1:0]       vpn_t;
typedef logic [PPN_W-1:0]       ppn_t;

// Do not change mappings, these are per-spec and directly used in decode
typedef enum logic [3:0] { 
    SATP_BARE = 4'd0,
    SATP_SV32 = 4'd1,
    SATP_SV39 = 4'd8,
    SATP_SV48 = 4'd9,
    SATP_SV57 = 4'd10
} satp_mode_e;

// Types of exceptions generated in the EX stage
typedef enum logic {
    EX_TRAP_NONE,
    EX_TRAP_MISALIGNED
} ex_trap_e;

// Types of memory traps generated in the MEM stage
typedef enum logic [2:0] {
    MEM_TRAP_NONE,
    MEM_TRAP_LOAD,
    MEM_TRAP_STORE,
    MEM_TRAP_LOAD_MISALIGNED,
    MEM_TRAP_STORE_MISALIGNED,
    MEM_TRAP_LOAD_ACCESS,
    MEM_TRAP_STORE_ACCESS
} mem_trap_e;

// Fields of the SATP register, using XLEN-parametrized widths
typedef struct packed {
    satp_mode_t mode;
    asid_t      asid;
    ppn_t       ppn;
} satp_t;

// The MMU request context is the information about the memory access for address translation
// and permission checks, and to generate exceptions if needed.
typedef struct packed {
    addr_t  addr;
    satp_t  satp;
    mode_e  mode;
    logic   sum;
    logic   mxr;
    logic   is_inst;
    logic   is_write;
} mmu_req_ctx_t;

// Permission bits of a page table or TLB entry.
typedef struct packed {
    logic d;  // Dirty
    logic a;  // Accessed
    logic g;  // Global
    logic u;  // User-accessible
    logic x;  // Execute
    logic w;  // Write
    logic r;  // Read
    logic v;  // Valid
} perm_t;

typedef enum logic [2:0] {
    I_TYPE,
    I2_TYPE,
    S_TYPE,
    B_TYPE,
    U_TYPE,
    J_TYPE,
    ZERO,    // Always produces 32'h0
    NEXT_PC  // Used to jump to incremented PC to refetch on FENCE.I
} imm_e;

// Instruction types, do not change mappings, keep in spec order for easier reference
typedef enum logic [6:0] {
    LOAD     = 7'b0000011,
    LOAD_FP  = 7'b0000111,
    CUSTOM_0 = 7'b0001011,
    MISC_MEM = 7'b0001111,
    OP_IMM   = 7'b0010011,
    AUIPC    = 7'b0010111,
    STORE    = 7'b0100011,
    STORE_FP = 7'b0100111,
    CUSTOM_1 = 7'b0101011,
    AMO      = 7'b0101111,
    OP       = 7'b0110011,
    LUI      = 7'b0110111,
    MADD     = 7'b1000011,
    MSUB     = 7'b1000111,
    NMSUB    = 7'b1001011,
    NMADD    = 7'b1001111,
    OP_FP    = 7'b1010011,
    OP_V     = 7'b1010111,
    BRANCH   = 7'b1100011,
    JALR     = 7'b1100111,
    JAL      = 7'b1101111,
    SYSTEM   = 7'b1110011,
    OP_VE    = 7'b1110111
} opcode_e;

// R-type instruction format, used for decoding R-type instructions from inst_t type signals
typedef struct packed {
    logic [6:0] funct7;
    reg_addr_t  rs2;
    reg_addr_t  rs1;
    logic [2:0] funct3;
    reg_addr_t  rd;
    opcode_e    opcode;
} r_type_t;

// Represents an instruction, provides raw bits and R-type fields
typedef union packed {
    inst_t   b;
    r_type_t r;
} instr_op_t;

typedef struct packed {
    logic [3:0] debugver;        // [31:28] Debug Version, supported 1.0
    logic       reserved_27;     // [27] Read-only 0
    logic [2:0] extcause;        // [26:24]
    logic [3:0] reserved_23_20;  // [23:20] Read-only 0
    logic       cetrig;          // [19] Critical error trigger, read-only 0
    logic       pelp;            // [18] No landing pad, read-only 0
    logic       ebreakvs;        // [17] No VS, read-only 0
    logic       ebreakvu;        // [16] No VU, read-only 0
    logic       ebreakm;         // [15] ebreak enters debug mode in M-mode
    logic       reserved_14;     // [14] Read-only 0
    logic       ebreaks;         // [13] ebreak enters debug mode in S-mode
    logic       ebreaku;         // [12] ebreak enters debug mode in U-mode
    logic       stepie;          // [11] Step interrupt enable, read-only 0
    logic       stopcount;       // [10] Stop counting in debug mode
    logic       stoptime;        // [9]  Stop time in debug mode, read-only 0
    logic [2:0] cause;           // [8:6] Why debug mode was entered
    logic       v;               // [5]  Previous virtualization, read-only 0
    logic       mprven;          // [4]  mprv takes effect in debug mode, read-only 0
    logic       nmip;            // [3]  Non-maskable interrupt pending
    logic       step;            // [2]  Step mode
    mode_e      prv;             // [1:0] Privilege before entering debug mode
} dcsr_t;

// Types of redirects
typedef enum logic [1:0] {
    BRANCH_JAL_NONE,
    BRANCH_INSTR,
    JAL_INSTR
} jump_sel_e;

// Types of branch conditions, do not change mappings
typedef enum logic [2:0] {
    COND_EQ     = 3'b000,
    COND_NE     = 3'b001,
    COND_ALWAYS = 3'b010,
    COND_LT     = 3'b100,
    COND_GE     = 3'b101,
    COND_LTU    = 3'b110,
    COND_GEU    = 3'b111
} branch_cond_e;

// Choose the first operand for the ALU
typedef enum logic [1:0] {
    RS1, ZERO_A, PC, RS1_SEL
} a_bus_sel_e;

// Choose the second operand for the ALU
typedef enum logic [1:0] {
    RS2, IMM, CSR
} b_bus_sel_e;

// Arithmetic and logic operations, do not change mappings
typedef enum logic [4:0] {
    ADD_OP    = 5'b00000,
    SUB_OP    = 5'b01000,
    AND_OP    = 5'b00111,
    OR_OP     = 5'b00110,
    XOR_OP    = 5'b00100,
    SLL_OP    = 5'b00001,
    SRL_OP    = 5'b00101,
    SRA_OP    = 5'b01101,
    SLT_OP    = 5'b00010,
    SLTU_OP   = 5'b00011,
    MUL_OP    = 5'b01001,
    MULH_OP   = 5'b01010,
    MULHU_OP  = 5'b01011,
    MULHSU_OP = 5'b01100,
    DIV_OP    = 5'b01110,
    DIVU_OP   = 5'b01111,
    REM_OP    = 5'b10000,
    REMU_OP   = 5'b10001
} alu_op_e;

// AMO operation types
typedef enum logic [3:0] {
    AMO_NONE,
    AMO_SWAP,
    AMO_ADD,
    AMO_XOR,
    AMO_AND,
    AMO_OR,
    AMO_MIN,
    AMO_MAX,
    AMO_MINU,
    AMO_MAXU
} amo_op_e;

// Choose if MEM should load, store or do nothing.
typedef enum logic [1:0] {
    MEM_INSTR_NONE  = 2'b00,
    MEM_INSTR_LOAD  = 2'b01,
    MEM_INSTR_STORE = 2'b10
} mem_instr_sel_e;

// Choose what data should be written back to the register file.
typedef enum logic [2:0] {
    WB_DATA_SEL_PC_PLUS_4,
    WB_DATA_SEL_ALU,
    WB_DATA_SEL_MEM,
    WB_DATA_SEL_SC_RES,
    WB_DATA_SEL_CSR
} wb_data_sel_e;

// Control signals generated by ID and used in EX, MEM and WB stages.
// This is the main output of the decoder.
typedef struct packed {
    logic           instr_valid;
    jump_sel_e      branch_jal_sel;
    branch_cond_e   branch_cond;
    logic           jalr_target;
    a_bus_sel_e     a_bus_sel;
    b_bus_sel_e     b_bus_sel;
    alu_op_e        alu_op;
    logic           invert_op_a;
    mem_instr_sel_e mem_instr_sel;
    mem_width_e     load_store_width;
    wb_data_sel_e   wb_data_sel;
    logic           reserve;
    logic           conditional;
    amo_op_e        amo_op;
    logic           csr_op;
    logic           mret_en;
    logic           sret_en;
    csr_addr_e      csr_addr;
    logic           csr_is_serializing;
    logic           csr_is_counter;
    logic           sfence_vma;
} instr_ex_t;

// A NOP instruction with all control signals set to safe values.
// Use this to insert bubbles in the pipeline when needed.
localparam instr_ex_t NOP_CTRL = '{
    instr_valid: 1'b0,
    branch_jal_sel: BRANCH_JAL_NONE,
    branch_cond: COND_NE,
    jalr_target: 1'b0,
    a_bus_sel: RS1,
    b_bus_sel: RS2,
    alu_op: ADD_OP,
    invert_op_a: 1'b0,
    mem_instr_sel: MEM_INSTR_NONE,
    load_store_width: WIDTH_I32,
    wb_data_sel: WB_DATA_SEL_ALU,
    reserve: 1'b0,
    conditional: 1'b0,
    amo_op: AMO_NONE,
    csr_op: 1'b0,
    mret_en: 1'b0,   
    sret_en: 1'b0,
    csr_addr: CSR_ZERO,
    csr_is_serializing: 1'b0,
    csr_is_counter: 1'b0,
    sfence_vma: 1'b0
};

endpackage
