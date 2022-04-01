/*
 * axi_video_gen_v1_0.sv
 *
 *  Created on: 2022-04-02 10:52
 *      Author: Jack Chen <redchenjs@live.com>
 */

`timescale 1 ns / 1 ps

module axi_video_gen_v1_0 #(
    parameter C_M_AXI_TARGET_SLAVE_BASE_ADDR = 32'h40000000
) (
    input logic m_axi_aclk,
    input logic m_axi_aresetn,

    output logic [31:0] m_axi_awaddr,
    output logic  [7:0] m_axi_awlen,
    output logic  [2:0] m_axi_awsize,
    output logic  [1:0] m_axi_awburst,
    output logic        m_axi_awlock,
    output logic  [3:0] m_axi_awcache,
    output logic  [2:0] m_axi_awprot,
    output logic  [3:0] m_axi_awqos,
    output logic        m_axi_awvalid,
    input  logic        m_axi_awready,

    output logic [31:0] m_axi_wdata,
    output logic  [3:0] m_axi_wstrb,
    output logic        m_axi_wlast,
    output logic        m_axi_wvalid,
    input  logic        m_axi_wready,

    input  logic [1:0] m_axi_bresp,
    input  logic       m_axi_bvalid,
    output logic       m_axi_bready,

    input  logic spi_miso,
    output logic spi_mosi,
    output logic spi_sclk,
    output logic spi_cs_n,

    input  logic pic_load_init,
    output logic pic_load_head,
    output logic pic_load_data,
    output logic pic_load_done,
    output logic pic_load_error
);

typedef enum logic [1:0] {
    IDLE      = 2'b00,
    SCAN_FILE = 2'b01,
    READ_HEAD = 2'b10,
    READ_DATA = 2'b11
} state_t;

state_t ctl_sta;

logic [31:0] axi_awaddr;
logic        axi_awvalid;

logic [31:0] axi_wdata;
logic        axi_wvalid;

logic axi_bready;

logic       sdcard_outreq;
logic [7:0] sdcard_outbyte;
logic       sdcard_file_found;

logic pic_load_init_p;
logic pic_load_init_n;

logic pic_data_next;

logic  [2:0] pic_byte_sel;
logic [31:0] pic_byte_cnt;

logic [23:0] color_data;
logic [23:0] color_grey;

assign m_axi_awaddr  = C_M_AXI_TARGET_SLAVE_BASE_ADDR + axi_awaddr;
assign m_axi_awlen   = 0;
assign m_axi_awsize  = 3'h2;
assign m_axi_awburst = 2'h1;
assign m_axi_awlock  = 1'b0;
assign m_axi_awcache = 4'h2;
assign m_axi_awprot  = 3'h0;
assign m_axi_awqos   = 4'h0;
assign m_axi_awvalid = axi_awvalid;

assign m_axi_wdata  = axi_wdata;
assign m_axi_wstrb  = 4'b1111;
assign m_axi_wlast  = axi_wvalid;
assign m_axi_wvalid = axi_wvalid;

assign m_axi_bready	= axi_bready;

wire pic_head_done = (pic_byte_cnt > (54 - 1));
wire pic_data_done = (pic_byte_cnt > (54 + 1920 * 1080 * 3 - 1));

sd_file_reader #(
    .FILE_NAME("pic.bmp"),
    .SPI_CLK_DIV(10)
) sd_file_reader (
    .clk(m_axi_aclk),
    .rst_n(ctl_sta != IDLE),

    .spi_miso(spi_miso),
    .spi_mosi(spi_mosi),
    .spi_clk(spi_sclk),
    .spi_cs_n(spi_cs_n),

    .sdcardtype(),
    .filesystemtype(),
    .sdcardstate(),
    .fatstate(),
    .file_found(sdcard_file_found),

    .outreq(sdcard_outreq),
    .outbyte(sdcard_outbyte)
);

edge2en pic_load_init_en(
    .clk_i(m_axi_aclk),
    .rst_n_i(m_axi_aresetn),
    .data_i(pic_load_init),
    .pos_edge_o(pic_load_init_p),
    .neg_edge_o(pic_load_init_n)
);

always_ff @(posedge m_axi_aclk or negedge m_axi_aresetn)
begin
    if (!m_axi_aresetn) begin
        ctl_sta <= IDLE;

        axi_awaddr  <= 32'h0000_0000;
        axi_awvalid <= 1'b0;

        axi_wdata  <= 32'h0000_0000;
        axi_wvalid <= 1'b0;

        axi_bready <= 1'b0;

        pic_byte_sel <= 3'b000;
        pic_byte_cnt <= 32'h0000_0000;

        pic_data_next <= 1'b0;

        pic_load_head  <= 1'b0;
        pic_load_data  <= 1'b0;
        pic_load_done  <= 1'b0;
        pic_load_error <= 1'b0;

        color_data <= 24'h00_0000;
        color_grey <= 24'h00_0000;
    end else begin
        case (ctl_sta)
            IDLE:
                ctl_sta <= pic_load_init_n ? SCAN_FILE : ctl_sta;
            SCAN_FILE:
                ctl_sta <= sdcard_file_found ? READ_HEAD : (pic_load_init_n ? IDLE : ctl_sta);
            READ_HEAD:
                ctl_sta <= pic_head_done ? READ_DATA : ctl_sta;
            READ_DATA:
                ctl_sta <= pic_data_done ? IDLE : ctl_sta;
            default:
                ctl_sta <= IDLE;
        endcase

        axi_awaddr  <= sdcard_file_found ? (axi_bready ? axi_awaddr + 3'h4 : axi_awaddr) : 32'h0000_0000;
        axi_awvalid <= (m_axi_awready & axi_awvalid) ? 1'b0 : (~axi_awvalid & pic_data_next) ? 1'b1 : axi_awvalid;

        axi_wdata  <= (~axi_wvalid & pic_data_next) ? {8'h00, color_data} : axi_wdata;
        axi_wvalid <= (m_axi_wready & axi_wvalid) ? 1'b0 : (~axi_wvalid & pic_data_next) ? 1'b1 : axi_wvalid;

        axi_bready <= (m_axi_bvalid & ~axi_bready);

        pic_byte_sel <= pic_head_done ? (sdcard_outreq ? {pic_byte_sel[1:0], pic_byte_sel[2]} : pic_byte_sel) : 3'b001;
        pic_byte_cnt <= sdcard_file_found ? pic_byte_cnt + sdcard_outreq : 32'h0000_0000;

        pic_data_next <= (pic_byte_sel[2] & pic_head_done & sdcard_outreq);

        pic_load_head  <= (ctl_sta == READ_HEAD);
        pic_load_data  <= (ctl_sta == READ_DATA);
        pic_load_done  <= (ctl_sta == IDLE);
        pic_load_error <= (ctl_sta == SCAN_FILE);

        if (pic_head_done & sdcard_outreq) begin
            case (pic_byte_sel)
                3'b001: begin
                    color_data <= {color_data[23:16], color_data[15:8], sdcard_outbyte};
                end
                3'b010: begin
                    color_data <= {color_data[23:16], sdcard_outbyte, color_data[7:0]};
                end
                3'b100: begin
                    color_data <= {sdcard_outbyte, color_data[15:8], color_data[7:0]};
                end
            endcase
        end

        color_grey <= 24'h00_0000;
    end
end

endmodule