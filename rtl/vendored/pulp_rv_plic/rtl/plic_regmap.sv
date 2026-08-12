// Do not edit - auto-generated
module plic_regs #(
  parameter type reg_req_t  = logic,
  parameter type reg_rsp_t  = logic
)(
  input logic [31:0][0:0] prio_i,
  output logic [31:0][0:0] prio_o,
  output logic [31:0] prio_we_o,
  output logic [31:0] prio_re_o,
  input logic [0:0][31:0] ip_i,
  output logic [0:0] ip_re_o,
  input logic [1:0][31:0] ie_i,
  output logic [1:0][31:0] ie_o,
  output logic [1:0] ie_we_o,
  output logic [1:0] ie_re_o,
  input logic [1:0][0:0] threshold_i,
  output logic [1:0][0:0] threshold_o,
  output logic [1:0] threshold_we_o,
  output logic [1:0] threshold_re_o,
  input logic [1:0][4:0] cc_i,
  output logic [1:0][4:0] cc_o,
  output logic [1:0] cc_we_o,
  output logic [1:0] cc_re_o,
  // Bus Interface
  input  reg_req_t req_i,
  output reg_rsp_t resp_o
);
always_comb begin
  resp_o.ready = 1'b1;
  resp_o.rdata = '0;
  resp_o.error = '0;
  prio_o = '0;
  prio_we_o = '0;
  prio_re_o = '0;
  ie_o = '0;
  ie_we_o = '0;
  ie_re_o = '0;
  threshold_o = '0;
  threshold_we_o = '0;
  threshold_re_o = '0;
  cc_o = '0;
  cc_we_o = '0;
  cc_re_o = '0;
  if (req_i.valid) begin
    if (req_i.write) begin
      unique case(req_i.addr)
        32'hc000000: begin
          prio_o[0][0:0] = req_i.wdata[0:0];
          prio_we_o[0] = 1'b1;
        end
        32'hc000004: begin
          prio_o[1][0:0] = req_i.wdata[0:0];
          prio_we_o[1] = 1'b1;
        end
        32'hc000008: begin
          prio_o[2][0:0] = req_i.wdata[0:0];
          prio_we_o[2] = 1'b1;
        end
        32'hc00000c: begin
          prio_o[3][0:0] = req_i.wdata[0:0];
          prio_we_o[3] = 1'b1;
        end
        32'hc000010: begin
          prio_o[4][0:0] = req_i.wdata[0:0];
          prio_we_o[4] = 1'b1;
        end
        32'hc000014: begin
          prio_o[5][0:0] = req_i.wdata[0:0];
          prio_we_o[5] = 1'b1;
        end
        32'hc000018: begin
          prio_o[6][0:0] = req_i.wdata[0:0];
          prio_we_o[6] = 1'b1;
        end
        32'hc00001c: begin
          prio_o[7][0:0] = req_i.wdata[0:0];
          prio_we_o[7] = 1'b1;
        end
        32'hc000020: begin
          prio_o[8][0:0] = req_i.wdata[0:0];
          prio_we_o[8] = 1'b1;
        end
        32'hc000024: begin
          prio_o[9][0:0] = req_i.wdata[0:0];
          prio_we_o[9] = 1'b1;
        end
        32'hc000028: begin
          prio_o[10][0:0] = req_i.wdata[0:0];
          prio_we_o[10] = 1'b1;
        end
        32'hc00002c: begin
          prio_o[11][0:0] = req_i.wdata[0:0];
          prio_we_o[11] = 1'b1;
        end
        32'hc000030: begin
          prio_o[12][0:0] = req_i.wdata[0:0];
          prio_we_o[12] = 1'b1;
        end
        32'hc000034: begin
          prio_o[13][0:0] = req_i.wdata[0:0];
          prio_we_o[13] = 1'b1;
        end
        32'hc000038: begin
          prio_o[14][0:0] = req_i.wdata[0:0];
          prio_we_o[14] = 1'b1;
        end
        32'hc00003c: begin
          prio_o[15][0:0] = req_i.wdata[0:0];
          prio_we_o[15] = 1'b1;
        end
        32'hc000040: begin
          prio_o[16][0:0] = req_i.wdata[0:0];
          prio_we_o[16] = 1'b1;
        end
        32'hc000044: begin
          prio_o[17][0:0] = req_i.wdata[0:0];
          prio_we_o[17] = 1'b1;
        end
        32'hc000048: begin
          prio_o[18][0:0] = req_i.wdata[0:0];
          prio_we_o[18] = 1'b1;
        end
        32'hc00004c: begin
          prio_o[19][0:0] = req_i.wdata[0:0];
          prio_we_o[19] = 1'b1;
        end
        32'hc000050: begin
          prio_o[20][0:0] = req_i.wdata[0:0];
          prio_we_o[20] = 1'b1;
        end
        32'hc000054: begin
          prio_o[21][0:0] = req_i.wdata[0:0];
          prio_we_o[21] = 1'b1;
        end
        32'hc000058: begin
          prio_o[22][0:0] = req_i.wdata[0:0];
          prio_we_o[22] = 1'b1;
        end
        32'hc00005c: begin
          prio_o[23][0:0] = req_i.wdata[0:0];
          prio_we_o[23] = 1'b1;
        end
        32'hc000060: begin
          prio_o[24][0:0] = req_i.wdata[0:0];
          prio_we_o[24] = 1'b1;
        end
        32'hc000064: begin
          prio_o[25][0:0] = req_i.wdata[0:0];
          prio_we_o[25] = 1'b1;
        end
        32'hc000068: begin
          prio_o[26][0:0] = req_i.wdata[0:0];
          prio_we_o[26] = 1'b1;
        end
        32'hc00006c: begin
          prio_o[27][0:0] = req_i.wdata[0:0];
          prio_we_o[27] = 1'b1;
        end
        32'hc000070: begin
          prio_o[28][0:0] = req_i.wdata[0:0];
          prio_we_o[28] = 1'b1;
        end
        32'hc000074: begin
          prio_o[29][0:0] = req_i.wdata[0:0];
          prio_we_o[29] = 1'b1;
        end
        32'hc000078: begin
          prio_o[30][0:0] = req_i.wdata[0:0];
          prio_we_o[30] = 1'b1;
        end
        32'hc00007c: begin
          prio_o[31][0:0] = req_i.wdata[0:0];
          prio_we_o[31] = 1'b1;
        end
        32'hc002000: begin
          ie_o[0][31:0] = req_i.wdata[31:0];
          ie_we_o[0] = 1'b1;
        end
        32'hc002080: begin
          ie_o[1][31:0] = req_i.wdata[31:0];
          ie_we_o[1] = 1'b1;
        end
        32'hc200000: begin
          threshold_o[0][0:0] = req_i.wdata[0:0];
          threshold_we_o[0] = 1'b1;
        end
        32'hc201000: begin
          threshold_o[1][0:0] = req_i.wdata[0:0];
          threshold_we_o[1] = 1'b1;
        end
        32'hc200004: begin
          cc_o[0][4:0] = req_i.wdata[4:0];
          cc_we_o[0] = 1'b1;
        end
        32'hc201004: begin
          cc_o[1][4:0] = req_i.wdata[4:0];
          cc_we_o[1] = 1'b1;
        end
        default: resp_o.error = 1'b1;
      endcase
    end else begin
      unique case(req_i.addr)
        32'hc000000: begin
          resp_o.rdata[0:0] = prio_i[0][0:0];
          prio_re_o[0] = 1'b1;
        end
        32'hc000004: begin
          resp_o.rdata[0:0] = prio_i[1][0:0];
          prio_re_o[1] = 1'b1;
        end
        32'hc000008: begin
          resp_o.rdata[0:0] = prio_i[2][0:0];
          prio_re_o[2] = 1'b1;
        end
        32'hc00000c: begin
          resp_o.rdata[0:0] = prio_i[3][0:0];
          prio_re_o[3] = 1'b1;
        end
        32'hc000010: begin
          resp_o.rdata[0:0] = prio_i[4][0:0];
          prio_re_o[4] = 1'b1;
        end
        32'hc000014: begin
          resp_o.rdata[0:0] = prio_i[5][0:0];
          prio_re_o[5] = 1'b1;
        end
        32'hc000018: begin
          resp_o.rdata[0:0] = prio_i[6][0:0];
          prio_re_o[6] = 1'b1;
        end
        32'hc00001c: begin
          resp_o.rdata[0:0] = prio_i[7][0:0];
          prio_re_o[7] = 1'b1;
        end
        32'hc000020: begin
          resp_o.rdata[0:0] = prio_i[8][0:0];
          prio_re_o[8] = 1'b1;
        end
        32'hc000024: begin
          resp_o.rdata[0:0] = prio_i[9][0:0];
          prio_re_o[9] = 1'b1;
        end
        32'hc000028: begin
          resp_o.rdata[0:0] = prio_i[10][0:0];
          prio_re_o[10] = 1'b1;
        end
        32'hc00002c: begin
          resp_o.rdata[0:0] = prio_i[11][0:0];
          prio_re_o[11] = 1'b1;
        end
        32'hc000030: begin
          resp_o.rdata[0:0] = prio_i[12][0:0];
          prio_re_o[12] = 1'b1;
        end
        32'hc000034: begin
          resp_o.rdata[0:0] = prio_i[13][0:0];
          prio_re_o[13] = 1'b1;
        end
        32'hc000038: begin
          resp_o.rdata[0:0] = prio_i[14][0:0];
          prio_re_o[14] = 1'b1;
        end
        32'hc00003c: begin
          resp_o.rdata[0:0] = prio_i[15][0:0];
          prio_re_o[15] = 1'b1;
        end
        32'hc000040: begin
          resp_o.rdata[0:0] = prio_i[16][0:0];
          prio_re_o[16] = 1'b1;
        end
        32'hc000044: begin
          resp_o.rdata[0:0] = prio_i[17][0:0];
          prio_re_o[17] = 1'b1;
        end
        32'hc000048: begin
          resp_o.rdata[0:0] = prio_i[18][0:0];
          prio_re_o[18] = 1'b1;
        end
        32'hc00004c: begin
          resp_o.rdata[0:0] = prio_i[19][0:0];
          prio_re_o[19] = 1'b1;
        end
        32'hc000050: begin
          resp_o.rdata[0:0] = prio_i[20][0:0];
          prio_re_o[20] = 1'b1;
        end
        32'hc000054: begin
          resp_o.rdata[0:0] = prio_i[21][0:0];
          prio_re_o[21] = 1'b1;
        end
        32'hc000058: begin
          resp_o.rdata[0:0] = prio_i[22][0:0];
          prio_re_o[22] = 1'b1;
        end
        32'hc00005c: begin
          resp_o.rdata[0:0] = prio_i[23][0:0];
          prio_re_o[23] = 1'b1;
        end
        32'hc000060: begin
          resp_o.rdata[0:0] = prio_i[24][0:0];
          prio_re_o[24] = 1'b1;
        end
        32'hc000064: begin
          resp_o.rdata[0:0] = prio_i[25][0:0];
          prio_re_o[25] = 1'b1;
        end
        32'hc000068: begin
          resp_o.rdata[0:0] = prio_i[26][0:0];
          prio_re_o[26] = 1'b1;
        end
        32'hc00006c: begin
          resp_o.rdata[0:0] = prio_i[27][0:0];
          prio_re_o[27] = 1'b1;
        end
        32'hc000070: begin
          resp_o.rdata[0:0] = prio_i[28][0:0];
          prio_re_o[28] = 1'b1;
        end
        32'hc000074: begin
          resp_o.rdata[0:0] = prio_i[29][0:0];
          prio_re_o[29] = 1'b1;
        end
        32'hc000078: begin
          resp_o.rdata[0:0] = prio_i[30][0:0];
          prio_re_o[30] = 1'b1;
        end
        32'hc00007c: begin
          resp_o.rdata[0:0] = prio_i[31][0:0];
          prio_re_o[31] = 1'b1;
        end
        32'hc001000: begin
          resp_o.rdata[31:0] = ip_i[0][31:0];
          ip_re_o[0] = 1'b1;
        end
        32'hc002000: begin
          resp_o.rdata[31:0] = ie_i[0][31:0];
          ie_re_o[0] = 1'b1;
        end
        32'hc002080: begin
          resp_o.rdata[31:0] = ie_i[1][31:0];
          ie_re_o[1] = 1'b1;
        end
        32'hc200000: begin
          resp_o.rdata[0:0] = threshold_i[0][0:0];
          threshold_re_o[0] = 1'b1;
        end
        32'hc201000: begin
          resp_o.rdata[0:0] = threshold_i[1][0:0];
          threshold_re_o[1] = 1'b1;
        end
        32'hc200004: begin
          resp_o.rdata[4:0] = cc_i[0][4:0];
          cc_re_o[0] = 1'b1;
        end
        32'hc201004: begin
          resp_o.rdata[4:0] = cc_i[1][4:0];
          cc_re_o[1] = 1'b1;
        end
        default: resp_o.error = 1'b1;
      endcase
    end
  end
end
endmodule

