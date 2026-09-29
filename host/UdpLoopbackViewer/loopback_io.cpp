// loopback_io.dll - packet engine of UdpLoopbackViewer (Windows Registered I/O).
//
// Sends test video frames to the FPGA echo port(s), receives the echoed packets,
// reassembles the frames and compares every frame byte by byte with what was sent.
//
// Packet = 16-byte header + frame bytes:
//   u32 magic 'RFLB' | u32 frame id | u16 packet index | u16 packet count | u32 byte offset
//
// Packet k of a frame goes out on flow k mod F: socket i sends to address ip+i, same port.
// The FPGA answers for a block of alias addresses and echoes from the address a packet was
// sent to, so the replies of flow i come from ip+i: a NIC that hashes receive queues on IP
// addresses only (RSS on Windows) still spreads the flows, and every reply comes from the
// address it was sent to (no firewall rule needed).
//
// Frames are pre-split into packets once (cycle of C frames); for frame n only the 4-byte
// frame id of each packet is patched before it is sent, so the send path copies nothing.
// Packets of a frame are spread evenly over `spread` x the frame interval.

#define WIN32_LEAN_AND_MEAN
#include <winsock2.h>
#include <ws2tcpip.h>
#include <mswsock.h>
#include <windows.h>

#include <immintrin.h>

#include <atomic>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <thread>
#include <vector>

#pragma comment(lib, "ws2_32.lib")

#define LB_API extern "C" __declspec(dllexport)

struct lb_config {
    char     ip[32];
    int      port;          // FPGA UDP port
    int      flows;         // sockets; flow i sends to ip + i
    int      width, height; // RGB24 frame
    int      payload;       // frame bytes per packet
    int      cycle;         // frames rendered by the caller, sent in turn
    int      rx_threads;
    int      tx_threads;
};

struct lb_stats {
    int64_t frames_sent, frames_ok, frames_bad, packets_sent, packets_recv, bytes_sent, bytes_recv;
    double  tx_seconds, rx_seconds, latency_avg_ms, latency_max_ms;
    int32_t running, packets_per_frame;
};

static const uint32_t MAGIC     = 0x424C4652;   // "RFLB"
static const int      HDR       = 16;
static const DWORD    SLOT      = 9216;         // receive slot, >= any packet
static const DWORD    RX_SLOTS  = 2048;         // receive buffers posted per flow
static const DWORD    TX_DEPTH  = 1024;         // outstanding sends per flow
static const DWORD    CQ_BATCH  = 512;

static RIO_EXTENSION_FUNCTION_TABLE rio;
static char g_err[256];

static double qpc_s()
{
    static LARGE_INTEGER f = {};
    if (!f.QuadPart) QueryPerformanceFrequency(&f);
    LARGE_INTEGER c;
    QueryPerformanceCounter(&c);
    return (double)c.QuadPart / (double)f.QuadPart;
}

static bool fail(const char *what)
{
    snprintf(g_err, sizeof(g_err), "%s failed (WSA error %d, Win32 error %lu)", what,
             WSAGetLastError(), GetLastError());
    return false;
}

struct Flow {
    SOCKET s = INVALID_SOCKET;
    RIO_RQ rq = RIO_INVALID_RQ;
    RIO_CQ rx_cq = RIO_INVALID_CQ, tx_cq = RIO_INVALID_CQ;
    SRWLOCK lock = SRWLOCK_INIT;          // RIO request queues are not thread safe
    char *rx_pool = nullptr;
    RIO_BUFFERID rx_bid = RIO_INVALID_BUFFERID;
    std::vector<RIO_BUF> rx_bufs;
    RIO_BUF addr = {};                    // FPGA address (registered SOCKADDR_INET)
    DWORD tx_out = 0;                     // outstanding sends (owning TX thread only)
    DWORD tx_pending = 0;                 // deferred sends not yet committed
};

// One reassembly slot per frame in flight (frame n uses slot n mod nslot).
struct Slot {
    std::atomic<int64_t> tag{-1};         // frame id held
    std::atomic<int> state{0};            // 0 free/done, 1 receiving, 2 comparing
    std::atomic<int> count{0};
    std::atomic<uint64_t> *bits = nullptr;
    uint8_t *data = nullptr;
    double t_sent = 0;
};

static struct Engine {
    lb_config cfg = {};
    int frame_bytes = 0, npkts = 0, nslot = 0, words = 0;
    std::vector<Flow> flows;
    // pre-split packets of the cycle frames, one registered block per frame
    std::vector<uint8_t *> pk_mem;
    std::vector<RIO_BUFFERID> pk_bid;
    std::vector<uint8_t *> orig;          // original frames (caller fills them)
    char *addr_mem = nullptr;
    RIO_BUFFERID addr_bid = RIO_INVALID_BUFFERID;
    std::vector<Slot> slots;
    uint8_t *disp = nullptr;              // latest intact received frame, for display
    SRWLOCK disp_lock = SRWLOCK_INIT;
    std::atomic<int64_t> disp_id{-1};
    std::atomic<bool> disp_want{false};

    std::thread tx;
    std::vector<std::thread> rx;
    std::atomic<bool> stop{false}, tx_done{false}, running{false};
    std::atomic<int64_t> frames_sent{0}, frames_ok{0}, frames_bad{0}, pk_sent{0}, pk_recv{0},
                         by_sent{0}, by_recv{0};
    std::atomic<int64_t> lat_sum_us{0}, lat_max_us{0};
    double t_start = 0, t_tx_end = 0;
    std::atomic<double> t_last_rx{0};
    bool open = false;
} E;

static uint8_t *pkt_at(int cyc, int k) { return E.pk_mem[cyc] + (size_t)k * (HDR + E.cfg.payload); }

static bool open_flow(Flow &f, int i)
{
    f.s = WSASocketW(AF_INET, SOCK_DGRAM, IPPROTO_UDP, nullptr, 0, WSA_FLAG_REGISTERED_IO);
    if (f.s == INVALID_SOCKET) return fail("WSASocket");
    if (!rio.RIOReceive) {
        GUID fid = WSAID_MULTIPLE_RIO;
        DWORD got = 0;
        if (WSAIoctl(f.s, SIO_GET_MULTIPLE_EXTENSION_FUNCTION_POINTER, &fid, sizeof(fid),
                     &rio, sizeof(rio), &got, nullptr, nullptr))
            return fail("RIO function table");
    }
    int buf = 64 << 20;
    setsockopt(f.s, SOL_SOCKET, SO_RCVBUF, (const char *)&buf, sizeof(buf));
    setsockopt(f.s, SOL_SOCKET, SO_SNDBUF, (const char *)&buf, sizeof(buf));
    sockaddr_in local = {};
    local.sin_family = AF_INET;
    if (bind(f.s, (sockaddr *)&local, sizeof(local))) return fail("bind");

    f.rx_pool = (char *)VirtualAlloc(nullptr, (SIZE_T)SLOT * RX_SLOTS, MEM_COMMIT | MEM_RESERVE, PAGE_READWRITE);
    if (!f.rx_pool) return fail("VirtualAlloc(rx)");
    f.rx_bid = rio.RIORegisterBuffer(f.rx_pool, SLOT * RX_SLOTS);
    if (f.rx_bid == RIO_INVALID_BUFFERID) return fail("RIORegisterBuffer(rx)");
    f.rx_cq = rio.RIOCreateCompletionQueue(RX_SLOTS, nullptr);
    f.tx_cq = rio.RIOCreateCompletionQueue(TX_DEPTH, nullptr);
    if (f.rx_cq == RIO_INVALID_CQ || f.tx_cq == RIO_INVALID_CQ) return fail("RIOCreateCompletionQueue");
    f.rq = rio.RIOCreateRequestQueue(f.s, RX_SLOTS, 1, TX_DEPTH, 1, f.rx_cq, f.tx_cq, nullptr);
    if (f.rq == RIO_INVALID_RQ) return fail("RIOCreateRequestQueue");
    f.rx_bufs.resize(RX_SLOTS);
    for (DWORD k = 0; k < RX_SLOTS; k++) {
        f.rx_bufs[k] = {f.rx_bid, k * SLOT, SLOT};
        if (!rio.RIOReceive(f.rq, &f.rx_bufs[k], 1, RIO_MSG_DEFER, (PVOID)(ULONG_PTR)k)) return fail("RIOReceive");
    }
    rio.RIOReceive(f.rq, nullptr, 0, RIO_MSG_COMMIT_ONLY, nullptr);

    sockaddr_in *a = (sockaddr_in *)(E.addr_mem + i * sizeof(SOCKADDR_INET));
    a->sin_family = AF_INET;
    a->sin_port = htons((u_short)E.cfg.port);
    inet_pton(AF_INET, E.cfg.ip, &a->sin_addr);
    a->sin_addr.s_addr = htonl(ntohl(a->sin_addr.s_addr) + (u_long)i);
    f.addr = {E.addr_bid, (ULONG)(i * sizeof(SOCKADDR_INET)), sizeof(SOCKADDR_INET)};
    return true;
}

// ---------------------------------------------------------------- receive
static void frame_done(Slot &s, int64_t id)
{
    int c = (int)(id % E.cfg.cycle);
    bool ok = memcmp(s.data, E.orig[c], E.frame_bytes) == 0;
    (ok ? E.frames_ok : E.frames_bad)++;
    int64_t lat = (int64_t)((qpc_s() - s.t_sent) * 1e6);
    E.lat_sum_us += lat;
    int64_t m = E.lat_max_us.load();
    while (lat > m && !E.lat_max_us.compare_exchange_weak(m, lat)) {}
    if (ok && E.disp_want.exchange(false)) {
        AcquireSRWLockExclusive(&E.disp_lock);
        memcpy(E.disp, s.data, E.frame_bytes);
        E.disp_id = id;
        ReleaseSRWLockExclusive(&E.disp_lock);
    }
    s.state = 0;
}

static void on_packet(const uint8_t *p, ULONG n)
{
    if (n < (ULONG)HDR) return;
    uint32_t magic, id, off;
    uint16_t idx;
    memcpy(&magic, p, 4); memcpy(&id, p + 4, 4); memcpy(&idx, p + 8, 2); memcpy(&off, p + 12, 4);
    if (magic != MAGIC || id == 0xFFFFFFFF) return;
    ULONG len = n - HDR;
    if (idx >= E.npkts || off != (uint32_t)idx * E.cfg.payload || off + len > (ULONG)E.frame_bytes) return;
    E.pk_recv++;
    E.by_recv += n;
    Slot &s = E.slots[id % E.nslot];
    if (s.tag.load(std::memory_order_acquire) != id || s.state.load() != 1) return;   // late / stale
    uint64_t bit = 1ull << (idx & 63);
    if (s.bits[idx >> 6].load(std::memory_order_relaxed) & bit) return;                  // duplicate
    memcpy(s.data + off, p + HDR, len);
    // count the packet only if the slot still holds this frame (a late packet of an old frame
    // may race with the slot being reused)
    if (s.tag.load(std::memory_order_acquire) != id || s.state.load() != 1) return;
    if (s.bits[idx >> 6].fetch_or(bit) & bit) return;                                  // duplicate
    if (s.count.fetch_add(1) + 1 == E.npkts) {
        int one = 1;
        if (s.state.compare_exchange_strong(one, 2)) frame_done(s, id);
    }
}

static void rx_loop(std::vector<Flow *> mine)
{
    std::vector<RIORESULT> res(CQ_BATCH);
    while (!E.stop.load(std::memory_order_relaxed)) {
        bool any = false;
        for (Flow *f : mine) {
            ULONG n = rio.RIODequeueCompletion(f->rx_cq, res.data(), CQ_BATCH);
            if (n == 0 || n == RIO_CORRUPT_CQ) continue;
            any = true;
            for (ULONG k = 0; k < n; k++) {
                DWORD slot = (DWORD)res[k].RequestContext;
                if (res[k].Status == 0) on_packet((uint8_t *)f->rx_pool + (size_t)slot * SLOT, res[k].BytesTransferred);
            }
            AcquireSRWLockExclusive(&f->lock);
            for (ULONG k = 0; k < n; k++) {
                DWORD slot = (DWORD)res[k].RequestContext;
                rio.RIOReceive(f->rq, &f->rx_bufs[slot], 1, RIO_MSG_DEFER, (PVOID)(ULONG_PTR)slot);
            }
            rio.RIOReceive(f->rq, nullptr, 0, RIO_MSG_COMMIT_ONLY, nullptr);
            ReleaseSRWLockExclusive(&f->lock);
        }
        if (any) E.t_last_rx = qpc_s();
        else _mm_pause();
    }
}

// ---------------------------------------------------------------- send
// Several send threads; thread j owns the flows i with i mod T == j and sends their packets
// on the common schedule. Sends are queued with RIO_MSG_DEFER and committed in batches.
static void reap_tx(Flow &f)
{
    RIORESULT res[CQ_BATCH];
    ULONG n = rio.RIODequeueCompletion(f.tx_cq, res, CQ_BATCH);
    if (n != RIO_CORRUPT_CQ) f.tx_out -= n;
}

static void commit_tx(Flow &f)
{
    if (!f.tx_pending) return;
    AcquireSRWLockExclusive(&f.lock);
    rio.RIOSendEx(f.rq, nullptr, 0, nullptr, nullptr, nullptr, nullptr, RIO_MSG_COMMIT_ONLY, nullptr);
    ReleaseSRWLockExclusive(&f.lock);
    f.tx_pending = 0;
}

static bool send_pkt(Flow &f, int cyc, int k, uint32_t len)
{
    while (f.tx_out >= TX_DEPTH) { commit_tx(f); reap_tx(f); }
    RIO_BUF b = {E.pk_bid[cyc], (ULONG)((size_t)k * (HDR + E.cfg.payload)), (ULONG)(HDR + len)};
    AcquireSRWLockExclusive(&f.lock);
    BOOL ok = rio.RIOSendEx(f.rq, &b, 1, nullptr, &f.addr, nullptr, nullptr, RIO_MSG_DEFER, nullptr);
    ReleaseSRWLockExclusive(&f.lock);
    if (ok) { f.tx_out++; if (++f.tx_pending >= 16) commit_tx(f); }
    return ok != FALSE;
}

// take the reassembly slot of frame n (the frame that used it last is given up if still open)
static void open_slot(int64_t n, double t0)
{
    Slot &s = E.slots[n % E.nslot];
    s.state = 0;
    for (int w = 0; w < E.words; w++) s.bits[w].store(0, std::memory_order_relaxed);
    s.count = 0;
    s.t_sent = t0;
    s.tag.store(n, std::memory_order_release);
    s.state = 1;
}

// max_gbps > 0 caps the send rate (Ethernet frame bytes on the wire): a thread that fell behind
// its schedule (the OS did not run it for a while) catches up at that rate instead of sending
// the backlog back to back at the NIC's line rate, which a slower receiver cannot buffer.
static void tx_loop(int j, int T, int64_t frames, double frame_t, double pkt_t, double max_gbps)
{
    int F = E.cfg.flows;
    std::vector<Flow *> mine;
    for (int i = j; i < F; i += T) mine.push_back(&E.flows[i]);
    // this thread sends every T-th packet: at most max_gbps / T of the traffic
    double min_gap = max_gbps > 0 ? T * (HDR + E.cfg.payload + 8 + 20 + 14 + 4 + 20) * 8.0 / (max_gbps * 1e9) : 0;
    double next_ok = 0;
    for (int64_t n = 0; n < frames && !E.stop; n++) {
        int cyc = (int)(n % E.cfg.cycle);
        double t0 = E.t_start + n * frame_t;
        if (j == 0 && n + 2 < frames) open_slot(n + 2, t0 + 2 * frame_t);   // two frames ahead
        int64_t pk = 0, by = 0;
        for (int k = 0; k < E.npkts && !E.stop; k++) {
            int fi = k % F;
            if (fi % T != j) continue;
            double due = t0 + k * pkt_t;
            if (due < next_ok) due = next_ok;
            if (qpc_s() < due) {
                for (Flow *f : mine) commit_tx(*f);
                while (qpc_s() < due) for (Flow *f : mine) if (f->tx_out) reap_tx(*f);
            }
            uint8_t *p = pkt_at(cyc, k);
            memcpy(p + 4, &n, 4);                     // frame id (low 32 bits)
            uint32_t len = (uint32_t)(k + 1 < E.npkts ? E.cfg.payload : E.frame_bytes - k * E.cfg.payload);
            if (send_pkt(E.flows[fi], cyc, k, len)) { pk++; by += HDR + len; }
            if (min_gap > 0) {
                // token bucket: the send time advances by min_gap per packet from the previous
                // allowance (so the send overhead does not add up), with at most 4 packets of burst
                double now = qpc_s(), floor = now - 4 * min_gap;
                next_ok = (next_ok > floor ? next_ok : floor) + min_gap;
                commit_tx(E.flows[fi]);               // shaped: no deferred batches
            }
        }
        for (Flow *f : mine) commit_tx(*f);
        E.pk_sent += pk; E.by_sent += by;
        if (j == 0) E.frames_sent++;
    }
    for (Flow *f : mine) commit_tx(*f);
}

// ---------------------------------------------------------------- API
LB_API const char *lb_error() { return g_err; }

// Allocates everything for this configuration; the caller then fills lb_frame(i) for all
// i < cycle and calls lb_prepare().
LB_API int lb_open(const lb_config *c)
{
    g_err[0] = 0;
    if (E.open) { snprintf(g_err, sizeof(g_err), "already open"); return 0; }
    WSADATA wd;
    if (WSAStartup(MAKEWORD(2, 2), &wd)) return fail("WSAStartup");
    E.cfg = *c;
    E.frame_bytes = c->width * c->height * 3;
    E.npkts = (E.frame_bytes + c->payload - 1) / c->payload;
    E.words = (E.npkts + 63) / 64;
    // reassembly: up to 64 frames in flight, no more than ~2 GB
    E.nslot = (int)(2000000000LL / E.frame_bytes);
    if (E.nslot > 64) E.nslot = 64;
    if (E.nslot < 4) E.nslot = 4;

    E.addr_mem = (char *)VirtualAlloc(nullptr, 64 * sizeof(SOCKADDR_INET), MEM_COMMIT | MEM_RESERVE, PAGE_READWRITE);
    E.flows = std::vector<Flow>(c->flows);
    // the function table is needed before registering buffers: open flow 0 first
    for (int i = 0; i < c->flows; i++) {
        if (i == 0) {
            SOCKET t = WSASocketW(AF_INET, SOCK_DGRAM, IPPROTO_UDP, nullptr, 0, WSA_FLAG_REGISTERED_IO);
            GUID fid = WSAID_MULTIPLE_RIO;
            DWORD got = 0;
            if (t == INVALID_SOCKET || WSAIoctl(t, SIO_GET_MULTIPLE_EXTENSION_FUNCTION_POINTER, &fid, sizeof(fid),
                                                &rio, sizeof(rio), &got, nullptr, nullptr))
                return fail("RIO function table");
            closesocket(t);
            E.addr_bid = rio.RIORegisterBuffer(E.addr_mem, 64 * sizeof(SOCKADDR_INET));
            if (E.addr_bid == RIO_INVALID_BUFFERID) return fail("RIORegisterBuffer(addr)");
        }
        if (!open_flow(E.flows[i], i)) return 0;
    }

    size_t pk_bytes = (size_t)E.npkts * (HDR + c->payload);
    for (int i = 0; i < c->cycle; i++) {
        uint8_t *m = (uint8_t *)VirtualAlloc(nullptr, pk_bytes, MEM_COMMIT | MEM_RESERVE, PAGE_READWRITE);
        uint8_t *o = (uint8_t *)VirtualAlloc(nullptr, E.frame_bytes, MEM_COMMIT | MEM_RESERVE, PAGE_READWRITE);
        if (!m || !o) return fail("VirtualAlloc(frames)");
        RIO_BUFFERID b = rio.RIORegisterBuffer((PCHAR)m, (DWORD)pk_bytes);
        if (b == RIO_INVALID_BUFFERID) return fail("RIORegisterBuffer(frames)");
        E.pk_mem.push_back(m); E.pk_bid.push_back(b); E.orig.push_back(o);
    }
    E.slots = std::vector<Slot>(E.nslot);
    for (auto &s : E.slots) {
        s.data = (uint8_t *)VirtualAlloc(nullptr, E.frame_bytes, MEM_COMMIT | MEM_RESERVE, PAGE_READWRITE);
        s.bits = new std::atomic<uint64_t>[E.words];
        if (!s.data) return fail("VirtualAlloc(reassembly)");
        memset(s.data, 0, E.frame_bytes);         // fault the pages in before the run
    }
    E.disp = (uint8_t *)VirtualAlloc(nullptr, E.frame_bytes, MEM_COMMIT | MEM_RESERVE, PAGE_READWRITE);
    E.open = true;
    return 1;
}

LB_API uint8_t *lb_frame(int i) { return (i >= 0 && i < (int)E.orig.size()) ? E.orig[i] : nullptr; }
LB_API int lb_packets_per_frame() { return E.npkts; }

// Splits the cycle frames into packets and checks every flow with one probe packet
// (the FPGA resolves our MAC while answering the first one).
LB_API int lb_prepare()
{
    for (int c = 0; c < E.cfg.cycle; c++)
        for (int k = 0; k < E.npkts; k++) {
            uint8_t *p = pkt_at(c, k);
            uint32_t off = (uint32_t)k * E.cfg.payload;
            uint32_t len = (uint32_t)(k + 1 < E.npkts ? E.cfg.payload : E.frame_bytes - off);
            uint16_t idx = (uint16_t)k, cnt = (uint16_t)E.npkts;
            memcpy(p, &MAGIC, 4); memset(p + 4, 0, 4); memcpy(p + 8, &idx, 2); memcpy(p + 10, &cnt, 2);
            memcpy(p + 12, &off, 4);
            memcpy(p + HDR, E.orig[c] + off, len);
        }
    // probe: 16-byte packet with frame id 0xFFFFFFFF, reusing the addr block's tail as buffer
    uint8_t *probe = (uint8_t *)E.addr_mem + 32 * sizeof(SOCKADDR_INET);
    uint32_t pid = 0xFFFFFFFF;
    memset(probe, 0, HDR); memcpy(probe, &MAGIC, 4); memcpy(probe + 4, &pid, 4);
    RIO_BUF pb = {E.addr_bid, 32 * sizeof(SOCKADDR_INET), HDR};
    for (int i = 0; i < E.cfg.flows; i++) {
        Flow &f = E.flows[i];
        bool ok = false;
        for (int attempt = 0; attempt < 10 && !ok; attempt++) {
            if (!rio.RIOSendEx(f.rq, &pb, 1, nullptr, &f.addr, nullptr, nullptr, 0, nullptr)) return fail("RIOSendEx(probe)");
            f.tx_out++;
            double end = qpc_s() + 0.3;
            RIORESULT r[16];
            while (!ok && qpc_s() < end) {
                reap_tx(f);
                ULONG n = rio.RIODequeueCompletion(f.rx_cq, r, 16);
                if (n == RIO_CORRUPT_CQ) n = 0;
                for (ULONG k = 0; k < n; k++) {
                    DWORD slot = (DWORD)r[k].RequestContext;
                    const uint8_t *p = (uint8_t *)f.rx_pool + (size_t)slot * SLOT;
                    uint32_t m, id;
                    memcpy(&m, p, 4); memcpy(&id, p + 4, 4);
                    if (r[k].BytesTransferred >= (ULONG)HDR && m == MAGIC && id == 0xFFFFFFFF) ok = true;
                    rio.RIOReceive(f.rq, &f.rx_bufs[slot], 1, 0, (PVOID)(ULONG_PTR)slot);
                }
            }
        }
        if (!ok) {
            char a[32];
            inet_ntop(AF_INET, &((sockaddr_in *)(E.addr_mem + i * sizeof(SOCKADDR_INET)))->sin_addr, a, sizeof(a));
            snprintf(g_err, sizeof(g_err), "no echo from %s:%d (flow %d)", a, E.cfg.port, i);
            return 0;
        }
    }
    return 1;
}

// Starts a run: `seconds` of video at `fps`, packets of a frame spread over `spread` of the
// frame interval. Returns at once; poll lb_get_stats().running.
LB_API int lb_run(int fps, double seconds, double spread, double max_gbps)
{
    if (!E.open || E.running) return 0;
    if (E.tx.joinable()) E.tx.join();
    E.stop = false; E.tx_done = false;
    E.frames_sent = E.frames_ok = E.frames_bad = E.pk_sent = E.pk_recv = E.by_sent = E.by_recv = 0;
    E.lat_sum_us = E.lat_max_us = 0;
    E.t_last_rx = 0;
    E.disp_id = -1;
    for (auto &s : E.slots) { s.state = 0; s.tag = -1; }
    E.running = true;
    int R = E.cfg.rx_threads < 1 ? 1 : E.cfg.rx_threads;
    std::vector<std::vector<Flow *>> groups(R);
    for (int i = 0; i < E.cfg.flows; i++) groups[i % R].push_back(&E.flows[i]);
    for (auto &g : groups) E.rx.emplace_back(rx_loop, g);
    E.tx = std::thread([fps, seconds, spread, max_gbps] {
        int T = E.cfg.tx_threads < 1 ? 1 : (E.cfg.tx_threads > E.cfg.flows ? E.cfg.flows : E.cfg.tx_threads);
        int64_t frames = (int64_t)(seconds * fps + 0.5);
        double frame_t = 1.0 / fps, pkt_t = spread * frame_t / E.npkts;
        E.t_start = qpc_s() + 0.05;
        for (int64_t n = 0; n < 2 && n < frames; n++) open_slot(n, E.t_start + n * frame_t);
        std::vector<std::thread> tx;
        for (int j = 0; j < T; j++)
            tx.emplace_back([=] {
                SetThreadPriority(GetCurrentThread(), THREAD_PRIORITY_HIGHEST);
                tx_loop(j, T, frames, frame_t, pkt_t, max_gbps);
            });
        for (auto &th : tx) th.join();
        E.t_tx_end = qpc_s();
        E.tx_done = true;
        // the run ends 0.3 s after the last packet came back (or 1 s after sending ended)
        while (!E.stop) {
            double t = qpc_s(), last = E.t_last_rx;
            if (t - E.t_tx_end > 1.0 || (last > E.t_tx_end && t - last > 0.3)) break;
            Sleep(10);
        }
        E.stop = true;
        for (auto &th : E.rx) th.join();
        E.rx.clear();
        E.running = false;
    });
    return 1;
}

LB_API void lb_stop() { E.stop = true; }

LB_API void lb_get_stats(lb_stats *s)
{
    s->frames_sent = E.frames_sent; s->frames_ok = E.frames_ok; s->frames_bad = E.frames_bad;
    s->packets_sent = E.pk_sent; s->packets_recv = E.pk_recv; s->bytes_sent = E.by_sent; s->bytes_recv = E.by_recv;
    double now = qpc_s();
    double tx_end = E.tx_done ? E.t_tx_end : now;
    s->tx_seconds = E.t_start > 0 && tx_end > E.t_start ? tx_end - E.t_start : 0;
    double rx_end = E.running ? now : (double)E.t_last_rx;
    s->rx_seconds = E.t_start > 0 && rx_end > E.t_start ? rx_end - E.t_start : 0;
    int64_t done = E.frames_ok + E.frames_bad;
    s->latency_avg_ms = done ? E.lat_sum_us / 1000.0 / done : 0;
    s->latency_max_ms = E.lat_max_us / 1000.0;
    s->running = E.running ? 1 : 0;
    s->packets_per_frame = E.npkts;
}

// Copies the latest intact received frame into dst if it is newer than *id; returns 1 then.
// Also asks the receive side for the next intact frame.
LB_API int lb_latest(uint8_t *dst, int64_t *id)
{
    E.disp_want = true;
    int64_t d = E.disp_id;
    if (d < 0 || d == *id) return 0;
    AcquireSRWLockShared(&E.disp_lock);
    memcpy(dst, E.disp, E.frame_bytes);
    *id = E.disp_id;
    ReleaseSRWLockShared(&E.disp_lock);
    return 1;
}

LB_API void lb_close()
{
    if (!E.open) return;
    E.stop = true;
    if (E.tx.joinable()) E.tx.join();
    for (auto &f : E.flows) {
        closesocket(f.s);
        rio.RIOCloseCompletionQueue(f.rx_cq);
        rio.RIOCloseCompletionQueue(f.tx_cq);
        rio.RIODeregisterBuffer(f.rx_bid);
        VirtualFree(f.rx_pool, 0, MEM_RELEASE);
    }
    E.flows.clear();
    for (size_t i = 0; i < E.pk_mem.size(); i++) {
        rio.RIODeregisterBuffer(E.pk_bid[i]);
        VirtualFree(E.pk_mem[i], 0, MEM_RELEASE);
        VirtualFree(E.orig[i], 0, MEM_RELEASE);
    }
    E.pk_mem.clear(); E.pk_bid.clear(); E.orig.clear();
    for (auto &s : E.slots) { VirtualFree(s.data, 0, MEM_RELEASE); delete[] s.bits; }
    E.slots.clear();
    rio.RIODeregisterBuffer(E.addr_bid);
    VirtualFree(E.addr_mem, 0, MEM_RELEASE);
    VirtualFree(E.disp, 0, MEM_RELEASE);
    E.open = false;
    WSACleanup();
}
