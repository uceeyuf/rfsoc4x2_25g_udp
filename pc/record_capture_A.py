#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
方案 A —— 定长记录 限速无损 接收 / 存储 / 显示完整波形

适用：一段“唯一、不重复”的记录（例如 DDR 里的 100 万样本），FPGA 限速发一遍，
      PC 一个不丢地全收下来，按样本序号拼回完整数组，存盘并显示整段波形。

配合 FPGA 端 record_udp_tx.v 使用。包格式（UDP payload）：
    [ 8 字节包头 ][ 数据 ... ]
    包头: 小端 uint32 start_index  + 小端 uint32 total_samples
          start_index   = 本包首样本在整段记录中的样本序号（0 起）
          total_samples = 整段记录的总样本数（让 PC 知道要收多大、何时收齐）
    数据: int16 有符号 cos/sin 交错: cos,sin,cos,sin,...（每样本 32bit）

用法：
    1) PC 与 FPGA 同网段（FPGA 默认 192.168.100.1）。
    2) python record_capture_A.py
       会先发注册包让 FPGA 锁存 PC 的 IP。
    3) 在 Vivado 把 VIO 的 tx_speed_en 由 0 拉到 1（上升沿触发一次性发送）。
    4) 收齐 total_samples 后自动停止，存 record_A.bin 并画整段波形。
       只画已有文件： python record_capture_A.py plot
"""

import socket
import struct
import sys
import time

import numpy as np
import matplotlib
matplotlib.rcParams["font.sans-serif"] = ["Microsoft YaHei", "SimHei", "SimSun"]
matplotlib.rcParams["axes.unicode_minus"] = False

# ------------------- 配置 -------------------
FPGA_IP     = "192.168.100.1"
LISTEN_PORT = 1237
REG_PORT    = 1237
RECV_BUF    = 64 * 1024 * 1024
FS          = 125e6
OUT_FILE    = "record_A.bin"
IDLE_TIMEOUT = 5.0          # 多少秒收不到新包就认为发完/卡住
# -------------------------------------------


def capture():
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)   # 允许复用端口，避免 10048
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, RECV_BUF)
    try:
        sock.bind(("0.0.0.0", LISTEN_PORT))
    except OSError as e:
        print(f"[X] 绑定端口 {LISTEN_PORT} 失败：{e}")
        print("    上次运行的 socket 还占着端口。Spyder 里请『重启 kernel』后再跑；")
        print("    或确认没有另一个脚本/抓包工具在用 1237 端口。")
        sock.close()
        return None
    sock.settimeout(IDLE_TIMEOUT)

    sock.sendto(b"REG", (FPGA_IP, REG_PORT))
    print(f"[i] 已向 {FPGA_IP}:{REG_PORT} 发送注册包")
    print("[i] 请在 Vivado 把 tx_speed_en 由 0 拉到 1 触发发送 ...")

    buf = None            # int16 平铺: [cos0,sin0,cos1,sin1,...]，长度 2*total
    filled = None         # 每个样本是否已收到
    total = None
    pkts = 0
    t0 = None

    while True:
        try:
            data, addr = sock.recvfrom(4096)
        except socket.timeout:
            if buf is None:
                print("[!] 一直没收到数据，检查网络/IP/防火墙/tx_speed_en")
                sock.close()
                return None
            print(f"[!] {IDLE_TIMEOUT}s 无新包，结束接收")
            break

        if len(data) < 8:
            continue
        start_index, total_samples = struct.unpack_from("<II", data, 0)

        if buf is None:
            # 护栏：total 不合理 => 多半连到了旧的连续 DDS 流（无包头），别盲目申请大内存
            if not (1 <= total_samples <= 100_000_000):
                print(f"[X] 包头异常 total_samples={total_samples}（start_index={start_index}）")
                print("    这通常说明 FPGA 跑的不是 record_udp_tx，而是旧的连续 DDS bitstream。")
                print("    请重新综合/实现/下载带 record_udp_tx 的设计后再试。")
                sock.close()
                return None
            total = total_samples
            buf = np.zeros(2 * total, dtype="<i2")
            filled = np.zeros(total, dtype=bool)
            t0 = time.time()
            print(f"[i] 来自 {addr}，整段 {total} 样本（{total*4/1024/1024:.2f} MB），开始接收")

        s16 = np.frombuffer(data, dtype="<i2", offset=8)
        npairs = len(s16) // 2
        if start_index + npairs > total:        # 越界保护
            npairs = max(0, total - start_index)
        if npairs > 0:
            buf[start_index * 2: (start_index + npairs) * 2] = s16[: npairs * 2]
            filled[start_index: start_index + npairs] = True

        pkts += 1
        if pkts % 1000 == 0:
            print(f"    收到 {filled.sum()}/{total} 样本  {pkts} 包")
        if filled.all():
            print("[✓] 已收齐全部样本")
            break

    dt = (time.time() - t0) if t0 else 0
    miss = int(total - filled.sum())
    print(f"[✓] 共 {pkts} 包，用时 {dt:.2f}s")
    if miss == 0:
        print("[✓] 无丢失，记录完整")
    else:
        print(f"[!] 丢失 {miss} 样本（{miss/total*100:.3f}%）—— 可调大 FPGA 的 GAP_CYCLES 降速")
    buf.tofile(OUT_FILE)
    print(f"[✓] 已保存 {OUT_FILE}")
    sock.close()
    return OUT_FILE


def _minmax_decimate(y, n_seg):
    """把长序列压成 n_seg 段的 min/max 包络，保留毛刺，适合总览。"""
    n = len(y)
    if n <= n_seg * 2:
        x = np.arange(n)
        return x, y, x, y
    seg = n // n_seg
    m = seg * n_seg
    yy = y[:m].reshape(n_seg, seg)
    xs = (np.arange(n_seg) * seg + seg // 2)
    return xs, yy.min(axis=1), xs, yy.max(axis=1)


def plot(path):
    buf = np.fromfile(path, dtype="<i2")
    buf = buf[: (len(buf) // 2) * 2]
    cos = buf[0::2]
    sin = buf[1::2]
    n = len(cos)
    print(f"[i] 整段样本数: {n}")

    fig, (ax_all, ax_zoom) = plt.subplots(2, 1, figsize=(12, 8))

    # 总览：min/max 抽取到 ~4000 段
    xc, lo_c, _, hi_c = _minmax_decimate(cos, 4000)
    ax_all.fill_between(xc, lo_c, hi_c, step="mid", alpha=0.7, label="cos 包络")
    xs, lo_s, _, hi_s = _minmax_decimate(sin, 4000)
    ax_all.fill_between(xs, lo_s, hi_s, step="mid", alpha=0.5, label="sin 包络")
    ax_all.set_title(f"整段记录总览（{n} 样本，min/max 抽取）")
    ax_all.set_xlabel("sample index")
    ax_all.set_ylabel("amplitude (int16)")
    ax_all.legend(loc="upper right")
    ax_all.grid(True)

    # 细节：前 2000 点（可在窗口里用工具栏放大平移看任意局部）
    m = min(2000, n)
    t = np.arange(m) / FS * 1e6
    ax_zoom.plot(t, cos[:m], lw=0.9, label="cos")
    ax_zoom.plot(t, sin[:m], lw=0.9, label="sin")
    ax_zoom.set_title(f"局部细节（前 {m} 点 @125MSps，用工具栏可缩放查看全段）")
    ax_zoom.set_xlabel("time (us)")
    ax_zoom.set_ylabel("amplitude (int16)")
    ax_zoom.legend(loc="upper right")
    ax_zoom.grid(True)

    fig.tight_layout()
    fig.savefig("record_A.png", dpi=120)
    print("[✓] 图已保存 record_A.png")
    plt.show()


if __name__ == "__main__":
    import matplotlib.pyplot as plt  # 延后导入，避免无显示环境报错
    if len(sys.argv) > 1 and sys.argv[1] == "plot":
        plot(sys.argv[2] if len(sys.argv) > 2 else OUT_FILE)
    else:
        f = capture()
        if f:
            plot(f)
