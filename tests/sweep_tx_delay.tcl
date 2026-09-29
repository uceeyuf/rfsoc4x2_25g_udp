# tx_delay sweep: for each packet gap, stream from the FPGA and measure with the
# Python receiver (pc/capture_bin.py) and the C++ RIO receiver (tests/rio_rx).
#
#   vivado -mode batch -source tests/sweep_tx_delay.tcl [-tclargs <seconds> <delay list...>]
#
# Needs: FPGA programmed with build/fpga.bit, build/fpga.ltx, tests/rio_rx/rio_udp_rx.exe.
# Output: build/sweep_tx_delay.csv and a table on stdout.

set repo_dir [file normalize [file join [file dirname [info script]] ..]]
set secs   [expr {$argc > 0 ? [lindex $argv 0] : 5}]
set delays [expr {$argc > 1 ? [lrange $argv 1 end] : {16 8 4 2 1 0}}]
# (not $::env(PYTHON): Vivado sets that to its own python directory)
set python [expr {[info exists ::env(RX_PYTHON)] ? $::env(RX_PYTHON) : "C:/Xilinx/Vivado/2023.2/tps/win64/python-3.8.3/python.exe"}]
set rio_exe [file join $repo_dir tests rio_rx rio_udp_rx.exe]
set pkt_bytes 1032

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
set_property OUTPUT_VALUE_RADIX UNSIGNED $p_delay

proc set_vio {probe val} {
    set_property OUTPUT_VALUE $val $probe
    commit_hw_vio $probe
}

# Python: run capture_bin.main() without writing to disk, report packets/lost.
set py_code "import sys, capture_bin as c; c.WRITE_FILE=False; sys.argv=\['x','$secs'\]; c.main(); print('RESULT', c._stat\['rpkts'\], c._stat\['lost'\])"

set rows {}
lappend rows [list tx_delay rx fpga_tx_gbps rx_gbps loss_pct rx_pkts lost_pkts]

set_vio $p_en 0
foreach d $delays {
    set_vio $p_delay $d
    set_vio $p_en 1
    after 1000

    # --- C++ RIO
    set out [exec -ignorestderr $rio_exe $secs]
    regexp {received\s+(\d+) pkts} $out -> rpk
    regexp {time\s+([0-9.]+) s} $out -> t
    regexp {lost \(by seq\)\s+(\d+)} $out -> lost
    set fpga [expr {($rpk + $lost) * $pkt_bytes * 8.0 / $t / 1e9}]
    set rx   [expr {$rpk * $pkt_bytes * 8.0 / $t / 1e9}]
    set loss [expr {100.0 * $lost / ($rpk + $lost)}]
    lappend rows [list $d rio [format %.2f $fpga] [format %.2f $rx] [format %.3f $loss] $rpk $lost]
    puts [format "tx_delay=%-3s RIO    FPGA TX %6.2f Gbps  RX %6.2f Gbps  loss %7.3f%%" $d $fpga $rx $loss]

    # --- Python socket (capture_bin.py)
    set cwd [pwd]
    cd [file join $repo_dir pc]
    set ::env(PYTHONIOENCODING) utf-8
    set out [exec -ignorestderr $python -c $py_code]
    cd $cwd
    regexp {RESULT (\d+) (\d+)} $out -> rpk lost
    # capture_bin measures a fixed window of $secs seconds from the first packet
    set fpga [expr {($rpk + $lost) * $pkt_bytes * 8.0 / $secs / 1e9}]
    set rx   [expr {$rpk * $pkt_bytes * 8.0 / $secs / 1e9}]
    set loss [expr {($rpk + $lost) ? 100.0 * $lost / ($rpk + $lost) : 0}]
    lappend rows [list $d python [format %.2f $fpga] [format %.2f $rx] [format %.3f $loss] $rpk $lost]
    puts [format "tx_delay=%-3s Python FPGA TX %6.2f Gbps  RX %6.2f Gbps  loss %7.3f%%" $d $fpga $rx $loss]
}
set_vio $p_en 0

set csv [file join $repo_dir build sweep_tx_delay.csv]
set f [open $csv w]
foreach r $rows { puts $f [join $r ,] }
close $f

puts "\n==================== tx_delay sweep (1032-B UDP payload, ${secs}s per point) ===================="
puts [format "%-9s %-7s %14s %12s %10s %12s %12s" tx_delay rx "FPGA_TX(Gbps)" "RX(Gbps)" "loss(%)" rx_pkts lost_pkts]
foreach r [lrange $rows 1 end] {
    puts [format "%-9s %-7s %14s %12s %10s %12s %12s" {*}$r]
}
puts "csv: $csv"
