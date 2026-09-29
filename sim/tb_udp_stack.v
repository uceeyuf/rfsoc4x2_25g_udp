`timescale 1ns / 1ps
// System test of udp_stack (verilog-ethernet + icmp_echo + udp_echo) at the Ethernet
// frame level: ARP, ICMP echo, UDP echo on two ports under bursts and MAC back-pressure,
// UDP echo while the peer MAC is still unresolved, the extra UDP stream port, and the
// alias addresses (ARP, echo replies from them).
module tb_udp_stack;
    reg clk = 0, rst = 1;
    always #2.5 clk = ~clk;

    localparam [47:0] FPGA_MAC = 48'h02_00_00_00_00_00;
    localparam [31:0] FPGA_IP  = {8'd192, 8'd168, 8'd100, 8'd1};
    localparam [31:0] ALIAS_IP = {8'd192, 8'd168, 8'd100, 8'd128};   // 32 alias addresses
    localparam [47:0] PC_MAC   = 48'hEC_0D_9A_44_D8_8C;
    localparam [31:0] PC_IP    = {8'd192, 8'd168, 8'd100, 8'd2};

    // ---------------------------------------------------------------- DUT
    reg  [63:0] rx_tdata = 0; reg [7:0] rx_tkeep = 0; reg rx_tvalid = 0, rx_tlast = 0;
    wire        rx_tready;
    wire [63:0] tx_tdata; wire [7:0] tx_tkeep; wire tx_tvalid, tx_tlast, tx_tuser;
    reg         tx_tready = 1;

    reg         st_hv = 0; wire st_hr;
    reg  [15:0] st_len = 0;
    reg  [63:0] st_d = 0; reg [7:0] st_k = 0; reg st_v = 0, st_l = 0; wire st_r;
    wire [31:0] stream_dest_ip;

    udp_stack #(.ALIAS_BASE(ALIAS_IP), .ALIAS_COUNT(32)) dut (
        .clk(clk), .rst(rst),
        .local_mac(FPGA_MAC), .local_ip(FPGA_IP), .gateway_ip({8'd192, 8'd168, 8'd100, 8'd254}),
        .subnet_mask(32'hFFFFFF00),
        .rx_axis_tdata(rx_tdata), .rx_axis_tkeep(rx_tkeep), .rx_axis_tvalid(rx_tvalid),
        .rx_axis_tready(rx_tready), .rx_axis_tlast(rx_tlast), .rx_axis_tuser(1'b0),
        .tx_axis_tdata(tx_tdata), .tx_axis_tkeep(tx_tkeep), .tx_axis_tvalid(tx_tvalid),
        .tx_axis_tready(tx_tready), .tx_axis_tlast(tx_tlast), .tx_axis_tuser(tx_tuser),
        .s_udp_hdr_valid(st_hv), .s_udp_hdr_ready(st_hr),
        .s_udp_ip_source_ip(FPGA_IP), .s_udp_ip_dest_ip(PC_IP),
        .s_udp_source_port(16'd1236), .s_udp_dest_port(16'd1237), .s_udp_length(st_len),
        .s_udp_payload_axis_tdata(st_d), .s_udp_payload_axis_tkeep(st_k),
        .s_udp_payload_axis_tvalid(st_v), .s_udp_payload_axis_tready(st_r),
        .s_udp_payload_axis_tlast(st_l), .s_udp_payload_axis_tuser(1'b0),
        .stream_dest_ip(stream_dest_ip)
    );

    integer errors = 0;
    task fail(input [8*80-1:0] msg); begin errors = errors + 1; $display("ERROR: %0s", msg); end endtask

    // ---------------------------------------------------------------- frame builder
    reg [7:0] fb [0:9215];
    integer   flen;

    task put16(input integer o, input [15:0] v); begin fb[o] = v[15:8]; fb[o+1] = v[7:0]; end endtask
    task put32(input integer o, input [31:0] v); begin put16(o, v[31:16]); put16(o+2, v[15:0]); end endtask
    task put48(input integer o, input [47:0] v); begin put16(o, v[47:32]); put32(o+2, v[31:0]); end endtask

    function [15:0] csum(input integer start, input integer n);   // over fb[start..start+n-1]
        integer i; reg [31:0] s;
        begin
            s = 0;
            for (i = 0; i < n; i = i + 2)
                s = s + {fb[start+i], (i+1 < n) ? fb[start+i+1] : 8'h00};
            while (s[31:16]) s = s[15:0] + s[31:16];
            csum = ~s[15:0];
        end
    endfunction

    task eth_hdr(input [15:0] ethertype);
        begin put48(0, FPGA_MAC); put48(6, PC_MAC); put16(12, ethertype); end
    endtask

    reg [31:0] dst_ip = FPGA_IP;      // destination of the frames built below
    reg [31:0] last_arp_spa = 0;

    task ip_hdr(input [15:0] total_len, input [7:0] proto);
        begin
            fb[14] = 8'h45; fb[15] = 0; put16(16, total_len); put16(18, 16'h1234); put16(20, 16'h4000);
            fb[22] = 64; fb[23] = proto; put16(24, 0); put32(26, PC_IP); put32(30, dst_ip);
            put16(24, csum(14, 20));
        end
    endtask

    task build_udp(input [15:0] sport, input [15:0] dport, input integer plen, input integer seed);
        integer i;
        begin
            eth_hdr(16'h0800); ip_hdr(28 + plen, 8'd17);
            put16(34, sport); put16(36, dport); put16(38, 8 + plen); put16(40, 0);
            for (i = 0; i < plen; i = i + 1) fb[42+i] = (seed * 7 + i * 13) & 8'hff;
            flen = 42 + plen;
        end
    endtask

    task build_arp(input [15:0] oper, input [47:0] tha, input [31:0] tpa);
        begin
            put48(0, oper == 1 ? 48'hFFFFFFFFFFFF : FPGA_MAC); put48(6, PC_MAC); put16(12, 16'h0806);
            put16(14, 1); put16(16, 16'h0800); fb[18] = 6; fb[19] = 4; put16(20, oper);
            put48(22, PC_MAC); put32(28, PC_IP); put48(32, tha); put32(38, tpa);
            flen = 42;
        end
    endtask

    task build_ping(input [15:0] seq, input integer dlen);
        integer i;
        begin
            eth_hdr(16'h0800); ip_hdr(28 + dlen, 8'd1);
            fb[34] = 8; fb[35] = 0; put16(36, 0); put16(38, 16'h0001); put16(40, seq);
            for (i = 0; i < dlen; i = i + 1) fb[42+i] = 8'h61 + (i % 23);
            put16(36, csum(34, 8 + dlen));
            flen = 42 + dlen;
        end
    endtask

    // push fb[0..flen-1] into the DUT; returns cycles spent waiting for rx_tready
    integer rx_stall;
    task send_frame;
        integer pos, j;
        reg [63:0] d; reg [7:0] kp;
        begin
            pos = 0;
            while (pos < flen) begin
                d = 0; kp = 0;
                for (j = 0; j < 8; j = j + 1)
                    if (pos + j < flen) begin d[j*8 +: 8] = fb[pos+j]; kp[j] = 1'b1; end
                rx_tdata <= d; rx_tkeep <= kp;
                rx_tvalid <= 1; rx_tlast <= (pos + 8 >= flen);
                @(posedge clk);
                while (!rx_tready) begin rx_stall = rx_stall + 1; @(posedge clk); end
                pos = pos + 8;
            end
            rx_tvalid <= 0; rx_tlast <= 0;
        end
    endtask

    // ---------------------------------------------------------------- TX monitor
    reg [7:0]  ob [0:9215];
    integer    olen = 0;
    integer    n_arp_req = 0, n_arp_rep = 0, n_ping = 0, n_echo = 0, n_stream = 0, n_flow = 0;
    reg [15:0] exp_len [0:1023];      // expected echo payload length, per sequence number
    reg [7:0]  last_seed;
    integer    echo_ok = 0;

    function [15:0] g16(input integer o); g16 = {ob[o], ob[o+1]}; endfunction

    task check_frame;
        integer i, plen, seed, ihl;
        reg [31:0] s;
        begin
            if (g16(12) == 16'h0806) begin
                if (g16(20) == 1) n_arp_req = n_arp_req + 1; else begin n_arp_rep = n_arp_rep + 1; last_arp_spa = {g16(28), g16(30)}; end
                if (olen < 60) begin $display("  ARP frame %0d bytes", olen); end
            end else if (g16(12) == 16'h0800) begin
                // verify IP header checksum
                s = 0; for (i = 14; i < 34; i = i + 2) s = s + g16(i);
                while (s[31:16]) s = s[15:0] + s[31:16];
                if (s[15:0] != 16'hFFFF) fail("IP header checksum");
                if (ob[23] == 1) begin
                    n_ping = n_ping + 1;
                    if (ob[34] != 0) fail("ICMP type is not echo reply");
                    s = 0; for (i = 34; i < 14 + g16(16); i = i + 2) s = s + {ob[i], (i + 1 < 14 + g16(16)) ? ob[i+1] : 8'h00};
                    while (s[31:16]) s = s[15:0] + s[31:16];
                    if (s[15:0] != 16'hFFFF) fail("ICMP checksum");
                end else if (ob[23] == 17) begin
                    plen = g16(38) - 8;
                    if (g16(34) == 16'd1236) begin
                        n_stream = n_stream + 1;
                    end else begin
                        n_echo = n_echo + 1;
                        if (g16(36) >= 16'd6000 && g16(36) < 16'd6016) begin
                            // flow echo: sent to alias address ALIAS_IP + p, the reply must come from it
                            n_flow = n_flow + 1;
                            if (g16(34) != 16'd1234) fail("flow echo source port");
                            if ({g16(26), g16(28)} != ALIAS_IP + (g16(36) - 16'd6000)) fail("flow echo source IP");
                        end else begin
                            if (g16(36) != 16'd5000 && g16(36) != 16'd5001) fail("echo destination port");
                            if (g16(34) != (g16(36) == 16'd5000 ? 16'd1234 : 16'd1235)) fail("echo source port");
                            if ({g16(26), g16(28)} != FPGA_IP) fail("echo source IP");
                        end
                        // payload was (seed*7 + i*13); seed is in the source port pairing, recover from byte 0
                        seed = -1;
                        for (i = 0; i < 256; i = i + 1) if (((i * 7) & 8'hff) == ob[42]) seed = i;
                        for (i = 0; i < plen; i = i + 1)
                            if (ob[42+i] != ((seed * 7 + i * 13) & 8'hff)) begin
                                begin $display("  payload mismatch: udp_len=%0d frame=%0d sport=%0d byte %0d", g16(38), olen, g16(34), i); fail("echo payload"); i = plen; end
                            end
                        if (olen != 42 + plen && !(plen < 18 && olen == 60)) fail("echo frame length");
                        echo_ok = echo_ok + 1;
                    end
                end
            end
        end
    endtask

    integer k;
    always @(posedge clk) if (!rst && tx_tvalid && tx_tready) begin
        for (k = 0; k < 8; k = k + 1) if (tx_tkeep[k]) begin ob[olen] = tx_tdata[k*8 +: 8]; olen = olen + 1; end
        if (tx_tlast) begin
            if (tx_tuser) begin $display("  bad frame: %0d bytes udp_len=%0d", olen, g16(38)); fail("frame marked bad on TX"); end
            check_frame;
            olen = 0;
        end
    end

    // random MAC back-pressure when enabled
    reg backpressure = 0;
    always @(posedge clk) tx_tready <= backpressure ? ($random & 1) : 1'b1;

    // ---------------------------------------------------------------- stream source
    task send_stream(input integer words);
        integer w;
        begin
            st_len <= 8 + words * 8; st_hv <= 1;
            @(posedge clk); while (!st_hr) @(posedge clk);
            st_hv <= 0;
            for (w = 0; w < words; w = w + 1) begin
                st_d <= w; st_k <= 8'hff; st_v <= 1; st_l <= (w == words - 1);
                @(posedge clk); while (!st_r) @(posedge clk);
            end
            st_v <= 0; st_l <= 0;
        end
    endtask

    // ---------------------------------------------------------------- test sequence
    integer p, n0, t0;

    task burst(input integer count);
        integer q;
        begin
            for (q = 0; q < count; q = q + 1) begin
                build_udp(q[0] ? 16'd5001 : 16'd5000, q[0] ? 16'd1235 : 16'd1234,
                          (q % 5 == 0) ? 1 : (q % 7 == 0) ? 8192 : (q % 3 == 0) ? 1472 : 64 + q * 9,
                          (q % 200) + 3);
                send_frame;
            end
        end
    endtask

    task wait_echo(input integer base, input integer count);   // until all arrived or 1 ms idle
        integer last, idle;
        begin
            last = echo_ok; idle = 0;
            while (echo_ok - base < count && idle < 200000) begin
                @(posedge clk);
                if (echo_ok != last) begin last = echo_ok; idle = 0; end else idle = idle + 1;
            end
        end
    endtask
    initial begin
        rx_stall = 0;
        repeat (20) @(posedge clk); rst <= 0; repeat (20) @(posedge clk);

        // 1) UDP echo while the FPGA does not know our MAC: it must ARP for us, and the
        //    receive path must keep accepting frames meanwhile
        build_udp(16'd5000, 16'd1234, 100, 1); send_frame;
        build_udp(16'd5001, 16'd1235, 200, 2); send_frame;
        t0 = $time;
        wait (n_arp_req > 0);
        if (rx_stall > 1000) fail("receive path blocked while the peer MAC was unresolved");
        build_arp(16'd2, FPGA_MAC, FPGA_IP); send_frame;     // ARP reply to the FPGA
        wait (echo_ok >= 2);
        $display("PASS 1: echo with ARP resolution (ARP requests %0d, rx stall cycles %0d)", n_arp_req, rx_stall);

        // 2) ARP request for the FPGA
        n0 = n_arp_rep;
        build_arp(16'd1, 48'd0, FPGA_IP); send_frame;
        wait (n_arp_rep > n0);
        $display("PASS 2: ARP reply");

        // 3) ping: 32-byte (Windows default) and a 1000-byte request
        build_ping(16'd1, 32); send_frame;
        build_ping(16'd2, 1000); send_frame;
        wait (n_ping >= 2);
        $display("PASS 3: ICMP echo replies with valid checksums");

        // 4) burst: 120 back-to-back packets to 1234/1235 incl. tiny and jumbo, with stream
        //    packets interleaved; the MAC takes everything -> every packet must come back
        n0 = echo_ok;
        fork
            burst(120);
            repeat (10) send_stream(128);
        join
        wait_echo(n0, 120);
        if (echo_ok - n0 != 120) fail("not every burst packet was echoed");
        if (n_stream != 10) fail("stream packets missing");
        $display("PASS 4: %0d/120 burst packets echoed byte-exact, %0d stream packets", echo_ok - n0, n_stream);

        // 5) same burst with random MAC back-pressure (TX slower than RX): the echo may drop
        //    whole packets when its FIFO is full, but never corrupts or stalls
        backpressure = 1;
        n0 = echo_ok;
        burst(120);
        wait_echo(n0, 120);
        backpressure = 0;
        $display("PASS 5: overload: %0d/120 echoed, all byte-exact (rest dropped as whole packets)", echo_ok - n0);

        // 6) the path is still healthy afterwards
        n0 = echo_ok;
        burst(20);
        wait_echo(n0, 20);
        if (echo_ok - n0 != 20) fail("echo path not healthy after overload");
        else $display("PASS 6: 20/20 echoed after the overload");
        if (stream_dest_ip != PC_IP) fail("stream destination IP not latched");

        // 7) alias addresses: ARP for one is answered with it as sender; 16 jumbo packets to
        //    ALIAS_IP + p come back from ALIAS_IP + p; an address outside the block is not echoed
        n0 = n_arp_rep;
        build_arp(16'd1, 48'd0, ALIAS_IP + 12); send_frame;
        wait (n_arp_rep > n0);
        if (last_arp_spa != ALIAS_IP + 12) fail("ARP reply for an alias address");
        n0 = echo_ok;
        for (p = 0; p < 16; p = p + 1) begin dst_ip = ALIAS_IP + p; build_udp(16'd6000 + p, 16'd1234, 8956, p + 50); send_frame; end
        dst_ip = ALIAS_IP + 40; build_udp(16'd6016, 16'd1234, 100, 99); send_frame;
        dst_ip = FPGA_IP;
        wait_echo(n0, 17);
        if (n_flow != 16 || echo_ok - n0 != 16) fail("alias echo");
        else $display("PASS 7: ARP for an alias address; 16/16 echoes from their alias address, byte-exact; outside the block ignored");

        if (errors == 0) $display("\n*** udp_stack: ALL TESTS PASSED ***");
        else             $display("\n*** udp_stack: %0d ERRORS ***", errors);
        $finish;
    end

    initial begin #60000000 $display("TIMEOUT (echo_ok=%0d ping=%0d arp_req=%0d)", echo_ok, n_ping, n_arp_req); $finish; end
endmodule
