// SPDX-License-Identifier: BSD-3-Clause
// Copyright (c) 2026 Yijie Yu
//
// RFSoC 4x2 core: 100GbE CMAC on QSFP28 <-> UDP/IP stack (64 bit @ clk) with ARP, ICMP echo,
// UDP echo on ports 1234/1235 and a UDP data stream read from PL DDR4.
//
//   CMAC 512 bit @ txusrclk2 <-> async frame FIFOs <-> udp_stack 64 bit @ clk (400 MHz)
//   DDR4 -> ddr_record_loop -> record_udp_tx -> udp_stack stream port (FPGA:1236+i -> peer:1237+i)
//
// Stream control (VIO): tx_speed_en start/stop, tx_delay idle cycles between packets,
// tx_length[4:0] number of flows, tx_length[5] rotate source IP, tx_length[11] jumbo frames.

`resetall
`timescale 1ns / 1ps
`default_nettype none

module fpga_core (
    input  wire         clk,            // 400 MHz: UDP stack, stream, DDR read side
    input  wire         rst,
    input  wire         clk_125,        // 125 MHz: DDS / DDR write side, CMAC init clock
    input  wire         rst_125,

    // QSFP28
    output wire         qsfp0_tx1_p, qsfp0_tx1_n,
    input  wire         qsfp0_rx1_p, qsfp0_rx1_n,
    output wire         qsfp0_tx2_p, qsfp0_tx2_n,
    input  wire         qsfp0_rx2_p, qsfp0_rx2_n,
    output wire         qsfp0_tx3_p, qsfp0_tx3_n,
    input  wire         qsfp0_rx3_p, qsfp0_rx3_n,
    output wire         qsfp0_tx4_p, qsfp0_tx4_n,
    input  wire         qsfp0_rx4_p, qsfp0_rx4_n,
    input  wire         qsfp0_mgt_refclk_0_p,
    input  wire         qsfp0_mgt_refclk_0_n,
    output wire         qsfp0_modsell,
    output wire         qsfp0_resetl,
    input  wire         qsfp0_modprsl,
    input  wire         qsfp0_intl,
    output wire         qsfp0_lpmode,

    // PL DDR4
    input  wire         c0_sys_clk_p,
    input  wire         c0_sys_clk_n,
    input  wire         ddr_sys_rst,
    output wire [16:0]  c0_ddr4_adr,
    output wire [1:0]   c0_ddr4_ba,
    output wire [0:0]   c0_ddr4_cke,
    output wire [0:0]   c0_ddr4_cs_n,
    inout  wire [7:0]   c0_ddr4_dm_dbi_n,
    inout  wire [63:0]  c0_ddr4_dq,
    inout  wire [7:0]   c0_ddr4_dqs_c,
    inout  wire [7:0]   c0_ddr4_dqs_t,
    output wire [0:0]   c0_ddr4_odt,
    output wire [0:0]   c0_ddr4_bg,
    output wire         c0_ddr4_reset_n,
    output wire         c0_ddr4_act_n,
    output wire [0:0]   c0_ddr4_ck_c,
    output wire [0:0]   c0_ddr4_ck_t
);

// ---------------------------------------------------------------- configuration
localparam [47:0] LOCAL_MAC   = 48'h02_00_00_00_00_00;
localparam [31:0] LOCAL_IP    = {8'd192, 8'd168, 8'd100, 8'd1};     // same plan as rfsoc4x2_corundum: board .1, PC .2
localparam [31:0] GATEWAY_IP  = {8'd192, 8'd168, 8'd100, 8'd254};
localparam [31:0] ALIAS_BASE  = {8'd192, 8'd168, 8'd100, 8'd128};   // .128-.159: flow addresses
localparam        ALIAS_COUNT = 32;
localparam [31:0] SUBNET_MASK = {8'd255, 8'd255, 8'd255, 8'd0};
localparam [15:0] STREAM_SRC_PORT = 16'd1236;
localparam [15:0] STREAM_DST_PORT = 16'd1237;
localparam REC_SAMPLES = 1048576;       // samples per DDR record (2^20, 4 MB)

assign qsfp0_modsell = 1'b1;
assign qsfp0_resetl  = 1'b1;
assign qsfp0_lpmode  = 1'b0;

// ---------------------------------------------------------------- CMAC
wire         mac_clk;                    // gt_txusrclk2, also used for the RX side
wire         mac_tx_rst, mac_rx_rst;
wire [511:0] mac_tx_tdata;
wire [63:0]  mac_tx_tkeep;
wire         mac_tx_tvalid, mac_tx_tready, mac_tx_tlast, mac_tx_tuser;
wire [511:0] mac_rx_tdata;
wire [63:0]  mac_rx_tkeep;
wire         mac_rx_tvalid, mac_rx_tlast, mac_rx_tuser;

cmac_usplus_0 cmac_inst (
    .gt_rxp_in({qsfp0_rx4_p, qsfp0_rx3_p, qsfp0_rx2_p, qsfp0_rx1_p}),
    .gt_rxn_in({qsfp0_rx4_n, qsfp0_rx3_n, qsfp0_rx2_n, qsfp0_rx1_n}),
    .gt_txp_out({qsfp0_tx4_p, qsfp0_tx3_p, qsfp0_tx2_p, qsfp0_tx1_p}),
    .gt_txn_out({qsfp0_tx4_n, qsfp0_tx3_n, qsfp0_tx2_n, qsfp0_tx1_n}),
    .gt_ref_clk_p(qsfp0_mgt_refclk_0_p),
    .gt_ref_clk_n(qsfp0_mgt_refclk_0_n),
    .gt_txusrclk2(mac_clk),
    .gt_loopback_in(12'd0),
    .gtwiz_reset_tx_datapath(1'b0),
    .gtwiz_reset_rx_datapath(1'b0),
    .sys_reset(rst_125),
    .init_clk(clk_125),
    // RS-FEC
    .ctl_tx_rsfec_enable(1'b1),
    .ctl_rx_rsfec_enable(1'b1),
    .ctl_rsfec_ieee_error_indication_mode(1'b0),
    .ctl_rx_rsfec_enable_correction(1'b1),
    .ctl_rx_rsfec_enable_indication(1'b1),
    // RX
    .rx_clk(mac_clk),
    .core_rx_reset(1'b0),
    .ctl_rx_enable(1'b1),
    .ctl_rx_force_resync(1'b0),
    .ctl_rx_test_pattern(1'b0),
    .usr_rx_reset(mac_rx_rst),
    .rx_axis_tvalid(mac_rx_tvalid),
    .rx_axis_tdata(mac_rx_tdata),
    .rx_axis_tlast(mac_rx_tlast),
    .rx_axis_tkeep(mac_rx_tkeep),
    .rx_axis_tuser(mac_rx_tuser),
    // TX
    .core_tx_reset(1'b0),
    .ctl_tx_enable(1'b1),
    .ctl_tx_send_idle(1'b0),
    .ctl_tx_send_rfi(1'b0),
    .ctl_tx_send_lfi(1'b0),
    .ctl_tx_test_pattern(1'b0),
    .usr_tx_reset(mac_tx_rst),
    .tx_axis_tvalid(mac_tx_tvalid),
    .tx_axis_tready(mac_tx_tready),
    .tx_axis_tdata(mac_tx_tdata),
    .tx_axis_tlast(mac_tx_tlast),
    .tx_axis_tkeep(mac_tx_tkeep),
    .tx_axis_tuser(mac_tx_tuser),
    .tx_preamblein(56'd0),
    // DRP unused
    .core_drp_reset(1'b0),
    .drp_clk(1'b0),
    .drp_addr(10'd0),
    .drp_di(16'd0),
    .drp_en(1'b0),
    .drp_we(1'b0)
);

// ---------------------------------------------------------------- MAC <-> stack FIFOs
wire [63:0]  rx_tdata, tx_tdata;
wire [7:0]   rx_tkeep, tx_tkeep;
wire         rx_tvalid, rx_tready, rx_tlast, rx_tuser;
wire         tx_tvalid, tx_tready, tx_tlast, tx_tuser;

// RX: frames flagged bad by the CMAC are dropped; drop rather than stall when full
axis_async_fifo_adapter #(
    .DEPTH(262144),     // absorbs line-rate bursts from the 100G link (the stack drains 25.6 Gbps)
    .S_DATA_WIDTH(512), .S_KEEP_ENABLE(1), .S_KEEP_WIDTH(64),
    .M_DATA_WIDTH(64),  .M_KEEP_ENABLE(1), .M_KEEP_WIDTH(8),
    .ID_ENABLE(0), .DEST_ENABLE(0), .USER_ENABLE(1), .USER_WIDTH(1),
    .FRAME_FIFO(1), .DROP_OVERSIZE_FRAME(1), .DROP_BAD_FRAME(1), .DROP_WHEN_FULL(1)
)
rx_fifo (
    .s_clk(mac_clk), .s_rst(mac_rx_rst),
    .s_axis_tdata(mac_rx_tdata), .s_axis_tkeep(mac_rx_tkeep), .s_axis_tvalid(mac_rx_tvalid),
    .s_axis_tready(), .s_axis_tlast(mac_rx_tlast), .s_axis_tid(8'd0), .s_axis_tdest(8'd0),
    .s_axis_tuser(mac_rx_tuser),
    .m_clk(clk), .m_rst(rst),
    .m_axis_tdata(rx_tdata), .m_axis_tkeep(rx_tkeep), .m_axis_tvalid(rx_tvalid),
    .m_axis_tready(rx_tready), .m_axis_tlast(rx_tlast), .m_axis_tid(), .m_axis_tdest(),
    .m_axis_tuser(rx_tuser),
    .s_status_overflow(), .s_status_bad_frame(), .s_status_good_frame(),
    .m_status_overflow(), .m_status_bad_frame(), .m_status_good_frame()
);

// TX: complete frames only (the CMAC must not underrun inside a frame)
wire [511:0] txf_tdata;
wire [63:0]  txf_tkeep;
wire         txf_tvalid, txf_tready, txf_tlast, txf_tuser;

axis_async_fifo_adapter #(
    .DEPTH(32768),
    .S_DATA_WIDTH(64),  .S_KEEP_ENABLE(1), .S_KEEP_WIDTH(8),
    .M_DATA_WIDTH(512), .M_KEEP_ENABLE(1), .M_KEEP_WIDTH(64),
    .ID_ENABLE(0), .DEST_ENABLE(0), .USER_ENABLE(1), .USER_WIDTH(1),
    .FRAME_FIFO(1), .DROP_OVERSIZE_FRAME(1), .DROP_BAD_FRAME(1), .DROP_WHEN_FULL(0)
)
tx_fifo (
    .s_clk(clk), .s_rst(rst),
    .s_axis_tdata(tx_tdata), .s_axis_tkeep(tx_tkeep), .s_axis_tvalid(tx_tvalid),
    .s_axis_tready(tx_tready), .s_axis_tlast(tx_tlast), .s_axis_tid(8'd0), .s_axis_tdest(8'd0),
    .s_axis_tuser(tx_tuser),
    .m_clk(mac_clk), .m_rst(mac_tx_rst),
    .m_axis_tdata(txf_tdata), .m_axis_tkeep(txf_tkeep), .m_axis_tvalid(txf_tvalid),
    .m_axis_tready(txf_tready), .m_axis_tlast(txf_tlast), .m_axis_tid(), .m_axis_tdest(),
    .m_axis_tuser(txf_tuser),
    .s_status_overflow(), .s_status_bad_frame(), .s_status_good_frame(),
    .m_status_overflow(), .m_status_bad_frame(), .m_status_good_frame()
);

eth_pad_min #(.DATA_WIDTH(512)) tx_pad (
    .clk(mac_clk), .rst(mac_tx_rst),
    .s_axis_tdata(txf_tdata), .s_axis_tkeep(txf_tkeep), .s_axis_tvalid(txf_tvalid),
    .s_axis_tready(txf_tready), .s_axis_tlast(txf_tlast), .s_axis_tuser(txf_tuser),
    .m_axis_tdata(mac_tx_tdata), .m_axis_tkeep(mac_tx_tkeep), .m_axis_tvalid(mac_tx_tvalid),
    .m_axis_tready(mac_tx_tready), .m_axis_tlast(mac_tx_tlast), .m_axis_tuser(mac_tx_tuser)
);

// ---------------------------------------------------------------- UDP/IP stack
wire        st_hdr_valid, st_hdr_ready;
wire [31:0] st_ip_source_ip, st_ip_dest_ip;
wire [15:0] st_source_port, st_dest_port, st_length;
wire [63:0] st_tdata;
wire [7:0]  st_tkeep;
wire        st_tvalid, st_tready, st_tlast, st_tuser;
wire [31:0] stream_dest_ip;

udp_stack #(
    .ECHO_PORT_A(16'd1234),
    .ECHO_PORT_B(16'd1235),
    .UDP_CHECKSUM_PAYLOAD_FIFO_DEPTH(32768),   // two jumbo payloads: store-and-forward without bubbles
    .ALIAS_BASE(ALIAS_BASE),
    .ALIAS_COUNT(ALIAS_COUNT)
)
stack_inst (
    .clk(clk), .rst(rst),
    .local_mac(LOCAL_MAC), .local_ip(LOCAL_IP), .gateway_ip(GATEWAY_IP), .subnet_mask(SUBNET_MASK),
    .rx_axis_tdata(rx_tdata), .rx_axis_tkeep(rx_tkeep), .rx_axis_tvalid(rx_tvalid),
    .rx_axis_tready(rx_tready), .rx_axis_tlast(rx_tlast), .rx_axis_tuser(rx_tuser),
    .tx_axis_tdata(tx_tdata), .tx_axis_tkeep(tx_tkeep), .tx_axis_tvalid(tx_tvalid),
    .tx_axis_tready(tx_tready), .tx_axis_tlast(tx_tlast), .tx_axis_tuser(tx_tuser),
    .s_udp_hdr_valid(st_hdr_valid), .s_udp_hdr_ready(st_hdr_ready),
    .s_udp_ip_source_ip(st_ip_source_ip), .s_udp_ip_dest_ip(st_ip_dest_ip),
    .s_udp_source_port(st_source_port), .s_udp_dest_port(st_dest_port), .s_udp_length(st_length),
    .s_udp_payload_axis_tdata(st_tdata), .s_udp_payload_axis_tkeep(st_tkeep),
    .s_udp_payload_axis_tvalid(st_tvalid), .s_udp_payload_axis_tready(st_tready),
    .s_udp_payload_axis_tlast(st_tlast), .s_udp_payload_axis_tuser(st_tuser),
    .stream_dest_ip(stream_dest_ip)
);

// ---------------------------------------------------------------- stream control (VIO)
wire        tx_speed_en;
wire [15:0] tx_length;
wire [15:0] tx_delay;
wire [3:0]  txstate;

vio_0 vio_inst (
    .clk(clk),
    .probe_in0(txstate),
    .probe_out0(tx_speed_en),
    .probe_out1(tx_length),
    .probe_out2(tx_delay)
);

// ---------------------------------------------------------------- DDR4 data source
wire [63:0] rec_tdata;
wire        rec_tvalid, rec_tready, rec_tready_stream;

ddr_record_loop #(
    .TOTAL_SAMPLES(REC_SAMPLES),
    .TEST_RAMP(1)                        // 1: sample index ramp, 0: DDS
)
ddr_inst (
    .clk(clk), .rst(rst),
    .clk_wr(clk_125), .rst_wr(rst_125),
    .trig(tx_speed_en),
    .c0_sys_clk_p(c0_sys_clk_p), .c0_sys_clk_n(c0_sys_clk_n),
    .sys_rst(ddr_sys_rst), .init_calib_complete(),
    .c0_ddr4_adr(c0_ddr4_adr), .c0_ddr4_ba(c0_ddr4_ba), .c0_ddr4_cke(c0_ddr4_cke),
    .c0_ddr4_cs_n(c0_ddr4_cs_n), .c0_ddr4_dm_dbi_n(c0_ddr4_dm_dbi_n), .c0_ddr4_dq(c0_ddr4_dq),
    .c0_ddr4_dqs_c(c0_ddr4_dqs_c), .c0_ddr4_dqs_t(c0_ddr4_dqs_t), .c0_ddr4_odt(c0_ddr4_odt),
    .c0_ddr4_bg(c0_ddr4_bg), .c0_ddr4_reset_n(c0_ddr4_reset_n), .c0_ddr4_act_n(c0_ddr4_act_n),
    .c0_ddr4_ck_c(c0_ddr4_ck_c), .c0_ddr4_ck_t(c0_ddr4_ck_t),
    .m_axis_tdata(rec_tdata), .m_axis_tvalid(rec_tvalid), .m_axis_tready(rec_tready)
);

// While stopped (and not finishing a packet) the reads still in flight are drained, so a new
// start begins at the start of a record and start_index 0 really is sample 0.
wire rec_drain = !tx_speed_en && (txstate == 4'd0 || txstate == 4'd5);   // record_udp_tx idle / done
assign rec_tready = rec_drain | rec_tready_stream;

record_udp_tx #(
    .TOTAL_SAMPLES(REC_SAMPLES),
    .PAYLOAD_DATA_BYTES(1024),           // 256 samples per packet (+8-byte header = 1032 B)
    .JUMBO_DATA_BYTES(8192),             // 2048 samples per packet (+8-byte header = 8200 B)
    .LOOP(1),
    .USE_TEST_RAMP(0)
)
stream_inst (
    .clk(clk), .rst(rst),
    .dest_ip(stream_dest_ip), .local_ip(tx_length[5] ? ALIAS_BASE : LOCAL_IP),
    .dest_port(STREAM_DST_PORT), .local_port(STREAM_SRC_PORT),
    .trig(tx_speed_en), .gap_cycles(tx_delay),
    .flow_count(tx_length[4:0]), .flow_vary_ip(tx_length[5]), .jumbo(tx_length[11]),
    .txstate(txstate), .busy(),
    .s_axis_tdata(rec_tdata), .s_axis_tvalid(rec_tvalid), .s_axis_tready(rec_tready_stream),
    .tx_udp_hdr_valid(st_hdr_valid), .tx_udp_hdr_ready(st_hdr_ready),
    .tx_udp_ip_dscp(), .tx_udp_ip_ecn(), .tx_udp_ip_ttl(),
    .tx_udp_ip_source_ip(st_ip_source_ip), .tx_udp_ip_dest_ip(st_ip_dest_ip),
    .tx_udp_source_port(st_source_port), .tx_udp_dest_port(st_dest_port),
    .tx_udp_length(st_length), .tx_udp_checksum(),
    .tx_udp_payload_axis_tdata(st_tdata), .tx_udp_payload_axis_tkeep(st_tkeep),
    .tx_udp_payload_axis_tvalid(st_tvalid), .tx_udp_payload_axis_tready(st_tready),
    .tx_udp_payload_axis_tlast(st_tlast), .tx_udp_payload_axis_tuser(st_tuser)
);

endmodule

`resetall
