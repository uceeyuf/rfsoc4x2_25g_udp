// rio_udp_rx.cpp - Windows Registered I/O (RIO) UDP receiver for the FPGA speed stream.
//
// Receives the record_udp_tx stream (FPGA:1236+i -> PC:1237+i), checks only the 8-byte
// sequence header of each packet (<u32 start_index><u32 total_samples>), never copies
// payload, and prints Gbps / Mpps / lost packets once per second.
//
// With N flows the FPGA sends packet k to port base+(k mod N), so every flow sees every
// N-th packet: each flow has its own socket and request/completion queue and checks its
// sequence with a stride of N packets (N must divide the packets per record: 4096 for 1032-B,
// 512 for 8200-B jumbo packets, so 1, 2, 4, 8 or 16). Packet size is taken from the data. The flows are
// polled by T busy-polling threads (flow i on thread i mod T), leaving the other cores to
// the kernel receive DPCs.
//
//   rio_udp_rx.exe [seconds=10] [flows=1] [threads=min(flows,8)] [fpga_ip=192.168.100.1] [base_port=1237]
//
// Build: tests\rio_rx\build.bat (MSVC x64)

#define WIN32_LEAN_AND_MEAN
#include <winsock2.h>
#include <ws2tcpip.h>
#include <mswsock.h>
#include <windows.h>

#include <atomic>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <thread>
#include <vector>

#pragma comment(lib, "ws2_32.lib")

static const DWORD SLOT_BYTES         = 9216;   // >= 8200 B jumbo payload
static const DWORD MAX_SLOTS          = 4096;   // outstanding receives per flow (reduced if refused)
static const DWORD CQ_BATCH           = 1024;

static RIO_EXTENSION_FUNCTION_TABLE rio;
static std::atomic<bool> g_stop{false};

static void die(const char *what)
{
    fprintf(stderr, "[!] %s failed: WSA error %d\n", what, WSAGetLastError());
    exit(1);
}

static double now_s()
{
    static LARGE_INTEGER f = {};
    if (!f.QuadPart) QueryPerformanceFrequency(&f);
    LARGE_INTEGER c;
    QueryPerformanceCounter(&c);
    return (double)c.QuadPart / (double)f.QuadPart;
}

struct Flow {
    int port = 0;
    uint32_t nflows = 1;
    uint32_t stride = 0;                   // samples between consecutive packets of this flow
                                           // = (payload bytes - 8) / 4 * nflows, set from the first packet
    SOCKET s = INVALID_SOCKET;
    char *pool = nullptr;
    RIO_BUFFERID bid = RIO_INVALID_BUFFERID;
    RIO_CQ cq = RIO_INVALID_CQ;
    RIO_RQ rq = RIO_INVALID_RQ;
    DWORD slots = 0;
    std::vector<RIO_BUF> bufs;
    std::atomic<uint64_t> pkts{0}, bytes{0}, lost{0}, bad{0};
    std::atomic<double> t_first{0};
};

static void open_flow(Flow &f)
{
    f.s = WSASocketW(AF_INET, SOCK_DGRAM, IPPROTO_UDP, nullptr, 0, WSA_FLAG_REGISTERED_IO);
    if (f.s == INVALID_SOCKET) die("WSASocket(RIO)");

    if (!rio.RIOReceive) {
        GUID fid = WSAID_MULTIPLE_RIO;
        DWORD got = 0;
        if (WSAIoctl(f.s, SIO_GET_MULTIPLE_EXTENSION_FUNCTION_POINTER, &fid, sizeof(fid),
                     &rio, sizeof(rio), &got, nullptr, nullptr))
            die("WSAIoctl(RIO table)");
    }

    int rcvbuf = 256 * 1024 * 1024;
    setsockopt(f.s, SOL_SOCKET, SO_RCVBUF, (const char *)&rcvbuf, sizeof(rcvbuf));

    sockaddr_in local = {};
    local.sin_family = AF_INET;
    local.sin_port = htons((u_short)f.port);
    local.sin_addr.s_addr = INADDR_ANY;
    if (bind(f.s, (sockaddr *)&local, sizeof(local))) die("bind");

    f.pool = (char *)VirtualAlloc(nullptr, (SIZE_T)SLOT_BYTES * MAX_SLOTS,
                                  MEM_COMMIT | MEM_RESERVE, PAGE_READWRITE);
    if (!f.pool) { fprintf(stderr, "[!] VirtualAlloc failed\n"); exit(1); }
    f.bid = rio.RIORegisterBuffer(f.pool, SLOT_BYTES * MAX_SLOTS);
    if (f.bid == RIO_INVALID_BUFFERID) die("RIORegisterBuffer");

    // CQ must hold every outstanding receive plus the (unused) send slot.
    f.cq = rio.RIOCreateCompletionQueue(MAX_SLOTS + 1, nullptr);   // polled, no notification
    if (f.cq == RIO_INVALID_CQ) die("RIOCreateCompletionQueue");
    for (f.slots = MAX_SLOTS; f.slots >= 256; f.slots /= 2) {
        f.rq = rio.RIOCreateRequestQueue(f.s, f.slots, 1, 1, 1, f.cq, f.cq, nullptr);
        if (f.rq != RIO_INVALID_RQ) break;
    }
    if (f.rq == RIO_INVALID_RQ) die("RIOCreateRequestQueue");

    f.bufs.resize(f.slots);
    for (DWORD i = 0; i < f.slots; i++) {
        f.bufs[i].BufferId = f.bid;
        f.bufs[i].Offset = i * SLOT_BYTES;
        f.bufs[i].Length = SLOT_BYTES;
        if (!rio.RIOReceive(f.rq, &f.bufs[i], 1, RIO_MSG_DEFER, (PVOID)(ULONG_PTR)i))
            die("RIOReceive(post)");
    }
    if (!rio.RIOReceive(f.rq, nullptr, 0, RIO_MSG_COMMIT_ONLY, nullptr)) die("RIOReceive(commit)");
}

static void close_flow(Flow &f)
{
    closesocket(f.s);
    rio.RIOCloseCompletionQueue(f.cq);
    rio.RIODeregisterBuffer(f.bid);
    VirtualFree(f.pool, 0, MEM_RELEASE);
}

struct SeqState {
    bool have_prev = false;
    uint32_t prev = 0, total = 0;
};

// Drain one batch of completions of flow f and re-post the buffers.
static void drain_flow(Flow &f, SeqState &st, std::vector<RIORESULT> &res)
{
    bool &have_prev = st.have_prev;
    uint32_t &prev = st.prev, &total = st.total;
    {
        ULONG n = rio.RIODequeueCompletion(f.cq, res.data(), CQ_BATCH);
        if (n == RIO_CORRUPT_CQ) { fprintf(stderr, "[!] corrupt CQ\n"); exit(1); }
        if (n == 0) return;
        if (f.t_first.load() == 0) f.t_first = now_s();

        uint64_t pk = 0, by = 0, lo = 0, bd = 0;
        for (ULONG k = 0; k < n; k++) {
            DWORD slot = (DWORD)res[k].RequestContext;
            ULONG len = res[k].BytesTransferred;
            if (res[k].Status == 0 && len >= 8) {
                const uint8_t *p = (const uint8_t *)f.pool + (size_t)slot * SLOT_BYTES;
                uint32_t idx, tot;
                memcpy(&idx, p, 4);
                memcpy(&tot, p + 4, 4);
                if (!f.stride) f.stride = (len - 8) / 4 * f.nflows;
                if (tot && tot != total) { total = tot; have_prev = false; }
                if (have_prev && total) {
                    uint32_t exp = (prev + f.stride) % total;
                    lo += ((idx + total - exp) % total) / f.stride;
                }
                prev = idx;
                have_prev = true;
                pk++;
                by += len;
            } else {
                bd++;
            }
            rio.RIOReceive(f.rq, &f.bufs[slot], 1, RIO_MSG_DEFER, (PVOID)(ULONG_PTR)slot);
        }
        rio.RIOReceive(f.rq, nullptr, 0, RIO_MSG_COMMIT_ONLY, nullptr);
        f.pkts += pk; f.bytes += by; f.lost += lo; f.bad += bd;
    }
}

static void poll_group(std::vector<Flow *> group)
{
    std::vector<RIORESULT> res(CQ_BATCH);
    std::vector<SeqState> st(group.size());
    while (!g_stop.load(std::memory_order_relaxed))
        for (size_t i = 0; i < group.size(); i++)
            drain_flow(*group[i], st[i], res);
}

int main(int argc, char **argv)
{
    double duration  = argc > 1 ? atof(argv[1]) : 10.0;
    int nflows       = argc > 2 ? atoi(argv[2]) : 1;
    int nthreads     = argc > 3 ? atoi(argv[3]) : (nflows < 8 ? nflows : 8);
    const char *fpga = argc > 4 ? argv[4] : "192.168.100.1";
    int base_port    = argc > 5 ? atoi(argv[5]) : 1237;
    if (nflows < 1 || nflows > 31 || 512 % nflows) {
        fprintf(stderr, "flows must divide 4096 (1, 2, 4, 8, 16)\n");
        return 1;
    }
    if (nthreads < 1 || nthreads > nflows) nthreads = nflows;

    WSADATA wsa;
    if (WSAStartup(MAKEWORD(2, 2), &wsa)) die("WSAStartup");

    std::vector<Flow> flows(nflows);
    for (int i = 0; i < nflows; i++) {
        flows[i].port = base_port + i;
        flows[i].nflows = (uint32_t)nflows;
        open_flow(flows[i]);
    }

    // Registration packet: the FPGA latches the source IP of any UDP packet it receives.
    SOCKET reg = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);
    sockaddr_in dst = {};
    dst.sin_family = AF_INET;
    dst.sin_port = htons((u_short)base_port);
    inet_pton(AF_INET, fpga, &dst.sin_addr);
    sendto(reg, "REG", 3, 0, (sockaddr *)&dst, sizeof(dst));
    closesocket(reg);

    printf("[i] RIO UDP receiver: %d flow(s) on :%d..%d, %d polling thread(s), %u slots x %u B per flow\n",
           nflows, base_port, base_port + nflows - 1, nthreads, flows[0].slots, SLOT_BYTES);
    printf("[i] registered with %s:%d, waiting for stream (set VIO tx_speed_en=1) ...\n", fpga, base_port);
    fflush(stdout);

    std::vector<std::vector<Flow *>> groups(nthreads);
    for (int i = 0; i < nflows; i++) groups[i % nthreads].push_back(&flows[i]);
    std::vector<std::thread> th;
    for (auto &g : groups) th.emplace_back(poll_group, g);

    auto sum = [&](uint64_t &pk, uint64_t &by, uint64_t &lo, uint64_t &bd) {
        pk = by = lo = bd = 0;
        for (auto &f : flows) { pk += f.pkts; by += f.bytes; lo += f.lost; bd += f.bad; }
    };

    // wait for the first packet on any flow
    double t0 = 0;
    while (!t0) {
        for (auto &f : flows) if (f.t_first.load()) { t0 = f.t_first; break; }
        Sleep(1);
    }
    uint64_t lp = 0, lb = 0, ll = 0, pk, by, lo, bd;
    double tl = t0;
    while (true) {
        Sleep(50);
        double t = now_s();
        if (t - tl >= 1.0 || t - t0 >= duration) {
            sum(pk, by, lo, bd);
            double dt = t - tl;
            uint64_t dp = pk - lp, dbytes = by - lb, dl = lo - ll;
            // wire rate adds UDP(8)+IP(20)+ETH(14)+FCS(4)+preamble/IFG(20) = 66 B per packet
            printf("%6.1fs  payload %6.2f Gbps  wire %6.2f Gbps  %6.3f Mpps  lost %8llu  (%.3f%%)\n",
                   t - t0, dbytes * 8 / dt / 1e9, (dbytes + 66.0 * dp) * 8 / dt / 1e9, dp / dt / 1e6,
                   (unsigned long long)dl, dp + dl ? 100.0 * dl / (dp + dl) : 0.0);
            fflush(stdout);
            lp = pk; lb = by; ll = lo; tl = t;
        }
        if (t - t0 >= duration) break;
    }
    g_stop = true;
    for (auto &t : th) t.join();
    double dt = now_s() - t0;
    sum(pk, by, lo, bd);

    printf("\n========== RIO result ==========\n");
    printf("flows          %d   threads %d\n", nflows, nthreads);
    printf("time           %.2f s\n", dt);
    printf("received       %llu pkts, %.2f GB\n", (unsigned long long)pk, by / 1e9);
    printf("payload rate   %.2f Gbps   wire rate %.2f Gbps   %.3f Mpps\n",
           by * 8 / dt / 1e9, (by + 66.0 * pk) * 8 / dt / 1e9, pk / dt / 1e6);
    printf("lost (by seq)  %llu   loss %.4f%%   bad completions %llu\n",
           (unsigned long long)lo, pk + lo ? 100.0 * lo / (pk + lo) : 0.0, (unsigned long long)bd);
    for (auto &f : flows)
        printf("  :%d  %llu pkts  lost %llu\n", f.port, (unsigned long long)f.pkts.load(),
               (unsigned long long)f.lost.load());
    printf(lo == 0 ? ">>> lossless <<<\n" : ">>> packet loss <<<\n");

    for (auto &f : flows) close_flow(f);
    WSACleanup();
    return 0;
}
