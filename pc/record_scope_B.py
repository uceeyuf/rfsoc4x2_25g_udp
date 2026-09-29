#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
方案 B —— 循环不停发 + PC 示波器式实时重组显示（按键停止）

适用：FPGA 把同一段记录（如 DDS 采集进 BRAM 的那段，或将来 DDR 里的记录）循环不停地发，
      PC 后台不停收，按包头里的 start_index 把碎片填进一个“整段数组”，定时重画。
      4Gbps 收不全没关系——每一圈补一些，覆盖率随扫描累积上升，波形逐渐填满/刷新。

与 record_capture_A.py 共用同一包格式：
    [ 8 字节包头: <uint32 start_index><uint32 total_samples> ][ int16 cos,sin,cos,sin... ]

需要 FPGA 端 record_udp_tx 的 LOOP=1（fpga_core 里 REC_LOOP=1）。

用法：
    1) PC 与 FPGA 同网段（FPGA 默认 192.168.100.1）。
    2) python record_scope_B.py
    3) Vivado 把 VIO 的 tx_speed_en 由 0 拉到 1 触发循环发送。
    4) ★窗口里按 'c' 清空重新累积；按其它任意键（或关窗口）停止。
"""

import socket
import struct
import threading
import time

import numpy as np
import matplotlib
for _bk in ("QtAgg", "Qt5Agg", "TkAgg"):
    try:
        matplotlib.use(_bk, force=True)
        break
    except Exception:
        continue
import matplotlib.pyplot as plt
matplotlib.rcParams["font.sans-serif"] = ["Microsoft YaHei", "SimHei", "SimSun"]
matplotlib.rcParams["axes.unicode_minus"] = False

# ------------------- 配置 -------------------
FPGA_IP     = "192.168.100.1"
LISTEN_PORT = 1237
REG_PORT    = 1237
RECV_BUF    = 64 * 1024 * 1024
FS          = 125e6
REFRESH_MS  = 150
MAX_TOTAL   = 100_000_000     # 护栏：total 超过此值判为连错了流
# -------------------------------------------

_lock = threading.Lock()
_state = {"buf": None, "filled": None, "total": None}
_stats = {"pkts": 0, "t0": None}
_stop = threading.Event()
_clear = threading.Event()


def receiver():
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, RECV_BUF)
    try:
        sock.bind(("0.0.0.0", LISTEN_PORT))
    except OSError as e:
        print(f"[X] 绑定端口失败：{e}（Spyder 里重启 kernel 再试）")
        return
    sock.settimeout(0.5)
    sock.sendto(b"REG", (FPGA_IP, REG_PORT))
    print(f"[i] 已向 {FPGA_IP}:{REG_PORT} 发注册包；请在 Vivado 把 tx_speed_en 置 1（需 REC_LOOP=1）")

    while not _stop.is_set():
        if _clear.is_set():
            with _lock:
                if _state["filled"] is not None:
                    _state["filled"][:] = False
                    _state["buf"][:] = 0
            _stats["pkts"] = 0
            _stats["t0"] = None
            _clear.clear()
        try:
            data, _ = sock.recvfrom(4096)
        except socket.timeout:
            continue
        except OSError:
            break
        if len(data) < 8:
            continue
        start_index, total_samples = struct.unpack_from("<II", data, 0)

        with _lock:
            if _state["buf"] is None:
                if not (1 <= total_samples <= MAX_TOTAL):
                    print(f"[X] 包头异常 total={total_samples}，多半连到了无包头的旧流，已停。")
                    _stop.set()
                    break
                _state["total"] = total_samples
                _state["buf"] = np.zeros(2 * total_samples, dtype="<i2")
                _state["filled"] = np.zeros(total_samples, dtype=bool)
                _stats["t0"] = time.time()
                print(f"[i] 整段 {total_samples} 样本，开始累积显示")

            total = _state["total"]
            s16 = np.frombuffer(data, dtype="<i2", offset=8)
            npairs = len(s16) // 2
            if start_index + npairs > total:
                npairs = max(0, total - start_index)
            if npairs > 0:
                _state["buf"][start_index * 2:(start_index + npairs) * 2] = s16[:npairs * 2]
                _state["filled"][start_index:start_index + npairs] = True
        _stats["pkts"] += 1
    sock.close()


def _minmax(y, n_seg):
    n = len(y)
    if n <= n_seg * 2:
        x = np.arange(n)
        return x, y, y
    seg = n // n_seg
    m = seg * n_seg
    yy = y[:m].reshape(n_seg, seg)
    xs = np.arange(n_seg) * seg + seg // 2
    return xs, yy.min(axis=1), yy.max(axis=1)


def main():
    th = threading.Thread(target=receiver, daemon=True)
    th.start()

    # 2x2：左列 cos、右列 sin；上行整段总览、下行细节
    fig, ((ax_cos_all, ax_sin_all), (ax_cos_z, ax_sin_z)) = plt.subplots(2, 2, figsize=(14, 8))
    fig.suptitle("方案B 示波器式实时重组  —  按 'c' 清空重累积，其它键停止")

    def on_key(event):
        if event.key == "c":
            _clear.set()
            print("[i] 清空，重新累积")
        else:
            print(f"[i] 按下 '{event.key}'，停止。")
            _stop.set()
            plt.close(fig)

    fig.canvas.mpl_connect("key_press_event", on_key)
    fig.canvas.mpl_connect("close_event", lambda e: _stop.set())

    plt.ion()
    fig.show()
    while not _stop.is_set() and plt.fignum_exists(fig.number):
        with _lock:
            buf = _state["buf"]
            filled = _state["filled"]
            total = _state["total"]
            cov = float(filled.mean()) if filled is not None else 0.0
            cos = buf[0::2].copy() if buf is not None else None
            sin = buf[1::2].copy() if buf is not None else None

        if cos is not None:
            m = min(2000, len(cos))
            t = np.arange(m) / FS * 1e6

            # ---- cos：总览(min/max) + 细节 ----
            ax_cos_all.cla()
            xc, lo_c, hi_c = _minmax(cos, 4000)
            ax_cos_all.fill_between(xc, lo_c, hi_c, step="mid", color="C0")
            ax_cos_all.set_title(f"cos 整段总览   {total} 样本  覆盖率 {cov*100:.1f}%  收包 {_stats['pkts']}")
            ax_cos_all.set_xlabel("sample index"); ax_cos_all.set_ylabel("int16"); ax_cos_all.grid(True)

            ax_cos_z.cla()
            ax_cos_z.plot(t, cos[:m], lw=0.9, color="C0")
            ax_cos_z.set_title(f"cos 细节（前 {m} 点 @125MSps）")
            ax_cos_z.set_xlabel("time (us)"); ax_cos_z.set_ylabel("int16"); ax_cos_z.grid(True)

            # ---- sin：总览(min/max) + 细节 ----
            ax_sin_all.cla()
            xs, lo_s, hi_s = _minmax(sin, 4000)
            ax_sin_all.fill_between(xs, lo_s, hi_s, step="mid", color="C1")
            ax_sin_all.set_title("sin 整段总览")
            ax_sin_all.set_xlabel("sample index"); ax_sin_all.set_ylabel("int16"); ax_sin_all.grid(True)

            ax_sin_z.cla()
            ax_sin_z.plot(t, sin[:m], lw=0.9, color="C1")
            ax_sin_z.set_title(f"sin 细节（前 {m} 点）")
            ax_sin_z.set_xlabel("time (us)"); ax_sin_z.set_ylabel("int16"); ax_sin_z.grid(True)

            fig.tight_layout()

        plt.pause(REFRESH_MS / 1000.0)

    _stop.set()
    th.join(timeout=1.0)
    print("[✓] 已退出。")


if __name__ == "__main__":
    main()
