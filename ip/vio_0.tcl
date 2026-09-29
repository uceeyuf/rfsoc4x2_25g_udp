# Stream control: in0 = txstate[3:0]; out0 = tx_speed_en, out1 = tx_length[15:0], out2 = tx_delay[15:0]
create_ip -name vio -vendor xilinx.com -library ip -module_name vio_0
set_property -dict [list \
    CONFIG.C_NUM_PROBE_IN {1} \
    CONFIG.C_PROBE_IN0_WIDTH {4} \
    CONFIG.C_NUM_PROBE_OUT {3} \
    CONFIG.C_PROBE_OUT0_WIDTH {1} \
    CONFIG.C_PROBE_OUT1_WIDTH {16} \
    CONFIG.C_PROBE_OUT2_WIDTH {16} \
    CONFIG.C_PROBE_OUT1_INIT_VAL {0x0000} \
    CONFIG.C_PROBE_OUT2_INIT_VAL {0x0000} \
    CONFIG.C_EN_PROBE_IN_ACTIVITY {0} \
] [get_ips vio_0]
