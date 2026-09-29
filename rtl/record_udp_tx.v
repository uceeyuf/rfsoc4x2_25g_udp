// SPDX-License-Identifier: BSD-3-Clause
// Copyright (c) 2026 Yijie Yu
//
`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module Name: record_udp_tx
// Description:
//   定长记录、带样本序号头 的 UDP 发送器（1 beat/拍 全速版）
//
//   每个 UDP 包 payload：
//     beat0(64bit) = 包头 = {total_samples[31:0], start_index[31:0]}（线上先发 start_index）
//     beat1..N = 数据，每 beat 2 个 32bit 样本；样本={sin[15:0],cos[15:0]}
//   数据字节数 N*8 = PAYLOAD_DATA_BYTES（标准帧）或 JUMBO_DATA_BYTES（jumbo=1，巨帧），
//   在 trig 上升沿锁存，整次发送不变。UDP 长度 = 8 + 8 + 数据字节数。
//
//   ★ 全速：payload 组合驱动，1 beat/拍 → 64bit@400M = 25.6Gbps 上限，
//     远超 DDS 写入的 4Gbps，使"读+发 > 写"（配合 ddr_record_loop 乒乓双缓冲不撕裂）。
//
//   数据源：USE_TEST_RAMP=1 内置锯齿；=0 用外部 s_axis（DDR 读出，可反压）。
//   LOOP=0 发完即停(A)；LOOP=1 循环不停(B)。gap_cycles 包间限速(运行时可调，接 VIO tx_delay)。
//////////////////////////////////////////////////////////////////////////////////

module record_udp_tx #(
    parameter TOTAL_SAMPLES      = 1000000,
    parameter PAYLOAD_DATA_BYTES = 1000,                // 8 的倍数（标准帧数据字节）
    parameter JUMBO_DATA_BYTES   = 8192,                // 8 的倍数（巨帧数据字节，需 PC 开 Jumbo）
    parameter LOOP               = 0,
    parameter USE_TEST_RAMP      = 1
)(
    input  wire         clk,
    input  wire         rst,

    input  wire  [31:0] dest_ip,
    input  wire  [31:0] local_ip,
    input  wire  [15:0] dest_port,
    input  wire  [15:0] local_port,

    input  wire         trig,
    input  wire  [15:0] gap_cycles,        // 包间空闲拍数(clk 周期)
    input  wire  [4:0]  flow_count,        // 逐包轮换的 flow 数(0/1=单 flow，最多 31)：端口 +i
    input  wire         flow_vary_ip,      // 1=源 IP 也 +i（Windows RSS 只按 IP 哈希时用）
    input  wire         jumbo,             // 1=巨帧（trig 上升沿锁存）
    output reg   [3:0]  txstate,
    output reg          busy,

    // 外部数据源（USE_TEST_RAMP=0）
    input  wire  [63:0] s_axis_tdata,
    input  wire         s_axis_tvalid,
    output wire         s_axis_tready,

    // UDP frame output
    output reg          tx_udp_hdr_valid,
    input  wire         tx_udp_hdr_ready,
    output wire  [5:0]  tx_udp_ip_dscp,
    output wire  [1:0]  tx_udp_ip_ecn,
    output wire  [7:0]  tx_udp_ip_ttl,
    output wire  [31:0] tx_udp_ip_source_ip,
    output wire  [31:0] tx_udp_ip_dest_ip,
    output wire  [15:0] tx_udp_source_port,
    output wire  [15:0] tx_udp_dest_port,
    output wire  [15:0] tx_udp_length,
    output wire  [15:0] tx_udp_checksum,
    output wire  [63:0] tx_udp_payload_axis_tdata,
    output wire  [7:0]  tx_udp_payload_axis_tkeep,
    output wire         tx_udp_payload_axis_tvalid,
    input  wire         tx_udp_payload_axis_tready,
    output wire         tx_udp_payload_axis_tlast,
    output wire         tx_udp_payload_axis_tuser
);

    // ---------------- 固定头部字段 ----------------
    assign tx_udp_ip_dscp      = 0;
    assign tx_udp_ip_ecn       = 0;
    assign tx_udp_ip_ttl       = 64;
    // 多 flow：第 k 包用 flow (k mod N)，只改端口(和可选的源 IP)，序号头仍全局递增
    reg  [4:0]  flow_idx;
    wire [4:0]  flow_last = (flow_count == 5'd0) ? 5'd0 : flow_count - 5'd1;
    assign tx_udp_ip_source_ip = local_ip + (flow_vary_ip ? {27'd0, flow_idx} : 32'd0);
    assign tx_udp_ip_dest_ip   = dest_ip;
    assign tx_udp_source_port  = local_port + {11'd0, flow_idx};
    assign tx_udp_dest_port    = dest_port  + {11'd0, flow_idx};
    localparam [15:0] WORDS_STD   = PAYLOAD_DATA_BYTES / 8;
    localparam [15:0] WORDS_JUMBO = JUMBO_DATA_BYTES / 8;
    reg        [15:0] pkt_words;   // 本次发送每包数据 beat 数
    assign tx_udp_length       = 16'd16 + {pkt_words[12:0], 3'd0};   // UDP 头 8 + 序号头 8 + 数据
    assign tx_udp_checksum     = 0;

    // ---------------- 触发边沿检测 ----------------
    reg trig_d;
    always @(posedge clk) trig_d <= trig;
    wire trig_rise = trig & ~trig_d;

    // ---------------- 状态/计数 ----------------
    localparam S_IDLE     = 4'd0,
               S_HDR      = 4'd1,
               S_HDR_WAIT = 4'd2,
               S_PAY      = 4'd3,   // 1 beat/拍 连续发 payload
               S_GAP      = 4'd4,
               S_DONE     = 4'd5;

    reg [31:0] start_index;     // 当前包首样本序号
    reg [31:0] beat_s;          // 当前数据 beat 低样本序号（贯穿整段）
    reg [15:0] bcnt;            // 包内 beat：0=包头，1..pkt_words=数据
    reg [31:0] gapc;

    // ---------------- 内置锯齿测试源 ----------------
    function [63:0] ramp_beat(input [31:0] k);
        ramp_beat = { {~(k[15:0]+16'd1), (k[15:0]+16'd1)},
                      { ~k[15:0],          k[15:0]        } };
    endfunction
    wire [63:0] src_data  = USE_TEST_RAMP ? ramp_beat(beat_s) : s_axis_tdata;
    wire        src_valid = USE_TEST_RAMP ? 1'b1              : s_axis_tvalid;

    // ---------------- payload 组合驱动（1 beat/拍）----------------
    wire        paying  = (txstate == S_PAY);
    wire        is_hdr  = (bcnt == 16'd0);
    wire [63:0] hdr_word = {TOTAL_SAMPLES[31:0], start_index};

    assign tx_udp_payload_axis_tdata  = is_hdr ? hdr_word : src_data;
    assign tx_udp_payload_axis_tvalid = paying & (is_hdr ? 1'b1 : src_valid);
    assign tx_udp_payload_axis_tlast  = paying & (bcnt == pkt_words);
    assign tx_udp_payload_axis_tkeep  = 8'hff;
    assign tx_udp_payload_axis_tuser  = 1'b0;
    // 仅外部源、数据 beat、且下游 ready 时，从源弹出一个 beat
    assign s_axis_tready = (~USE_TEST_RAMP) & paying & (~is_hdr) & tx_udp_payload_axis_tready;

    wire beat_acc = tx_udp_payload_axis_tvalid & tx_udp_payload_axis_tready;

    always @(posedge clk) begin
        if (rst) begin
            txstate          <= S_IDLE;
            busy             <= 1'b0;
            start_index      <= 32'd0;
            beat_s           <= 32'd0;
            bcnt             <= 16'd0;
            gapc             <= 32'd0;
            flow_idx         <= 5'd0;
            pkt_words        <= WORDS_STD;
            tx_udp_hdr_valid <= 1'b0;
        end else begin
            case (txstate)
            //-------------------------------------------------------------- 等触发
            S_IDLE: begin
                busy             <= 1'b0;
                tx_udp_hdr_valid <= 1'b0;
                if (trig_rise && dest_ip != 32'd0) begin
                    start_index <= 32'd0;
                    beat_s      <= 32'd0;
                    flow_idx    <= 5'd0;
                    pkt_words   <= jumbo ? WORDS_JUMBO : WORDS_STD;
                    busy        <= 1'b1;
                    txstate     <= S_HDR;
                end
            end
            //-------------------------------------------------------------- UDP 包头
            S_HDR: begin
                tx_udp_hdr_valid <= 1'b1;
                if (tx_udp_hdr_ready)
                    txstate <= S_HDR_WAIT;
            end
            S_HDR_WAIT: begin
                if (~tx_udp_hdr_ready) begin
                    tx_udp_hdr_valid <= 1'b0;
                    bcnt             <= 16'd0;
                    txstate          <= S_PAY;
                end
            end
            //-------------------------------------------------------------- payload（1 beat/拍）
            S_PAY: begin
                if (beat_acc) begin
                    if (~is_hdr)
                        beat_s <= beat_s + 32'd2;        // 数据 beat 消耗 2 个样本
                    if (bcnt == pkt_words) begin
                        gapc    <= 32'd0;
                        flow_idx <= (flow_idx >= flow_last) ? 5'd0 : flow_idx + 5'd1;
                        txstate <= S_GAP;                // 一包发完
                    end else begin
                        bcnt <= bcnt + 16'd1;
                    end
                end
            end
            //-------------------------------------------------------------- 包间限速
            S_GAP: begin
                if (gapc >= {16'd0, gap_cycles}) begin
                    if (~trig) begin
                        txstate <= S_DONE;
                    end else if (beat_s >= TOTAL_SAMPLES) begin
                        if (LOOP) begin
                            beat_s      <= 32'd0;
                            start_index <= 32'd0;
                            txstate     <= S_HDR;
                        end else begin
                            txstate <= S_DONE;
                        end
                    end else begin
                        start_index <= beat_s;
                        txstate     <= S_HDR;
                    end
                end else begin
                    gapc <= gapc + 32'd1;
                end
            end
            //-------------------------------------------------------------- 完成
            S_DONE: begin
                busy <= 1'b0;
                if (~trig)
                    txstate <= S_IDLE;
            end
            default: txstate <= S_IDLE;
            endcase
        end
    end

endmodule
