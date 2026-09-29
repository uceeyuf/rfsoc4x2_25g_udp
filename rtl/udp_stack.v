// SPDX-License-Identifier: BSD-3-Clause
// Copyright (c) 2026 Yijie Yu
//
// Ethernet/ARP/IP/UDP stack around verilog-ethernet (eth_axis_rx/tx, udp_complete_64,
// udp_arb_mux) with an ICMP echo responder, UDP echo on two ports and one extra UDP
// transmit port for a data stream. Ethernet frames (without FCS) in and out, 64 bit.
// The source IP of the last received UDP packet is exported as the stream destination.

`resetall
`timescale 1ns / 1ps
`default_nettype none

module udp_stack #(
    parameter [15:0] ECHO_PORT_A = 16'd1234,
    parameter [15:0] ECHO_PORT_B = 16'd1235,
    parameter UDP_CHECKSUM_PAYLOAD_FIFO_DEPTH = 16384,  // bytes, >= largest UDP payload
    parameter ECHO_FIFO_DEPTH = 131072,                 // bytes, echo frame FIFO (several jumbo packets)
    // extra addresses (ARP + UDP echo) for multi-flow tests and the stream source IPs
    parameter [31:0] ALIAS_BASE = 32'd0,
    parameter ALIAS_COUNT = 0
)(
    input  wire        clk,
    input  wire        rst,

    input  wire [47:0] local_mac,
    input  wire [31:0] local_ip,
    input  wire [31:0] gateway_ip,
    input  wire [31:0] subnet_mask,

    // Ethernet frames from the MAC
    input  wire [63:0] rx_axis_tdata,
    input  wire [7:0]  rx_axis_tkeep,
    input  wire        rx_axis_tvalid,
    output wire        rx_axis_tready,
    input  wire        rx_axis_tlast,
    input  wire        rx_axis_tuser,

    // Ethernet frames to the MAC
    output wire [63:0] tx_axis_tdata,
    output wire [7:0]  tx_axis_tkeep,
    output wire        tx_axis_tvalid,
    input  wire        tx_axis_tready,
    output wire        tx_axis_tlast,
    output wire        tx_axis_tuser,

    // UDP data stream to transmit
    input  wire        s_udp_hdr_valid,
    output wire        s_udp_hdr_ready,
    input  wire [31:0] s_udp_ip_source_ip,
    input  wire [31:0] s_udp_ip_dest_ip,
    input  wire [15:0] s_udp_source_port,
    input  wire [15:0] s_udp_dest_port,
    input  wire [15:0] s_udp_length,
    input  wire [63:0] s_udp_payload_axis_tdata,
    input  wire [7:0]  s_udp_payload_axis_tkeep,
    input  wire        s_udp_payload_axis_tvalid,
    output wire        s_udp_payload_axis_tready,
    input  wire        s_udp_payload_axis_tlast,
    input  wire        s_udp_payload_axis_tuser,

    output reg  [31:0] stream_dest_ip = 32'd0
);

// ---------------------------------------------------------------- Ethernet framing
wire        rx_eth_hdr_valid, rx_eth_hdr_ready;
wire [47:0] rx_eth_dest_mac, rx_eth_src_mac;
wire [15:0] rx_eth_type;
wire [63:0] rx_eth_payload_axis_tdata;
wire [7:0]  rx_eth_payload_axis_tkeep;
wire        rx_eth_payload_axis_tvalid, rx_eth_payload_axis_tready;
wire        rx_eth_payload_axis_tlast, rx_eth_payload_axis_tuser;

wire        tx_eth_hdr_valid, tx_eth_hdr_ready;
wire [47:0] tx_eth_dest_mac, tx_eth_src_mac;
wire [15:0] tx_eth_type;
wire [63:0] tx_eth_payload_axis_tdata;
wire [7:0]  tx_eth_payload_axis_tkeep;
wire        tx_eth_payload_axis_tvalid, tx_eth_payload_axis_tready;
wire        tx_eth_payload_axis_tlast, tx_eth_payload_axis_tuser;

eth_axis_rx #(.DATA_WIDTH(64)) eth_rx_inst (
    .clk(clk), .rst(rst),
    .s_axis_tdata(rx_axis_tdata), .s_axis_tkeep(rx_axis_tkeep), .s_axis_tvalid(rx_axis_tvalid),
    .s_axis_tready(rx_axis_tready), .s_axis_tlast(rx_axis_tlast), .s_axis_tuser(rx_axis_tuser),
    .m_eth_hdr_valid(rx_eth_hdr_valid), .m_eth_hdr_ready(rx_eth_hdr_ready),
    .m_eth_dest_mac(rx_eth_dest_mac), .m_eth_src_mac(rx_eth_src_mac), .m_eth_type(rx_eth_type),
    .m_eth_payload_axis_tdata(rx_eth_payload_axis_tdata), .m_eth_payload_axis_tkeep(rx_eth_payload_axis_tkeep),
    .m_eth_payload_axis_tvalid(rx_eth_payload_axis_tvalid), .m_eth_payload_axis_tready(rx_eth_payload_axis_tready),
    .m_eth_payload_axis_tlast(rx_eth_payload_axis_tlast), .m_eth_payload_axis_tuser(rx_eth_payload_axis_tuser),
    .busy(), .error_header_early_termination()
);

eth_axis_tx #(.DATA_WIDTH(64)) eth_tx_inst (
    .clk(clk), .rst(rst),
    .s_eth_hdr_valid(tx_eth_hdr_valid), .s_eth_hdr_ready(tx_eth_hdr_ready),
    .s_eth_dest_mac(tx_eth_dest_mac), .s_eth_src_mac(tx_eth_src_mac), .s_eth_type(tx_eth_type),
    .s_eth_payload_axis_tdata(tx_eth_payload_axis_tdata), .s_eth_payload_axis_tkeep(tx_eth_payload_axis_tkeep),
    .s_eth_payload_axis_tvalid(tx_eth_payload_axis_tvalid), .s_eth_payload_axis_tready(tx_eth_payload_axis_tready),
    .s_eth_payload_axis_tlast(tx_eth_payload_axis_tlast), .s_eth_payload_axis_tuser(tx_eth_payload_axis_tuser),
    .m_axis_tdata(tx_axis_tdata), .m_axis_tkeep(tx_axis_tkeep), .m_axis_tvalid(tx_axis_tvalid),
    .m_axis_tready(tx_axis_tready), .m_axis_tlast(tx_axis_tlast), .m_axis_tuser(tx_axis_tuser),
    .busy()
);

// ---------------------------------------------------------------- IP / UDP
// non-UDP IP (ICMP) in both directions
wire        rx_ip_hdr_valid, rx_ip_hdr_ready;
wire [15:0] rx_ip_length;
wire [7:0]  rx_ip_protocol;
wire [31:0] rx_ip_source_ip, rx_ip_dest_ip;
wire [63:0] rx_ip_payload_axis_tdata;
wire [7:0]  rx_ip_payload_axis_tkeep;
wire        rx_ip_payload_axis_tvalid, rx_ip_payload_axis_tready;
wire        rx_ip_payload_axis_tlast, rx_ip_payload_axis_tuser;

wire        tx_ip_hdr_valid, tx_ip_hdr_ready;
wire [5:0]  tx_ip_dscp;
wire [1:0]  tx_ip_ecn;
wire [15:0] tx_ip_length;
wire [7:0]  tx_ip_ttl, tx_ip_protocol;
wire [31:0] tx_ip_source_ip, tx_ip_dest_ip;
wire [63:0] tx_ip_payload_axis_tdata;
wire [7:0]  tx_ip_payload_axis_tkeep;
wire        tx_ip_payload_axis_tvalid, tx_ip_payload_axis_tready;
wire        tx_ip_payload_axis_tlast, tx_ip_payload_axis_tuser;

// received UDP
wire        rx_udp_hdr_valid, rx_udp_hdr_ready;
wire [31:0] rx_udp_ip_source_ip, rx_udp_ip_dest_ip;
wire [15:0] rx_udp_source_port, rx_udp_dest_port, rx_udp_length;
wire [63:0] rx_udp_payload_axis_tdata;
wire [7:0]  rx_udp_payload_axis_tkeep;
wire        rx_udp_payload_axis_tvalid, rx_udp_payload_axis_tready;
wire        rx_udp_payload_axis_tlast, rx_udp_payload_axis_tuser;

// UDP to transmit (after the arbiter)
wire        tx_udp_hdr_valid, tx_udp_hdr_ready;
wire [5:0]  tx_udp_ip_dscp;
wire [1:0]  tx_udp_ip_ecn;
wire [7:0]  tx_udp_ip_ttl;
wire [31:0] tx_udp_ip_source_ip, tx_udp_ip_dest_ip;
wire [15:0] tx_udp_source_port, tx_udp_dest_port, tx_udp_length, tx_udp_checksum;
wire [63:0] tx_udp_payload_axis_tdata;
wire [7:0]  tx_udp_payload_axis_tkeep;
wire        tx_udp_payload_axis_tvalid, tx_udp_payload_axis_tready;
wire        tx_udp_payload_axis_tlast, tx_udp_payload_axis_tuser;

udp_complete_64 #(
    .UDP_CHECKSUM_GEN_ENABLE(1),
    .UDP_CHECKSUM_PAYLOAD_FIFO_DEPTH(UDP_CHECKSUM_PAYLOAD_FIFO_DEPTH)
)
udp_complete_inst (
    .clk(clk), .rst(rst),
    // Ethernet
    .s_eth_hdr_valid(rx_eth_hdr_valid), .s_eth_hdr_ready(rx_eth_hdr_ready),
    .s_eth_dest_mac(rx_eth_dest_mac), .s_eth_src_mac(rx_eth_src_mac), .s_eth_type(rx_eth_type),
    .s_eth_payload_axis_tdata(rx_eth_payload_axis_tdata), .s_eth_payload_axis_tkeep(rx_eth_payload_axis_tkeep),
    .s_eth_payload_axis_tvalid(rx_eth_payload_axis_tvalid), .s_eth_payload_axis_tready(rx_eth_payload_axis_tready),
    .s_eth_payload_axis_tlast(rx_eth_payload_axis_tlast), .s_eth_payload_axis_tuser(rx_eth_payload_axis_tuser),
    .m_eth_hdr_valid(tx_eth_hdr_valid), .m_eth_hdr_ready(tx_eth_hdr_ready),
    .m_eth_dest_mac(tx_eth_dest_mac), .m_eth_src_mac(tx_eth_src_mac), .m_eth_type(tx_eth_type),
    .m_eth_payload_axis_tdata(tx_eth_payload_axis_tdata), .m_eth_payload_axis_tkeep(tx_eth_payload_axis_tkeep),
    .m_eth_payload_axis_tvalid(tx_eth_payload_axis_tvalid), .m_eth_payload_axis_tready(tx_eth_payload_axis_tready),
    .m_eth_payload_axis_tlast(tx_eth_payload_axis_tlast), .m_eth_payload_axis_tuser(tx_eth_payload_axis_tuser),
    // IP (ICMP)
    .s_ip_hdr_valid(tx_ip_hdr_valid), .s_ip_hdr_ready(tx_ip_hdr_ready),
    .s_ip_dscp(tx_ip_dscp), .s_ip_ecn(tx_ip_ecn), .s_ip_length(tx_ip_length), .s_ip_ttl(tx_ip_ttl),
    .s_ip_protocol(tx_ip_protocol), .s_ip_source_ip(tx_ip_source_ip), .s_ip_dest_ip(tx_ip_dest_ip),
    .s_ip_payload_axis_tdata(tx_ip_payload_axis_tdata), .s_ip_payload_axis_tkeep(tx_ip_payload_axis_tkeep),
    .s_ip_payload_axis_tvalid(tx_ip_payload_axis_tvalid), .s_ip_payload_axis_tready(tx_ip_payload_axis_tready),
    .s_ip_payload_axis_tlast(tx_ip_payload_axis_tlast), .s_ip_payload_axis_tuser(tx_ip_payload_axis_tuser),
    .m_ip_hdr_valid(rx_ip_hdr_valid), .m_ip_hdr_ready(rx_ip_hdr_ready),
    .m_ip_eth_dest_mac(), .m_ip_eth_src_mac(), .m_ip_eth_type(), .m_ip_version(), .m_ip_ihl(),
    .m_ip_dscp(), .m_ip_ecn(), .m_ip_length(rx_ip_length), .m_ip_identification(), .m_ip_flags(),
    .m_ip_fragment_offset(), .m_ip_ttl(), .m_ip_protocol(rx_ip_protocol), .m_ip_header_checksum(),
    .m_ip_source_ip(rx_ip_source_ip), .m_ip_dest_ip(rx_ip_dest_ip),
    .m_ip_payload_axis_tdata(rx_ip_payload_axis_tdata), .m_ip_payload_axis_tkeep(rx_ip_payload_axis_tkeep),
    .m_ip_payload_axis_tvalid(rx_ip_payload_axis_tvalid), .m_ip_payload_axis_tready(rx_ip_payload_axis_tready),
    .m_ip_payload_axis_tlast(rx_ip_payload_axis_tlast), .m_ip_payload_axis_tuser(rx_ip_payload_axis_tuser),
    // UDP
    .s_udp_hdr_valid(tx_udp_hdr_valid), .s_udp_hdr_ready(tx_udp_hdr_ready),
    .s_udp_ip_dscp(tx_udp_ip_dscp), .s_udp_ip_ecn(tx_udp_ip_ecn), .s_udp_ip_ttl(tx_udp_ip_ttl),
    .s_udp_ip_source_ip(tx_udp_ip_source_ip), .s_udp_ip_dest_ip(tx_udp_ip_dest_ip),
    .s_udp_source_port(tx_udp_source_port), .s_udp_dest_port(tx_udp_dest_port),
    .s_udp_length(tx_udp_length), .s_udp_checksum(tx_udp_checksum),
    .s_udp_payload_axis_tdata(tx_udp_payload_axis_tdata), .s_udp_payload_axis_tkeep(tx_udp_payload_axis_tkeep),
    .s_udp_payload_axis_tvalid(tx_udp_payload_axis_tvalid), .s_udp_payload_axis_tready(tx_udp_payload_axis_tready),
    .s_udp_payload_axis_tlast(tx_udp_payload_axis_tlast), .s_udp_payload_axis_tuser(tx_udp_payload_axis_tuser),
    .m_udp_hdr_valid(rx_udp_hdr_valid), .m_udp_hdr_ready(rx_udp_hdr_ready),
    .m_udp_eth_dest_mac(), .m_udp_eth_src_mac(), .m_udp_eth_type(), .m_udp_ip_version(), .m_udp_ip_ihl(),
    .m_udp_ip_dscp(), .m_udp_ip_ecn(), .m_udp_ip_length(), .m_udp_ip_identification(), .m_udp_ip_flags(),
    .m_udp_ip_fragment_offset(), .m_udp_ip_ttl(), .m_udp_ip_protocol(), .m_udp_ip_header_checksum(),
    .m_udp_ip_source_ip(rx_udp_ip_source_ip), .m_udp_ip_dest_ip(rx_udp_ip_dest_ip),
    .m_udp_source_port(rx_udp_source_port), .m_udp_dest_port(rx_udp_dest_port),
    .m_udp_length(rx_udp_length), .m_udp_checksum(),
    .m_udp_payload_axis_tdata(rx_udp_payload_axis_tdata), .m_udp_payload_axis_tkeep(rx_udp_payload_axis_tkeep),
    .m_udp_payload_axis_tvalid(rx_udp_payload_axis_tvalid), .m_udp_payload_axis_tready(rx_udp_payload_axis_tready),
    .m_udp_payload_axis_tlast(rx_udp_payload_axis_tlast), .m_udp_payload_axis_tuser(rx_udp_payload_axis_tuser),
    // status / config
    .ip_rx_busy(), .ip_tx_busy(), .udp_rx_busy(), .udp_tx_busy(),
    .ip_rx_error_header_early_termination(), .ip_rx_error_payload_early_termination(),
    .ip_rx_error_invalid_header(), .ip_rx_error_invalid_checksum(),
    .ip_tx_error_payload_early_termination(), .ip_tx_error_arp_failed(),
    .udp_rx_error_header_early_termination(), .udp_rx_error_payload_early_termination(),
    .udp_tx_error_payload_early_termination(),
    .local_mac(local_mac), .local_ip(local_ip), .gateway_ip(gateway_ip), .subnet_mask(subnet_mask),
    .clear_arp_cache(1'b0)
);

// ---------------------------------------------------------------- ICMP echo
icmp_echo icmp_echo_inst (
    .clk(clk), .rst(rst), .local_ip(local_ip),
    .s_ip_hdr_valid(rx_ip_hdr_valid), .s_ip_hdr_ready(rx_ip_hdr_ready),
    .s_ip_length(rx_ip_length), .s_ip_protocol(rx_ip_protocol),
    .s_ip_source_ip(rx_ip_source_ip), .s_ip_dest_ip(rx_ip_dest_ip),
    .s_ip_payload_axis_tdata(rx_ip_payload_axis_tdata), .s_ip_payload_axis_tkeep(rx_ip_payload_axis_tkeep),
    .s_ip_payload_axis_tvalid(rx_ip_payload_axis_tvalid), .s_ip_payload_axis_tready(rx_ip_payload_axis_tready),
    .s_ip_payload_axis_tlast(rx_ip_payload_axis_tlast), .s_ip_payload_axis_tuser(rx_ip_payload_axis_tuser),
    .m_ip_hdr_valid(tx_ip_hdr_valid), .m_ip_hdr_ready(tx_ip_hdr_ready),
    .m_ip_dscp(tx_ip_dscp), .m_ip_ecn(tx_ip_ecn), .m_ip_length(tx_ip_length), .m_ip_ttl(tx_ip_ttl),
    .m_ip_protocol(tx_ip_protocol), .m_ip_source_ip(tx_ip_source_ip), .m_ip_dest_ip(tx_ip_dest_ip),
    .m_ip_payload_axis_tdata(tx_ip_payload_axis_tdata), .m_ip_payload_axis_tkeep(tx_ip_payload_axis_tkeep),
    .m_ip_payload_axis_tvalid(tx_ip_payload_axis_tvalid), .m_ip_payload_axis_tready(tx_ip_payload_axis_tready),
    .m_ip_payload_axis_tlast(tx_ip_payload_axis_tlast), .m_ip_payload_axis_tuser(tx_ip_payload_axis_tuser)
);

// ---------------------------------------------------------------- UDP echo
wire        echo_hdr_valid, echo_hdr_ready;
wire [5:0]  echo_ip_dscp;
wire [1:0]  echo_ip_ecn;
wire [7:0]  echo_ip_ttl;
wire [31:0] echo_ip_source_ip, echo_ip_dest_ip;
wire [15:0] echo_source_port, echo_dest_port, echo_length, echo_checksum;
wire [63:0] echo_payload_axis_tdata;
wire [7:0]  echo_payload_axis_tkeep;
wire        echo_payload_axis_tvalid, echo_payload_axis_tready;
wire        echo_payload_axis_tlast, echo_payload_axis_tuser;

udp_echo #(.PORT_A(ECHO_PORT_A), .PORT_B(ECHO_PORT_B), .FIFO_DEPTH(ECHO_FIFO_DEPTH),
           .ALIAS_BASE(ALIAS_BASE), .ALIAS_COUNT(ALIAS_COUNT)) udp_echo_inst (
    .clk(clk), .rst(rst), .local_ip(local_ip),
    .s_udp_hdr_valid(rx_udp_hdr_valid), .s_udp_hdr_ready(rx_udp_hdr_ready),
    .s_udp_ip_source_ip(rx_udp_ip_source_ip), .s_udp_ip_dest_ip(rx_udp_ip_dest_ip),
    .s_udp_source_port(rx_udp_source_port),
    .s_udp_dest_port(rx_udp_dest_port), .s_udp_length(rx_udp_length),
    .s_udp_payload_axis_tdata(rx_udp_payload_axis_tdata), .s_udp_payload_axis_tkeep(rx_udp_payload_axis_tkeep),
    .s_udp_payload_axis_tvalid(rx_udp_payload_axis_tvalid), .s_udp_payload_axis_tready(rx_udp_payload_axis_tready),
    .s_udp_payload_axis_tlast(rx_udp_payload_axis_tlast), .s_udp_payload_axis_tuser(rx_udp_payload_axis_tuser),
    .m_udp_hdr_valid(echo_hdr_valid), .m_udp_hdr_ready(echo_hdr_ready),
    .m_udp_ip_dscp(echo_ip_dscp), .m_udp_ip_ecn(echo_ip_ecn), .m_udp_ip_ttl(echo_ip_ttl),
    .m_udp_ip_source_ip(echo_ip_source_ip), .m_udp_ip_dest_ip(echo_ip_dest_ip),
    .m_udp_source_port(echo_source_port), .m_udp_dest_port(echo_dest_port),
    .m_udp_length(echo_length), .m_udp_checksum(echo_checksum),
    .m_udp_payload_axis_tdata(echo_payload_axis_tdata), .m_udp_payload_axis_tkeep(echo_payload_axis_tkeep),
    .m_udp_payload_axis_tvalid(echo_payload_axis_tvalid), .m_udp_payload_axis_tready(echo_payload_axis_tready),
    .m_udp_payload_axis_tlast(echo_payload_axis_tlast), .m_udp_payload_axis_tuser(echo_payload_axis_tuser)
);

// ARP answers for the alias addresses too
defparam udp_complete_inst.ip_complete_64_inst.arp_inst.ALIAS_BASE = ALIAS_BASE;
defparam udp_complete_inst.ip_complete_64_inst.arp_inst.ALIAS_COUNT = ALIAS_COUNT;

// the stream goes to whoever sent us the last UDP packet
always @(posedge clk) begin
    if (rst)
        stream_dest_ip <= 32'd0;
    else if (rx_udp_hdr_valid && rx_udp_hdr_ready)
        stream_dest_ip <= rx_udp_ip_source_ip;
end

// ---------------------------------------------------------------- TX arbitration: echo, stream
udp_arb_mux #(
    .S_COUNT(2),
    .DATA_WIDTH(64),
    .KEEP_ENABLE(1),
    .ID_ENABLE(0),
    .DEST_ENABLE(0),
    .USER_ENABLE(1),
    .USER_WIDTH(1),
    .ARB_TYPE_ROUND_ROBIN(1),
    .ARB_LSB_HIGH_PRIORITY(1)
)
udp_arb_inst (
    .clk(clk), .rst(rst),
    .s_udp_hdr_valid({s_udp_hdr_valid, echo_hdr_valid}),
    .s_udp_hdr_ready({s_udp_hdr_ready, echo_hdr_ready}),
    .s_eth_dest_mac(96'd0), .s_eth_src_mac(96'd0), .s_eth_type(32'd0),
    .s_ip_version(8'd0), .s_ip_ihl(8'd0),
    .s_ip_dscp({6'd0, echo_ip_dscp}), .s_ip_ecn({2'd0, echo_ip_ecn}),
    .s_ip_length(32'd0), .s_ip_identification(32'd0), .s_ip_flags(6'd0), .s_ip_fragment_offset(26'd0),
    .s_ip_ttl({8'd64, echo_ip_ttl}), .s_ip_protocol({8'd17, 8'd17}), .s_ip_header_checksum(32'd0),
    .s_ip_source_ip({s_udp_ip_source_ip, echo_ip_source_ip}),
    .s_ip_dest_ip({s_udp_ip_dest_ip, echo_ip_dest_ip}),
    .s_udp_source_port({s_udp_source_port, echo_source_port}),
    .s_udp_dest_port({s_udp_dest_port, echo_dest_port}),
    .s_udp_length({s_udp_length, echo_length}),
    .s_udp_checksum({16'd0, echo_checksum}),
    .s_udp_payload_axis_tdata({s_udp_payload_axis_tdata, echo_payload_axis_tdata}),
    .s_udp_payload_axis_tkeep({s_udp_payload_axis_tkeep, echo_payload_axis_tkeep}),
    .s_udp_payload_axis_tvalid({s_udp_payload_axis_tvalid, echo_payload_axis_tvalid}),
    .s_udp_payload_axis_tready({s_udp_payload_axis_tready, echo_payload_axis_tready}),
    .s_udp_payload_axis_tlast({s_udp_payload_axis_tlast, echo_payload_axis_tlast}),
    .s_udp_payload_axis_tid(16'd0), .s_udp_payload_axis_tdest(16'd0),
    .s_udp_payload_axis_tuser({s_udp_payload_axis_tuser, echo_payload_axis_tuser}),
    .m_udp_hdr_valid(tx_udp_hdr_valid), .m_udp_hdr_ready(tx_udp_hdr_ready),
    .m_eth_dest_mac(), .m_eth_src_mac(), .m_eth_type(), .m_ip_version(), .m_ip_ihl(),
    .m_ip_dscp(tx_udp_ip_dscp), .m_ip_ecn(tx_udp_ip_ecn), .m_ip_length(), .m_ip_identification(),
    .m_ip_flags(), .m_ip_fragment_offset(), .m_ip_ttl(tx_udp_ip_ttl), .m_ip_protocol(),
    .m_ip_header_checksum(), .m_ip_source_ip(tx_udp_ip_source_ip), .m_ip_dest_ip(tx_udp_ip_dest_ip),
    .m_udp_source_port(tx_udp_source_port), .m_udp_dest_port(tx_udp_dest_port),
    .m_udp_length(tx_udp_length), .m_udp_checksum(tx_udp_checksum),
    .m_udp_payload_axis_tdata(tx_udp_payload_axis_tdata), .m_udp_payload_axis_tkeep(tx_udp_payload_axis_tkeep),
    .m_udp_payload_axis_tvalid(tx_udp_payload_axis_tvalid), .m_udp_payload_axis_tready(tx_udp_payload_axis_tready),
    .m_udp_payload_axis_tlast(tx_udp_payload_axis_tlast), .m_udp_payload_axis_tid(),
    .m_udp_payload_axis_tdest(), .m_udp_payload_axis_tuser(tx_udp_payload_axis_tuser)
);

endmodule

`resetall
