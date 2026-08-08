// Copyright 2026 FER, HPC Architecture and Application Research Center
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
//
// Single-port block RAM, replacing the tech_cells_generic cell in the flist.
// FRISCV_SRAM_INIT names a $readmemh file to preload.

module tc_sram #(
  parameter int unsigned NumWords    = 32'd1024,
  parameter int unsigned DataWidth   = 32'd32,
  parameter int unsigned ByteWidth   = 32'd8,
  parameter int unsigned NumPorts    = 32'd1,
  parameter int unsigned Latency     = 32'd1,
  parameter              SimInit     = "none",
  parameter bit          PrintSimCfg = 1'b0,
  parameter              ImplKey     = "none",
  parameter int unsigned AddrWidth = (NumWords > 32'd1) ? $clog2(NumWords) : 32'd1,
  parameter int unsigned BeWidth   = DataWidth / ByteWidth,
  parameter type         addr_t    = logic [AddrWidth-1:0],
  parameter type         data_t    = logic [DataWidth-1:0],
  parameter type         be_t      = logic [BeWidth-1:0]
) (
  input  logic                 clk_i,
  input  logic                 rst_ni,
  input  logic  [NumPorts-1:0] req_i,
  input  logic  [NumPorts-1:0] we_i,
  input  addr_t [NumPorts-1:0] addr_i,
  input  data_t [NumPorts-1:0] wdata_i,
  input  be_t   [NumPorts-1:0] be_i,
  output data_t [NumPorts-1:0] rdata_o
);

`ifdef FRISCV_SRAM_INIT
  localparam InitFile = `FRISCV_SRAM_INIT;
`else
  localparam InitFile = "none";
`endif

  be_t wen;
  assign wen = be_i[0] & {BeWidth{we_i[0]}};

  xpm_memory_spram #(
    .ADDR_WIDTH_A       ( AddrWidth          ),
    .BYTE_WRITE_WIDTH_A ( ByteWidth          ),
    .MEMORY_INIT_FILE   ( InitFile           ),
    .MEMORY_SIZE        ( NumWords*DataWidth ),  // bits
    .READ_DATA_WIDTH_A  ( DataWidth          ),
    .READ_LATENCY_A     ( Latency            ),
    .WRITE_DATA_WIDTH_A ( DataWidth          ),
    .WRITE_MODE_A       ( "no_change"        )
  ) i_spram (
    .clka   ( clk_i      ),
    .rsta   ( ~rst_ni    ),
    .ena    ( req_i[0]   ),
    .wea    ( wen        ),
    .addra  ( addr_i[0]  ),
    .dina   ( wdata_i[0] ),
    .douta  ( rdata_o[0] ),
    .regcea ( 1'b1       ),
    .sleep  ( 1'b0       ),
    .injectsbiterra ( 1'b0 ),
    .injectdbiterra ( 1'b0 )
  );

endmodule
