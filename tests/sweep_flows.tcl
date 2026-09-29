# RSS flow-count sweep: stream at full rate (tx_delay=0) and rotate each packet over N
# UDP flows (VIO tx_length[4:0] = N, tx_length[5] = also rotate the source IP).
# Receiver: tests/rio_rx/rio_udp_rx.exe with one RIO queue + thread per flow.
# While receiving, samples per-core DPC time to show how many cores do the kernel RX work.
#
#   vivado -mode batch -source tests/sweep_flows.tcl [-tclargs <seconds> <flow list...>]
#
# Optional environment: SWEEP_DELAYS  (tx_delay list, default "0"),
#                       SWEEP_MODES   (0 = rotate ports only, 1 = ports + source IP; default "0 1"),
#                       SWEEP_JUMBO   (1 = 8200-B jumbo packets via tx_length[11]; default 0),
#                       SWEEP_THREADS (RIO polling threads; default min(flows, 8)).
#
# Output: build/sweep_flows.csv and a table on stdout.

set repo_dir [file normalize [file join [file dirname [info script]] ..]]
set secs  [expr {$argc > 0 ? [lindex $argv 0] : 6}]
set flows [expr {$argc > 1 ? [lrange $argv 1 end] : {1 2 4 8}}]
set delays [expr {[info exists ::env(SWEEP_DELAYS)] ? $::env(SWEEP_DELAYS) : 0}]
set modes  [expr {[info exists ::env(SWEEP_MODES)]  ? $::env(SWEEP_MODES)  : {0 1}}]
set rio_exe [file join $repo_dir tests rio_rx rio_udp_rx.exe]
set jumbo   [expr {[info exists ::env(SWEEP_JUMBO)]   ? $::env(SWEEP_JUMBO)   : 0}]
set threads [expr {[info exists ::env(SWEEP_THREADS)] ? $::env(SWEEP_THREADS) : 0}]
set pkt_bytes [expr {$jumbo ? 8200 : 1032}]

open_hw_manager
connect_hw_server -allow_non_jtag
open_hw_target
set dev [lindex [get_hw_devices xczu48dr*] 0]
current_hw_device $dev
set ltx [file join $repo_dir build fpga.ltx]
set_property PROBES.FILE $ltx $dev
set_property FULL_PROBES.FILE $ltx $dev
refresh_hw_device $dev
set vio [get_hw_vios -of_objects $dev]
set p_en    [get_hw_probes core_inst/tx_speed_en -of_objects $vio]
set p_delay [get_hw_probes core_inst/tx_delay    -of_objects $vio]
set p_len   [get_hw_probes core_inst/tx_length   -of_objects $vio]
set_property OUTPUT_VALUE_RADIX UNSIGNED $p_delay
set_property OUTPUT_VALUE_RADIX UNSIGNED $p_len

proc set_vio {probe val} {
    set_property OUTPUT_VALUE $val $probe
    commit_hw_vio $probe
}

# cores whose DPC time exceeds 20 % over a 2 s window
set dpc_ps {(Get-Counter '\Processor(*)\% DPC Time' -SampleInterval 2 -MaxSamples 1).CounterSamples | ? { $_.InstanceName -ne '_total' -and $_.CookedValue -gt 20 } | % { '{0}:{1:N0}' -f $_.InstanceName, $_.CookedValue }}

set rows {}
lappend rows [list mode tx_delay flows fpga_tx_gbps rx_gbps rx_mpps loss_pct busy_dpc_cores]

set_vio $p_en 0
foreach d $delays {
foreach vary_ip $modes {
    foreach n $flows {
        set_vio $p_en 0
        set_vio $p_delay $d
        set_vio $p_len [expr {$n | ($vary_ip << 5) | ($jumbo << 11)}]
        set_vio $p_en 1
        after 1000

        set log [file join $repo_dir build rio_flows_${d}_${vary_ip}_$n.txt]
        set pid [exec $rio_exe $secs $n [expr {$threads ? $threads : ($n < 8 ? $n : 8)}] > $log &]
        after 2000
        set dpc [string trim [exec powershell -NoProfile -Command $dpc_ps]]
        after [expr {int($secs * 1000)}]
        # wait for the receiver to finish
        for {set i 0} {$i < 50 && [catch {exec tasklist /FI "PID eq $pid" /NH} tl] == 0 && [string match "*rio_udp_rx*" $tl]} {incr i} {
            after 200
        }
        set f [open $log r]; set out [read $f]; close $f

        regexp {received\s+(\d+) pkts} $out -> rpk
        regexp {time\s+([0-9.]+) s} $out -> t
        regexp {lost \(by seq\)\s+(\d+)} $out -> lost
        set fpga [expr {($rpk + $lost) * $pkt_bytes * 8.0 / $t / 1e9}]
        set rx   [expr {$rpk * $pkt_bytes * 8.0 / $t / 1e9}]
        set mpps [expr {$rpk / $t / 1e6}]
        set loss [expr {100.0 * $lost / ($rpk + $lost)}]
        set mode [expr {$vary_ip ? "port+ip" : "port"}]
        set ncores [llength [split $dpc "\n"]]
        if {$dpc eq ""} { set ncores 0 }
        lappend rows [list $mode $d $n [format %.2f $fpga] [format %.2f $rx] [format %.3f $mpps] [format %.3f $loss] "$ncores ([join [split $dpc "\n"] { }])"]
        puts [format "%-8s delay=%-3s flows=%-2s FPGA TX %6.2f Gbps  RX %6.2f Gbps  %5.3f Mpps  loss %7.3f%%  DPC cores: %s" \
              $mode $d $n $fpga $rx $mpps $loss [join [split $dpc "\n"] { }]]
    }
}
}
set_vio $p_en 0
set_vio $p_len 0

set csv [file join $repo_dir build sweep_flows.csv]
set f [open $csv w]
foreach r $rows { puts $f [join $r ,] }
close $f

puts "\n=========== RSS flow sweep (${pkt_bytes}-B UDP payload, RIO, ${secs}s per point) ==========="
puts [format "%-8s %-8s %-5s %13s %9s %8s %9s  %s" mode tx_delay flows "FPGA_TX(Gbps)" "RX(Gbps)" "RX_Mpps" "loss(%)" "cores with DPC>20% (core:%)"]
foreach r [lrange $rows 1 end] {
    puts [format "%-8s %-8s %-5s %13s %9s %8s %9s  %s" {*}$r]
}
puts "csv: $csv"
