`timescale 1ns / 1ps
// Quick check of record_udp_tx multi-flow rotation: prints dest port / source IP /
// start_index of the first packets for flow_count = 4 with source-IP variation on.
module tb_record_udp_tx_flows;
    parameter JUMBO = 0;
    reg clk = 0, rst = 1, trig = 0;
    always #4 clk = ~clk;

    wire        hdr_valid;
    reg         hdr_ready = 0;   // one-cycle accept pulse, like udp_complete
    always @(posedge clk) hdr_ready <= hdr_valid & ~hdr_ready;
    wire [31:0] src_ip;
    wire [15:0] dport, sport;
    wire [63:0] tdata;
    wire        tvalid, tlast;

    record_udp_tx #(
        .TOTAL_SAMPLES(4096), .PAYLOAD_DATA_BYTES(64), .JUMBO_DATA_BYTES(512), .LOOP(1), .USE_TEST_RAMP(1)
    ) dut (
        .clk(clk), .rst(rst),
        .dest_ip(32'hC0A86401), .local_ip(32'hC0A86480),
        .dest_port(16'd1237), .local_port(16'd1236),
        .trig(trig), .gap_cycles(16'd2), .flow_count(5'd4), .flow_vary_ip(1'b1), .jumbo(JUMBO[0]),
        .txstate(), .busy(),
        .s_axis_tdata(64'd0), .s_axis_tvalid(1'b0), .s_axis_tready(),
        .tx_udp_hdr_valid(hdr_valid), .tx_udp_hdr_ready(hdr_ready),
        .tx_udp_ip_dscp(), .tx_udp_ip_ecn(), .tx_udp_ip_ttl(),
        .tx_udp_ip_source_ip(src_ip), .tx_udp_ip_dest_ip(),
        .tx_udp_source_port(sport), .tx_udp_dest_port(dport),
        .tx_udp_length(), .tx_udp_checksum(),
        .tx_udp_payload_axis_tdata(tdata), .tx_udp_payload_axis_tkeep(),
        .tx_udp_payload_axis_tvalid(tvalid), .tx_udp_payload_axis_tready(1'b1),
        .tx_udp_payload_axis_tlast(tlast), .tx_udp_payload_axis_tuser()
    );

    integer npkt = 0;
    reg first_beat = 1;
    always @(posedge clk) begin
        if (tvalid && first_beat) begin
            $display("pkt %0d: src %0d.%0d.%0d.%0d:%0d -> :%0d  udp_len=%0d  start_index=%0d",
                     npkt, src_ip[31:24], src_ip[23:16], src_ip[15:8], src_ip[7:0],
                     sport, dport, dut.tx_udp_length, tdata[31:0]);
            npkt = npkt + 1;
        end
        if (tvalid) first_beat <= tlast;
    end

    initial begin
        #40 rst = 0;
        #40 trig = 1;
        wait (npkt == 10);
        $finish;
    end
endmodule
