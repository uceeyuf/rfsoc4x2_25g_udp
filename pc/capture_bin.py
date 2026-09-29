#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
高吞吐 UDP → .bin 落盘测试（不解析、不画图，专测 PC 能无损存多少 Gbps）

优化：
  - 大 SO_RCVBUF
  - recv_into 零拷贝，收进块池里的大块
  - 独立写盘线程，整块(8MB)批量写 NVMe，收/写重叠
  - 用包头 start_index 统计丢包率（FPGA 端 record_udp_tx 的 8 字节序号头）

配合当前 FPGA：每包 1032 字节(8 头 + 1024 数据)，256 样本/包，记录 1048576 样本循环。
用法：
  python capture_bin.py            # 默认抓 DURATION 秒
  python capture_bin.py 10         # 抓 10 秒
跑起来后到 Vivado 把 tx_speed_en 置 1。
"""

import socket
import sys
import threading
import time
import queue

import numpy as np

# ------------------- 配置 -------------------
FPGA_IP        = "192.168.100.1"
LISTEN_PORT    = 1237
REG_PORT       = 1237
OUT_FILE       = "capture.bin"
DURATION_S     = 5.0                    # 抓多少秒
RCVBUF         = 256 * 1024 * 1024      # 内核接收缓冲(尽量大；Windows 可能封顶)
BLOCK          = 8 * 1024 * 1024        # 每块 8MB，整块写盘
NBLOCKS        = 16                     # 块池大小（收/写重叠的缓冲深度）
PKT_BYTES      = 1032                   # 8 头 + 1024 数据
SAMPLES_PER_PKT = 256
TOTAL_SAMPLES  = 1048576
WRITE_FILE     = True                   # False = 只收不落盘(测纯接收上限)
# -------------------------------------------

free_q = queue.Queue()      # 空闲块
full_q = queue.Queue()      # 待写块 (block, length)
_stat = {"wbytes": 0, "lost": 0, "rpkts": 0, "prev": None}
_stop = threading.Event()


def writer():
    f = open(OUT_FILE, "wb", buffering=0) if WRITE_FILE else None
    while not (_stop.is_set() and full_q.empty()):
        try:
            block, length = full_q.get(timeout=0.5)
        except queue.Empty:
            continue
        if f is not None:
            f.write(memoryview(block)[:length])
        _stat["wbytes"] += length
        # 丢包统计（numpy 向量化）：每 PKT_BYTES 一个包，前 4 字节 = start_index
        n = length // PKT_BYTES
        if n:
            a = np.frombuffer(block, dtype=np.uint8, count=n * PKT_BYTES).reshape(n, PKT_BYTES)
            idx = a[:, 0:4].copy().view("<u4").ravel().astype(np.int64)  # 每包 start_index
            if n >= 2:
                exp = (idx[:-1] + SAMPLES_PER_PKT) % TOTAL_SAMPLES
                gaps = (idx[1:] - exp) % TOTAL_SAMPLES
                _stat["lost"] += int((gaps // SAMPLES_PER_PKT).sum())
            if _stat["prev"] is not None:
                exp0 = (_stat["prev"] + SAMPLES_PER_PKT) % TOTAL_SAMPLES
                _stat["lost"] += int(((int(idx[0]) - exp0) % TOTAL_SAMPLES) // SAMPLES_PER_PKT)
            _stat["prev"] = int(idx[-1])
            _stat["rpkts"] += n
        free_q.put(block)
    if f is not None:
        f.close()


def main():
    dur = float(sys.argv[1]) if len(sys.argv) > 1 else DURATION_S

    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, RCVBUF)
    actual = sock.getsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF)
    print(f"[i] SO_RCVBUF = {actual/1024/1024:.1f} MB（请求 {RCVBUF/1024/1024:.0f}）")
    sock.bind(("0.0.0.0", LISTEN_PORT))
    sock.settimeout(1.0)

    for _ in range(NBLOCKS):
        free_q.put(bytearray(BLOCK))

    th = threading.Thread(target=writer, daemon=True)
    th.start()

    sock.sendto(b"REG", (FPGA_IP, REG_PORT))
    print(f"[i] 已注册到 {FPGA_IP}:{REG_PORT}；请置 tx_speed_en=1。抓 {dur:.0f}s ...")

    rbytes = 0
    t0 = None
    drops_overflow = 0
    try:
        while not _stop.is_set():
            try:
                block = free_q.get(timeout=1.0)
            except queue.Empty:
                drops_overflow += 1     # 写盘跟不上，块池空 → 这期间必然丢包
                continue
            mv = memoryview(block)
            offset = 0
            # 填满一块（留一个包的余量）
            while offset <= BLOCK - 2048:
                try:
                    nb = sock.recv_into(mv[offset:])
                except socket.timeout:
                    break
                if t0 is None:
                    t0 = time.time()
                    print("[i] 开始收数 ...")
                offset += nb
                rbytes += nb
                if t0 and (time.time() - t0) >= dur:
                    _stop.set()
                    break
            full_q.put((block, offset))
    except KeyboardInterrupt:
        _stop.set()

    dt = (time.time() - t0) if t0 else 0
    th.join(timeout=5.0)
    sock.close()

    print("\n========== 结果 ==========")
    if dt <= 0:
        print("[!] 没收到数据。检查网络/IP/防火墙/tx_speed_en")
        return
    rgbps = rbytes * 8 / dt / 1e9
    wgbps = _stat["wbytes"] * 8 / dt / 1e9
    rcvd = _stat["rpkts"]
    lost = _stat["lost"]
    lossp = lost / (rcvd + lost) * 100 if (rcvd + lost) else 0
    print(f"用时           {dt:.2f} s")
    print(f"接收           {rbytes/1e9:.2f} GB   = {rgbps:.2f} Gbps")
    print(f"落盘           {_stat['wbytes']/1e9:.2f} GB   = {wgbps:.2f} Gbps  "
          f"({'写文件' if WRITE_FILE else '只收不写'})")
    print(f"收到包         {rcvd}")
    print(f"丢包(按序号)   {lost}   丢包率 {lossp:.3f}%")
    if drops_overflow:
        print(f"[!] 块池空 {drops_overflow} 次：写盘/CPU 跟不上接收 → 这是瓶颈")
    if lossp < 0.01:
        print(">>> 基本无损：PC 能在这个速率下无损落盘 <<<")
    else:
        print(">>> 有丢包：此速率超过 PC 无损落盘能力（看是内核缓冲还是写盘瓶颈）<<<")


if __name__ == "__main__":
    main()
