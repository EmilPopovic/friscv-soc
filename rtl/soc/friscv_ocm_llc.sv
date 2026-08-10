// Copyright 2026 FER, HPC Architecture and Application Research Center
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
//
// Licensed under the Solderpad Hardware License v 2.1 (the "License");
// you may not use this file except in compliance with the License, or,
// at your option, the Apache License version 2.0.
// You may obtain a copy of the License at https://solderpad.org/licenses/SHL-2.1/

module friscv_ocm_llc import friscv_mem_pkg::*; #(
    parameter  int unsigned OCM_BASE    = 32'h0000_0000,
    parameter  int unsigned REGION_BASE = 32'h8000_0000,
    parameter  int unsigned REGION_LOG2 = 25,  // 32MB
    parameter  int unsigned LINE_BYTES  = 64,
    parameter  int unsigned WAYS        = 4,
    parameter  int unsigned SIZE_BYTES  = 16*1024,
    parameter  bit          SRAM_TAGS   = 1'b1,
    localparam int unsigned SETS        = SIZE_BYTES / (LINE_BYTES * WAYS),
    localparam int unsigned OFFSET_W    = $clog2(LINE_BYTES),
    localparam int unsigned IDX_W       = $clog2(SETS),
    localparam int unsigned TAG_W       = REGION_LOG2 - OFFSET_W - IDX_W,
    localparam int unsigned LINE_WORDS  = LINE_BYTES / 4,
    localparam int unsigned BEAT_W      = $clog2(LINE_WORDS),
    localparam int unsigned WAY_SEL_W   = $clog2(WAYS),
    localparam int unsigned WAY_WORDS   = SIZE_BYTES / WAYS / 4,
    localparam int unsigned WAY_ADDR_W  = $clog2(WAY_WORDS)
) (
    input  logic            i_clk,
    input  logic            i_rstn,
    input  logic [WAYS-1:0] i_way_is_cache,  // 1 = this way is cache, 0 = this way is OCM
    input  logic            i_crpsel,        // 0 = round-robin, 1 = random
    input  logic            i_llcinv,        // pulse to invalidate every way

    friscv_mem_if.slave     s_mem_if,  // From the hub: OCM region and cacheable region
    friscv_mem_if.master    m_mem_if   // To external memory
);

// ============================================================
// Parameter checks
// ============================================================

if (SIZE_BYTES != SETS * LINE_BYTES * WAYS) begin : gen_chk_size
    $error("SIZE_BYTES (%0d) must equal SETS * LINE_BYTES * WAYS", SIZE_BYTES);
end
if (LINE_BYTES != (1 << OFFSET_W)) begin : gen_chk_line
    $error("LINE_BYTES (%0d) must be a power of two", LINE_BYTES);
end
if (SETS != (1 << IDX_W)) begin : gen_chk_sets
    $error("SETS (%0d) must be a power of two", SETS);
end
if (WAYS < 2 || WAYS != (1 << WAY_SEL_W)) begin : gen_chk_ways
    $error("WAYS (%0d) must be a power of two, at least 2", WAYS);
end
if (IDX_W + BEAT_W != WAY_ADDR_W) begin : gen_chk_split
    $error("the OCM and cache address splits disagree");
end
if (REGION_LOG2 <= OFFSET_W + IDX_W) begin : gen_chk_tag
    $error("REGION_LOG2 (%0d) leaves no tag bits", REGION_LOG2);
end

// ============================================================
// Convert to memory interface
// ============================================================

logic        w_req, w_gnt, w_we, w_rvalid, w_err;
logic [31:0] w_addr, w_wdata, w_rdata;
logic [3:0]  w_be;

// An access to the OCM region is illegal if the selected way is configured as cache
logic w_illegal_ocm_access;

friscv_to_mem #(
    .REGISTER_REQ ( 1 )
) to_mem (
    .i_clk       ( i_clk    ),
    .i_rstn      ( i_rstn   ),
    .req_o       ( w_req    ),
    .addr_o      ( w_addr   ),
    .we_o        ( w_we     ),
    .wdata_o     ( w_wdata  ),
    .be_o        ( w_be     ),
    .gnt_i       ( w_gnt    ),
    .rvalid_i    ( w_rvalid ),
    .err_i       ( w_err    ),
    .other_err_i ( 1'b0     ),
    .rdata_i     ( w_rdata  ),
    .mem_if      ( s_mem_if )
);

// ============================================================
// Address decode
// ============================================================

logic w_match_cached, w_match_ocm;
assign w_match_cached = (w_addr - addr_t'(REGION_BASE)) < (addr_t'(1) << REGION_LOG2);
assign w_match_ocm    = (w_addr - addr_t'(OCM_BASE)) < addr_t'(SIZE_BYTES);

// If regions overlap, OCM takes priority
logic w_sel_ocm, w_sel_cached;
assign w_sel_ocm    = w_match_ocm;
assign w_sel_cached = w_match_cached && !w_sel_ocm;

// ============================================================
// SRAM blocks
// ============================================================

logic [WAYS-1:0]       w_way_req, w_way_we;
logic [WAYS-1:0][31:0] w_way_wdata, w_way_rdata;
logic [WAYS-1:0][3:0]  w_way_be;
logic [WAYS-1:0][WAY_ADDR_W-1:0] w_way_addr;

for (genvar i = 0; i < WAYS; i++) begin : gen_ways
    tc_sram #(
        .NumWords ( WAY_WORDS ),
        .DataWidth( 32        ),
        .ByteWidth( 8         ),
        .NumPorts ( 1         ),
        .Latency  ( 1         )
    ) way_sram (
        .clk_i   ( i_clk          ),
        .rst_ni  ( i_rstn         ),
        .req_i   ( w_way_req  [i] ),
        .we_i    ( w_way_we   [i] ),
        .addr_i  ( w_way_addr [i] ),
        .wdata_i ( w_way_wdata[i] ),
        .be_i    ( w_way_be   [i] ),
        .rdata_o ( w_way_rdata[i] )
    );
end

// ============================================================
// Invalidate
// ============================================================

logic [WAYS-1:0] r_mode, w_mode_changed;
assign w_mode_changed = i_way_is_cache ^ r_mode;

always_ff @(posedge i_clk) begin
    if (!i_rstn) r_mode <= '0;
    else         r_mode <= i_way_is_cache;
end

logic [WAYS-1:0] w_inv_ways;
logic            w_inv;
assign w_inv_ways = i_llcinv ? {WAYS{1'b1}} : w_mode_changed;
assign w_inv      = |w_inv_ways;

// ============================================================
// LLC mode
// ============================================================

typedef enum logic [2:0] {
    S_LLC_IDLE,    // OCM completes here, and the first lookup is issued from here
    S_LLC_LOOKUP,  // the tag compare issued last cycle is ready
    S_LLC_FWD,     // single-beat pass-through to external memory
    S_LLC_REFILL,  // line burst, each beat written into the victim way
    S_LLC_REPLAY   // re-issue the way read after a refill, then look up again
} llc_state_e;

llc_state_e r_state, w_next_state;

logic w_hit;         // the lookup registered in S_LLC_LOOKUP hit
logic w_dn_done;     // the external request completes this cycle
logic w_refill_err;  // some beat of the current refill reported an error

logic w_cache_enabled;
assign w_cache_enabled = |i_way_is_cache;  // Cache is enabled if any way is configured as cache

logic w_is_lookup;
assign w_is_lookup = w_sel_cached && w_cache_enabled;

always_comb begin
    w_next_state = r_state;
    case (r_state)
        S_LLC_IDLE: begin
            if (w_req && !w_sel_ocm && !w_inv)
                w_next_state = w_is_lookup ? S_LLC_LOOKUP : S_LLC_FWD;
        end
        S_LLC_LOOKUP: begin
            if      (w_we)  w_next_state = S_LLC_FWD;     // write-through
            else if (w_hit) w_next_state = S_LLC_IDLE;    // read hit, served from cache
            else            w_next_state = S_LLC_REFILL;
        end
        S_LLC_FWD: begin
            if (w_dn_done) w_next_state = S_LLC_IDLE;
        end
        S_LLC_REFILL: begin
            if (w_dn_done) w_next_state = w_refill_err ? S_LLC_IDLE : S_LLC_REPLAY;
        end
        S_LLC_REPLAY: begin
            w_next_state = S_LLC_LOOKUP;
        end
        default: w_next_state = S_LLC_IDLE;
    endcase
end

always_ff @(posedge i_clk) begin
    if (!i_rstn) r_state <= S_LLC_IDLE;
    else         r_state <= w_next_state;
end

// A tag compare and a parallel read of every cache way are issued this cycle
logic w_lookup_en;
assign w_lookup_en = !w_inv && ((r_state == S_LLC_IDLE && w_req && w_is_lookup) || (r_state == S_LLC_REPLAY));

// Split address into tag, index, and offset
logic [OFFSET_W-1:0] w_offset;
logic [IDX_W-1:0]    w_idx;
logic [TAG_W-1:0]    w_tag;
assign {w_tag, w_idx, w_offset} = w_addr[REGION_LOG2-1:0];

// Line selection
logic [WAY_ADDR_W-1:0] w_lookup_addr;
assign w_lookup_addr = {w_idx, w_offset[OFFSET_W-1:2]};  // 32-bit word address within line

logic [WAYS-1:0][SETS-1:0] r_valid_arr;

logic [WAY_SEL_W-1:0] w_victim, r_victim;

// The refill writes the tag and validates the line
logic w_alloc;
assign w_alloc = (r_state == S_LLC_REFILL) && w_dn_done && !w_refill_err;

logic [WAYS-1:0] w_hit_arr, r_hit_arr;

// Cache hit if any way matches
assign w_hit = |w_hit_arr;

if (SRAM_TAGS) begin : gen_tag_sram
    localparam int unsigned TAG_MEM_W = WAYS * TAG_W;

    logic [TAG_MEM_W-1:0] w_tag_rdata;
    logic [WAYS-1:0]      w_tag_be;

    for (genvar i = 0; i < WAYS; i++) begin : gen_tag_be
        assign w_tag_be[i] = (r_victim == WAY_SEL_W'(unsigned'(i)));
    end

    tc_sram #(
        .NumWords  ( SETS      ),
        .DataWidth ( TAG_MEM_W ),
        .ByteWidth ( TAG_W     ),
        .NumPorts  ( 1         ),
        .Latency   ( 1         )
    ) tag_sram (
        .clk_i   ( i_clk                  ),
        .rst_ni  ( i_rstn                 ),
        .req_i   ( w_lookup_en || w_alloc ),
        .we_i    ( w_alloc                ),
        .addr_i  ( w_idx                  ),
        .wdata_i ( {WAYS{w_tag}}          ),
        .be_i    ( w_tag_be               ),
        .rdata_o ( w_tag_rdata            )
    );

    for (genvar i = 0; i < WAYS; i++) begin : gen_hit_arr
        assign w_hit_arr[i] = i_way_is_cache[i] && r_valid_arr[i][w_idx] &&
                              (w_tag_rdata[i*TAG_W +: TAG_W] == w_tag);
    end

    always_ff @(posedge i_clk) begin
        if (!i_rstn)                      r_hit_arr <= '0;
        else if (r_state == S_LLC_LOOKUP) r_hit_arr <= w_hit_arr;
    end

end else begin : gen_tag_flops
    logic [WAYS-1:0][SETS-1:0][TAG_W-1:0] r_tag_arr;
    logic [WAYS-1:0]                      w_hit_arr_d;

    for (genvar i = 0; i < WAYS; i++) begin : gen_hit_arr
        assign w_hit_arr_d[i] = i_way_is_cache[i] && r_valid_arr[i][w_idx] &&
                                (r_tag_arr[i][w_idx] == w_tag);
    end

    // r_hit_arr behaves like the SRAM output
    always_ff @(posedge i_clk) begin
        if (!i_rstn)          r_hit_arr <= '0;
        else if (w_lookup_en) r_hit_arr <= w_hit_arr_d;
    end

    assign w_hit_arr = r_hit_arr;

    always_ff @(posedge i_clk) begin
        if (!i_rstn)      r_tag_arr <= '0;
        else if (w_alloc) r_tag_arr[r_victim][w_idx] <= w_tag;
    end
end

// ============================================================
// Replacement policy
// ============================================================

// Random replacement

localparam int unsigned LFSR_W    = 32;
localparam int unsigned LFSR_POLY = 32'h8020_0003;

logic [LFSR_W-1:0] r_lfsr;  // for random replacement

logic w_lfsr_next;
assign w_lfsr_next = ~^(r_lfsr & LFSR_POLY);

always_ff @(posedge i_clk) begin
    if (!i_rstn) r_lfsr <= '0;
    else         r_lfsr <= {r_lfsr[LFSR_W-2:0], w_lfsr_next};
end

// Round-robin replacement

logic [SETS-1:0][WAY_SEL_W-1:0] r_rr_ptr;  // round-robin pointer for each set

// Both policies only nominate a starting index, the selection below rotates from it
// over the eligible ways so neither policy can land on a way that is OCM
logic [WAY_SEL_W-1:0] w_start;
assign w_start = i_crpsel ? r_lfsr[WAY_SEL_W-1:0] : r_rr_ptr[w_idx];

always_comb begin
    w_victim = '0;
    // Lowest priority: wrap round to an eligible way below the starting index
    for (int unsigned i = WAYS; i > 0; i--) begin
        if (i_way_is_cache[i-1] && WAY_SEL_W'(i-1) < w_start)
            w_victim = WAY_SEL_W'(i-1);
    end
    // Then the first eligible way at or above the starting index
    for (int unsigned i = WAYS; i > 0; i--) begin
        if (i_way_is_cache[i-1] && WAY_SEL_W'(i-1) >= w_start)
            w_victim = WAY_SEL_W'(i-1);
    end
    // Highest priority: an eligible way that holds nothing yet
    for (int unsigned i = WAYS; i > 0; i--) begin
        if (i_way_is_cache[i-1] && !r_valid_arr[i-1][w_idx])
            w_victim = WAY_SEL_W'(i-1);
    end
end

always_ff @(posedge i_clk) begin
    if (!i_rstn) begin
        r_rr_ptr <= '0;
    end else if (r_state == S_LLC_REFILL && w_dn_done && !w_refill_err) begin
        r_rr_ptr[w_idx] <= r_victim + 1'b1;  // next way in round-robin order
    end
end

always_ff @(posedge i_clk) begin
    if (!i_rstn) begin
        r_valid_arr <= '0;
    end else if (w_inv) begin
        for (int unsigned i = 0; i < WAYS; i++) begin
            if (w_inv_ways[i]) r_valid_arr[i] <= '0;  // every set of that way, one cycle
        end
    end else if (w_alloc) begin
        r_valid_arr[r_victim][w_idx] <= 1'b1;
    end
end

// ============================================================
// Refill
// ============================================================

logic [BEAT_W-1:0] r_beat;
logic              r_refill_err;

assign w_refill_err = (r_state == S_LLC_REFILL) && (r_refill_err || m_mem_if.err);

always_ff @(posedge i_clk) begin
    if (!i_rstn) begin
        r_beat       <= '0;
        r_refill_err <= 1'b0;
        r_victim     <= '0;
    end else if (r_state == S_LLC_LOOKUP && !w_hit && !w_we) begin
        // Freeze the victim before the burst starts
        r_beat       <= '0;
        r_refill_err <= 1'b0;
        r_victim     <= w_victim;
    end else if (r_state == S_LLC_REFILL) begin
        if (m_mem_if.beat_valid) r_beat <= r_beat + 1'b1;
        if (m_mem_if.err)        r_refill_err <= 1'b1;
    end
end

// ============================================================
// Downstream path
// ============================================================

logic w_dn_req;
assign w_dn_req  = (r_state == S_LLC_FWD) || (r_state == S_LLC_REFILL);
assign w_dn_done = w_dn_req && !m_mem_if.wait_req;

always_comb begin
    m_mem_if.addr     = w_addr;
    m_mem_if.size     = s_mem_if.size;
    m_mem_if.wdata    = w_wdata;
    m_mem_if.rw       = RW_IDLE;
    m_mem_if.burst_en = 1'b0;

    if (r_state == S_LLC_REFILL) begin
        m_mem_if.addr     = {w_addr[31:OFFSET_W], {OFFSET_W{1'b0}}};
        m_mem_if.size     = WIDTH_I32;
        m_mem_if.wdata    = '0;
        m_mem_if.rw       = RW_READ;
        m_mem_if.burst_en = 1'b1;
    end else if (r_state == S_LLC_FWD) begin
        m_mem_if.rw       = w_we ? RW_WRITE : RW_READ;
    end
end

// ============================================================
// Request completion
// ============================================================

always_comb begin
    case (r_state)
        S_LLC_IDLE:   w_gnt = w_req && w_sel_ocm && !w_inv;  // the SRAM answers immediately
        S_LLC_LOOKUP: w_gnt = w_hit && !w_we;                // read hit
        S_LLC_FWD:    w_gnt = w_dn_done;
        S_LLC_REFILL: w_gnt = w_dn_done && w_refill_err;     // a failed refill ends the access
        S_LLC_REPLAY: w_gnt = 1'b0;
        default:      w_gnt = 1'b0;
    endcase
end

data_t w_hit_rdata;
always_comb begin
    w_hit_rdata = '0;
    for (int unsigned i = 0; i < WAYS; i++) begin
        if (w_hit_arr[i]) w_hit_rdata = w_way_rdata[i];
    end
end

data_t r_rsp_rdata;
logic  r_rsp_sel;

always_ff @(posedge i_clk) begin
    if (!i_rstn) begin
        w_rvalid    <= 1'b0;
        w_err       <= 1'b0;
        r_rsp_sel   <= 1'b0;
        r_rsp_rdata <= '0;
    end else begin
        w_rvalid <= w_req && w_gnt;
        if (w_req && w_gnt) begin
            r_rsp_sel   <= r_state != S_LLC_IDLE;
            r_rsp_rdata <= (r_state == S_LLC_LOOKUP) ? w_hit_rdata : m_mem_if.rdata;
            w_err       <= (r_state == S_LLC_IDLE) ? w_illegal_ocm_access :
                           (r_state == S_LLC_FWD)  ? m_mem_if.err : w_refill_err;
        end
    end
end

// ============================================================
// SRAM read/write
// ============================================================

logic [WAY_ADDR_W-1:0] w_ocm_addr;
logic [WAY_SEL_W-1:0]  w_ocm_way_sel;

// Full OCM address is [X, WAY_SEL, WAY_ADDR, BYTE_SEL], where BYTE_SEL is 2 bits for 32-bit address
assign w_ocm_addr    = w_addr[WAY_ADDR_W+1:2];
assign w_ocm_way_sel = w_addr[WAY_ADDR_W+WAY_SEL_W+1:WAY_ADDR_W+2];

assign w_illegal_ocm_access = w_sel_ocm && i_way_is_cache[w_ocm_way_sel];

// A write hit updates the line in place only once the external write has been accepted
logic w_write_hit;
assign w_write_hit = (r_state == S_LLC_FWD) && w_we && w_sel_cached &&
                     w_dn_done && !m_mem_if.err;

always_comb begin
    for (int unsigned i = 0; i < WAYS; i++) begin
        w_way_req  [i] = 1'b0;
        w_way_addr [i] = '0;
        w_way_we   [i] = 1'b0;
        w_way_wdata[i] = '0;
        w_way_be   [i] = '0;

        if (i_way_is_cache[i]) begin
            if (r_state == S_LLC_REFILL) begin
                if (r_victim == WAY_SEL_W'(i) && m_mem_if.beat_valid) begin
                    w_way_req  [i] = 1'b1;
                    w_way_addr [i] = {w_idx, r_beat};
                    w_way_we   [i] = 1'b1;
                    w_way_wdata[i] = m_mem_if.rdata;
                    w_way_be   [i] = '1;
                end
            end else if (w_lookup_en) begin
                // Read every cache way in parallel with the tag lookup
                w_way_req  [i] = 1'b1;
                w_way_addr [i] = w_lookup_addr;
            end else if (w_write_hit && r_hit_arr[i]) begin
                // Write-through to the hit way
                w_way_req  [i] = 1'b1;
                w_way_addr [i] = w_lookup_addr;
                w_way_we   [i] = 1'b1;
                w_way_wdata[i] = w_wdata;
                w_way_be   [i] = w_be;
            end
        end else begin
            if (w_ocm_way_sel == WAY_SEL_W'(i) && w_req && w_sel_ocm) begin
                // OCM access
                w_way_req  [i] = 1'b1;
                w_way_addr [i] = w_ocm_addr;
                w_way_we   [i] = w_we;
                w_way_wdata[i] = w_wdata;
                w_way_be   [i] = w_be;
            end
        end
    end
end

always_comb begin
    if (r_rsp_sel) begin
        w_rdata = r_rsp_rdata;
    end else begin
        w_rdata = '0;
        for (int unsigned i = 0; i < WAYS; i++) begin
            if (!i_way_is_cache[i] && w_ocm_way_sel == WAY_SEL_W'(i) && w_sel_ocm) begin
                w_rdata = w_way_rdata[i];
            end
        end
    end
end

endmodule
