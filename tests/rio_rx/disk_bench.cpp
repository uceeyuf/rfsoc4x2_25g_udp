// disk_bench.cpp - sustained sequential write benchmark for the capture disk.
//
// Writes <GB> gigabytes to <file> with the same I/O pattern as the recorder:
// preallocated file, FILE_FLAG_NO_BUFFERING, OVERLAPPED writes of 64 MB blocks with
// several requests in flight. Prints GB/s every second, so the SLC-cache cliff of a
// consumer NVMe drive shows up, and the average before/after the cliff at the end.
//
//   disk_bench.exe <file> [GB=100] [queue_depth=8]
//
// Build: tests\rio_rx\build.bat

#define WIN32_LEAN_AND_MEAN
#include <windows.h>

#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <vector>

static const DWORD BLOCK = 64u << 20;

static double now_s()
{
    static LARGE_INTEGER f = {};
    if (!f.QuadPart) QueryPerformanceFrequency(&f);
    LARGE_INTEGER c;
    QueryPerformanceCounter(&c);
    return (double)c.QuadPart / (double)f.QuadPart;
}

int main(int argc, char **argv)
{
    if (argc < 2) { fprintf(stderr, "usage: disk_bench <file> [GB=100] [queue_depth=8]\n"); return 1; }
    const char *path = argv[1];
    uint64_t total = (uint64_t)(argc > 2 ? atof(argv[2]) : 100.0) * (1ull << 30);
    int qd = argc > 3 ? atoi(argv[3]) : 8;
    total -= total % BLOCK;

    HANDLE h = CreateFileA(path, GENERIC_WRITE, 0, nullptr, CREATE_ALWAYS,
                           FILE_FLAG_NO_BUFFERING | FILE_FLAG_OVERLAPPED, nullptr);
    if (h == INVALID_HANDLE_VALUE) { fprintf(stderr, "CreateFile failed %lu\n", GetLastError()); return 1; }
    // preallocate (sets EOF; valid data length is advanced by the writes themselves)
    LARGE_INTEGER sz; sz.QuadPart = (LONGLONG)total;
    SetFilePointerEx(h, sz, nullptr, FILE_BEGIN);
    SetEndOfFile(h);

    std::vector<char *> buf(qd);
    std::vector<OVERLAPPED> ov(qd);
    for (int i = 0; i < qd; i++) {
        buf[i] = (char *)VirtualAlloc(nullptr, BLOCK, MEM_COMMIT | MEM_RESERVE, PAGE_READWRITE);
        for (DWORD k = 0; k < BLOCK; k += 8) *(uint64_t *)(buf[i] + k) = 0x9E3779B97F4A7C15ull * (k + i + 1);
        memset(&ov[i], 0, sizeof(ov[i]));
        ov[i].hEvent = CreateEventA(nullptr, TRUE, FALSE, nullptr);
    }

    printf("[i] writing %.1f GB to %s, %u MB blocks, queue depth %d, unbuffered\n",
           total / 1073741824.0, path, BLOCK >> 20, qd);
    uint64_t issued = 0, done = 0, sec_done = 0;
    std::vector<bool> busy(qd, false);
    std::vector<double> per_sec;
    double t0 = now_s(), tl = t0;

    auto issue = [&](int i) {
        ov[i].Offset = (DWORD)issued;
        ov[i].OffsetHigh = (DWORD)(issued >> 32);
        ResetEvent(ov[i].hEvent);
        if (!WriteFile(h, buf[i], BLOCK, nullptr, &ov[i]) && GetLastError() != ERROR_IO_PENDING) {
            fprintf(stderr, "WriteFile failed %lu\n", GetLastError());
            exit(1);
        }
        issued += BLOCK;
        busy[i] = true;
    };
    for (int i = 0; i < qd && issued < total; i++) issue(i);

    while (done < total) {
        for (int i = 0; i < qd; i++) {
            if (!busy[i]) continue;
            DWORD n = 0;
            if (!GetOverlappedResult(h, &ov[i], &n, FALSE)) {
                if (GetLastError() == ERROR_IO_INCOMPLETE) continue;
                fprintf(stderr, "write failed %lu\n", GetLastError());
                return 1;
            }
            busy[i] = false;
            done += n;
            sec_done += n;
            if (issued < total) issue(i);
        }
        double t = now_s();
        if (t - tl >= 1.0 || done >= total) {
            double r = sec_done / (t - tl) / 1e9;
            per_sec.push_back(r);
            printf("%6.1fs  %7.1f GB written  %5.2f GB/s  (%5.1f Gbps)\n", t - t0, done / 1e9, r, r * 8);
            fflush(stdout);
            sec_done = 0;
            tl = t;
        }
        Sleep(0);
    }
    double dt = now_s() - t0;
    CloseHandle(h);

    // cliff: first second whose rate drops below 60 % of the first 5 s average
    double head = 0; int nh = 0;
    for (size_t i = 0; i < per_sec.size() && i < 5; i++) { head += per_sec[i]; nh++; }
    head = nh ? head / nh : 0;
    size_t cliff = per_sec.size();
    for (size_t i = 0; i < per_sec.size(); i++) if (per_sec[i] < 0.6 * head) { cliff = i; break; }
    double tail = 0; int nt = 0;
    for (size_t i = cliff; i < per_sec.size(); i++) { tail += per_sec[i]; nt++; }

    printf("\n========== disk result ==========\n");
    printf("total          %.1f GB in %.1f s  = %.2f GB/s (%.1f Gbps) average\n", done / 1e9, dt, done / dt / 1e9, done * 8 / dt / 1e9);
    printf("first 5 s      %.2f GB/s (%.1f Gbps)\n", head, head * 8);
    if (nt)
        printf("after cliff    %.2f GB/s (%.1f Gbps) sustained, cliff at ~%zu s (~%.0f GB)\n",
               tail / nt, tail / nt * 8, cliff, head * cliff);
    else
        printf("no cache cliff within %.1f GB\n", done / 1e9);
    return 0;
}
