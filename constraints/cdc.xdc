# Clock-domain-crossing constraints for this project's own synchronizers.
#
# Async FIFOs and sync_reset instances from verilog-ethernet/verilog-axis are constrained
# per instance by third_party/verilog-ethernet/lib/axis/syn/vivado/{axis_async_fifo,sync_reset}.tcl
# (added to constrs_1 by scripts/create_project.tcl).
#
# Here: quasi-static level signals (trig / calib_done) re-timed with two ASYNC_REG flops.
# Every such synchronizer register is named *_cdc_sr; only its first stage is cut.
set_false_path -to [get_cells -hier -filter {NAME =~ *_cdc_sr_reg[0]}]
