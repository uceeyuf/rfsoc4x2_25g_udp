// UdpLoopbackViewer - host application for the RFSoC 4x2 UDP echo ports.
//
// Renders a cycle of test video frames, sends them to the FPGA as UDP packets, receives the
// echoed packets, reassembles every frame and compares it byte by byte with what was sent.
// Packet I/O, reassembly and comparison run in loopback_io.dll (Windows Registered I/O);
// this program renders the frames and shows the sent / received video and the results.
//
// Sweep: one resolution at increasing frame rates, a few seconds each. A step passes when
// every frame came back intact; the highest passing rate is the video ceiling of the path.
//
// Packet = 16-byte header + frame bytes:
//   u32 magic 'RFLB' | u32 frame id | u16 packet index | u16 packet count | u32 byte offset
//
// Command line (all optional):
//   --ip 192.168.100.128 --port 1234 --flows 16 --res 3840x2160 --fps 120 --seconds 10
//   (flow i goes to ip+i: the FPGA answers on its alias addresses 192.168.100.128-159;
//    --ip 192.168.100.1 --flows 1 uses the main address only)
//   --payload 8956 --cycle 20 --spread 1.0 --rx-threads 12 --tx-threads 4
//   --max-gbps 25            cap the send rate (catch-up after OS scheduling gaps) for a 25G receiver
//   --sweep 60,90,120,...    run a sweep instead of a single run
//   --out <dir>   --auto (start immediately)   --exit (close when done; implies --auto)
//   --shot <png>  save a picture of the window when done

using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using System.Windows.Forms;

namespace UdpLoopbackViewer
{
    sealed class Options
    {
        public string Ip = "192.168.100.128";
        public int Port = 1234, Flows = 16;
        public int Width = 3840, Height = 2160;
        public int Fps = 120;
        public double Seconds = 10;
        public int Payload = 8956;            // frame bytes per packet (+16 B header = 8972 B UDP payload, MTU 9000)
        public int Cycle = 20;
        public double Spread = 1.0;
        public double MaxGbps;                // cap on the send rate (0 = none), e.g. 25 for a 25G receiver
        public int RxThreads = 12, TxThreads = 4;
        public int[] Sweep;
        public string OutDir = Path.Combine(Environment.CurrentDirectory, "loopback_out");
        public string Shot;
        public bool Auto, Exit;

        public static Options Parse(string[] a)
        {
            var o = new Options();
            var ci = CultureInfo.InvariantCulture;
            for (int i = 0; i < a.Length; i++)
            {
                string v = i + 1 < a.Length ? a[i + 1] : "";
                switch (a[i])
                {
                    case "--ip": o.Ip = v; i++; break;
                    case "--port": o.Port = int.Parse(v); i++; break;
                    case "--flows": o.Flows = int.Parse(v); i++; break;
                    case "--res": var p = v.Split('x'); o.Width = int.Parse(p[0]); o.Height = int.Parse(p[1]); i++; break;
                    case "--fps": o.Fps = int.Parse(v); i++; break;
                    case "--seconds": o.Seconds = double.Parse(v, ci); i++; break;
                    case "--payload": o.Payload = int.Parse(v); i++; break;
                    case "--cycle": o.Cycle = int.Parse(v); i++; break;
                    case "--spread": o.Spread = double.Parse(v, ci); i++; break;
                    case "--max-gbps": o.MaxGbps = double.Parse(v, ci); i++; break;
                    case "--rx-threads": o.RxThreads = int.Parse(v); i++; break;
                    case "--tx-threads": o.TxThreads = int.Parse(v); i++; break;
                    case "--sweep": o.Sweep = ParseList(v); i++; break;
                    case "--out": o.OutDir = v; i++; break;
                    case "--shot": o.Shot = v; i++; break;
                    case "--auto": o.Auto = true; break;
                    case "--exit": o.Auto = o.Exit = true; break;
                }
            }
            return o;
        }

        public static int[] ParseList(string s)
        {
            return s.Split(new[] { ',', ' ' }, StringSplitOptions.RemoveEmptyEntries).Select(int.Parse).ToArray();
        }
    }

    // ---------------------------------------------------------------- native engine
    static class Native
    {
        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Ansi)]
        public struct Config
        {
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string Ip;
            public int Port, Flows, Width, Height, Payload, Cycle, RxThreads, TxThreads;
        }

        [StructLayout(LayoutKind.Sequential)]
        public struct Stats
        {
            public long FramesSent, FramesOk, FramesBad, PacketsSent, PacketsRecv, BytesSent, BytesRecv;
            public double TxSeconds, RxSeconds, LatencyAvgMs, LatencyMaxMs;
            public int Running, PacketsPerFrame;
        }

        const string Dll = "loopback_io.dll";
        [DllImport(Dll)] public static extern int lb_open(ref Config c);
        [DllImport(Dll)] public static extern IntPtr lb_frame(int i);
        [DllImport(Dll)] public static extern int lb_prepare();
        [DllImport(Dll)] public static extern int lb_run(int fps, double seconds, double spread, double maxGbps);
        [DllImport(Dll)] public static extern void lb_stop();
        [DllImport(Dll)] public static extern void lb_get_stats(out Stats s);
        [DllImport(Dll)] public static extern int lb_latest(byte[] dst, ref long id);
        [DllImport(Dll)] public static extern void lb_close();
        [DllImport(Dll)] static extern IntPtr lb_error();
        public static string Error() { return Marshal.PtrToStringAnsi(lb_error()); }
    }

    // One finished run (a single run, or one step of a sweep).
    sealed class StepResult
    {
        public int Fps;
        public double Seconds;
        // the frames went out at the requested rate (not late because the sender was held back)
        public bool OnTime { get { return S.TxSeconds <= Seconds * 1.02 + 1.0 / Math.Max(1, Fps); } }
        public Native.Stats S;
        public long Incomplete { get { return S.FramesSent - S.FramesOk - S.FramesBad; } }
        public bool Pass { get { return S.FramesSent > 0 && S.FramesOk == S.FramesSent && OnTime; } }
        public double TxGbps { get { return S.TxSeconds > 0 ? S.BytesSent * 8 / S.TxSeconds / 1e9 : 0; } }
        public double RxGbps { get { return S.TxSeconds > 0 ? S.BytesRecv * 8 / S.TxSeconds / 1e9 : 0; } }
        public double LostPct { get { return S.PacketsSent > 0 ? 100.0 * (S.PacketsSent - S.PacketsRecv) / S.PacketsSent : 0; } }
    }

    // ---------------------------------------------------------------- test video
    // Moving colour gradient, bars, a bouncing ball and the frame number.
    sealed class FrameGenerator
    {
        readonly int w, h;
        readonly Bitmap bmp;
        readonly Font big, small;

        public FrameGenerator(int width, int height)
        {
            w = width; h = height;
            bmp = new Bitmap(w, h, PixelFormat.Format24bppRgb);
            big = new Font("Consolas", h / 8f, FontStyle.Bold, GraphicsUnit.Pixel);
            small = new Font("Consolas", h / 24f, GraphicsUnit.Pixel);
        }

        public Bitmap Render(int n, int count)
        {
            double t = (double)n / count;
            using (var g = Graphics.FromImage(bmp))
            {
                g.SmoothingMode = SmoothingMode.AntiAlias;
                float hue = (float)(t * 360);
                using (var bg = new LinearGradientBrush(new Rectangle(0, 0, w, h),
                    Imaging.Hsv(hue, 0.7, 0.35), Imaging.Hsv(hue + 120, 0.7, 0.55), (float)(t * 360)))
                    g.FillRectangle(bg, 0, 0, w, h);
                for (int i = 0; i < 8; i++)
                {
                    int x = (int)((i * w / 8 + t * w) % w);
                    using (var br = new SolidBrush(Color.FromArgb(60, Imaging.Hsv(i * 45, 1, 1))))
                        g.FillRectangle(br, x, 0, w / 16, h);
                }
                double a = t * 2 * Math.PI;
                int r = h / 7;
                using (var ball = new SolidBrush(Color.FromArgb(230, 255, 210, 40)))
                    g.FillEllipse(ball, (int)((0.5 + 0.4 * Math.Cos(a)) * (w - 2 * r)), (int)((0.5 + 0.4 * Math.Sin(2 * a)) * (h - 2 * r)), 2 * r, 2 * r);
                g.DrawString(string.Format("FRAME {0:D2}/{1}", n, count), big, Brushes.White, w * 0.05f, h * 0.06f);
                g.DrawString(string.Format("{0}x{1}  RFSoC 4x2 UDP loopback", w, h), small, Brushes.White, w * 0.05f, h * 0.24f);
            }
            return bmp;
        }
    }

    static class Imaging
    {
        public static Color Hsv(double hue, double s, double v)
        {
            hue = ((hue % 360) + 360) % 360;
            int i = (int)(hue / 60) % 6;
            double f = hue / 60 - Math.Floor(hue / 60);
            double p = v * (1 - s), q = v * (1 - f * s), u = v * (1 - (1 - f) * s);
            double r, g, b;
            switch (i)
            {
                case 0: r = v; g = u; b = p; break;
                case 1: r = q; g = v; b = p; break;
                case 2: r = p; g = v; b = u; break;
                case 3: r = p; g = q; b = v; break;
                case 4: r = u; g = p; b = v; break;
                default: r = v; g = p; b = q; break;
            }
            return Color.FromArgb((int)(r * 255), (int)(g * 255), (int)(b * 255));
        }

        // Copies a 24-bit bitmap into unmanaged memory as tightly packed rows (BGR24).
        public static void CopyTo(Bitmap bmp, IntPtr dst)
        {
            var d = bmp.LockBits(new Rectangle(0, 0, bmp.Width, bmp.Height), ImageLockMode.ReadOnly, PixelFormat.Format24bppRgb);
            int row = bmp.Width * 3;
            var line = new byte[row];
            for (int y = 0; y < bmp.Height; y++)
            {
                Marshal.Copy(IntPtr.Add(d.Scan0, y * d.Stride), line, 0, row);
                Marshal.Copy(line, 0, IntPtr.Add(dst, y * row), row);
            }
            bmp.UnlockBits(d);
        }

        public static Bitmap FromBytes(byte[] data, int w, int h)
        {
            var bmp = new Bitmap(w, h, PixelFormat.Format24bppRgb);
            var d = bmp.LockBits(new Rectangle(0, 0, w, h), ImageLockMode.WriteOnly, PixelFormat.Format24bppRgb);
            for (int y = 0; y < h; y++)
                Marshal.Copy(data, y * w * 3, IntPtr.Add(d.Scan0, y * d.Stride), w * 3);
            bmp.UnlockBits(d);
            return bmp;
        }

        public static Bitmap Scaled(Image src, int w, int h)
        {
            var b = new Bitmap(w, h, PixelFormat.Format24bppRgb);
            using (var g = Graphics.FromImage(b))
            {
                g.InterpolationMode = InterpolationMode.Bilinear;
                g.DrawImage(src, 0, 0, w, h);
            }
            return b;
        }
    }

    // ---------------------------------------------------------------- sweep chart
    sealed class SweepChart : Control
    {
        public readonly List<StepResult> Steps = new List<StepResult>();
        public string Title = "";

        public SweepChart() { DoubleBuffered = true; }

        protected override void OnPaint(PaintEventArgs e)
        {
            var g = e.Graphics;
            g.SmoothingMode = SmoothingMode.AntiAlias;
            g.Clear(BackColor);
            float k = DeviceDpi / 96f;
            using (var fTitle = new Font("Segoe UI Semibold", 11f))
            using (var fAxis = new Font("Segoe UI", 8.5f))
            using (var fVal = new Font("Segoe UI", 8f))
            using (var axis = new Pen(Color.FromArgb(110, 110, 120)))
            using (var grid = new Pen(Color.FromArgb(55, 55, 62)))
            using (var txt = new SolidBrush(ForeColor))
            using (var dim = new SolidBrush(Color.FromArgb(150, 150, 160)))
            {
                g.DrawString(Title, fTitle, txt, 8 * k, 4 * k);
                float left = 44 * k, top = 48 * k, right = Width - 12 * k, bottom = Height - 48 * k;
                if (right <= left || bottom <= top) return;

                double maxG = 1;
                foreach (var s in Steps) maxG = Math.Max(maxG, Math.Max(s.TxGbps, s.RxGbps));
                double stepG = maxG > 60 ? 20 : maxG > 30 ? 10 : 5;
                maxG = Math.Ceiling(maxG * 1.08 / stepG) * stepG;
                Func<double, float> Y = v => (float)(bottom - (bottom - top) * v / maxG);

                for (double v = 0; v <= maxG + 1e-9; v += stepG)
                {
                    g.DrawLine(v == 0 ? axis : grid, left, Y(v), right, Y(v));
                    var sz = g.MeasureString(v.ToString("0"), fAxis);
                    g.DrawString(v.ToString("0"), fAxis, dim, left - sz.Width - 2 * k, Y(v) - sz.Height / 2);
                }
                g.DrawString("Gbps", fAxis, dim, 4 * k, bottom + 3 * k);

                int n = Math.Max(Steps.Count, 1);
                float slot = (right - left) / n, bw = Math.Min(slot * 0.34f, 34 * k);
                for (int i = 0; i < Steps.Count; i++)
                {
                    var s = Steps[i];
                    float cx = left + slot * (i + 0.5f);
                    Color c = s.Pass ? Color.FromArgb(76, 175, 80) : Color.FromArgb(229, 83, 75);
                    using (var tx = new SolidBrush(Color.FromArgb(120, c)))
                    using (var rx = new SolidBrush(c))
                    {
                        g.FillRectangle(tx, cx - bw - 1 * k, Y(s.TxGbps), bw, bottom - Y(s.TxGbps));
                        g.FillRectangle(rx, cx + 1 * k, Y(s.RxGbps), bw, bottom - Y(s.RxGbps));
                    }
                    string val = s.RxGbps.ToString("0.0");
                    var vs = g.MeasureString(val, fVal);
                    g.DrawString(val, fVal, txt, cx + 1 * k + bw / 2 - vs.Width / 2, Y(s.RxGbps) - vs.Height);
                    string lab = s.Fps + " fps";
                    var ls = g.MeasureString(lab, fAxis);
                    g.DrawString(lab, fAxis, txt, cx - ls.Width / 2, bottom + 3 * k);
                    string res = s.Pass ? "all intact" : s.S.FramesOk == s.S.FramesSent && s.S.FramesSent > 0 ? "too slow" : string.Format("{0} / {1}", s.S.FramesOk, s.S.FramesSent);
                    var rs = g.MeasureString(res, fVal);
                    using (var rb = new SolidBrush(c))
                        g.DrawString(res, fVal, rb, cx - rs.Width / 2, bottom + 3 * k + ls.Height);
                }
            }
        }
    }

    // ---------------------------------------------------------------- window
    sealed class MainForm : Form
    {
        readonly Options o;
        readonly TextBox ip = new TextBox(), port = new TextBox(), flows = new TextBox(), res = new TextBox(),
                         fps = new TextBox(), secs = new TextBox(), sweep = new TextBox();
        readonly Button start = new Button { Text = "Start" }, sweepB = new Button { Text = "Sweep" }, stopB = new Button { Text = "Stop", Enabled = false };
        readonly PictureBox left = new PictureBox(), right = new PictureBox();
        readonly Label leftCap = new Label(), rightCap = new Label();
        readonly TextBox stats = new TextBox { Multiline = true, ReadOnly = true, Font = new Font("Consolas", 9.5f), BorderStyle = BorderStyle.None };
        readonly SweepChart chart = new SweepChart();
        readonly System.Windows.Forms.Timer ui = new System.Windows.Forms.Timer { Interval = 200 };

        Bitmap[] previews;                    // scaled cycle frames (sent side)
        byte[] rxFrame;
        long rxId = -1;
        int shownCycle = -1;
        string openKey;
        volatile bool stopReq;
        Thread worker;
        readonly List<StepResult> results = new List<StepResult>();
        string status = "";
        int curFps;

        public MainForm(Options opt)
        {
            o = opt;
            Text = "RFSoC 4x2 UDP Loopback Viewer";
            float k;                            // process is DPI aware: scale the layout by hand
            using (var g = CreateGraphics()) k = g.DpiX / 96f;
            Func<int, int> S = v => (int)Math.Round(v * k);
            var wa = Screen.PrimaryScreen.WorkingArea;       // fit the screen (taskbar excluded)
            ClientSize = new Size(Math.Min(S(1360), wa.Width - S(16)), Math.Min(S(860), wa.Height - S(48)));
            StartPosition = FormStartPosition.Manual;
            Location = new Point(wa.Left + (wa.Width - Width) / 2, wa.Top);
            BackColor = Color.FromArgb(32, 32, 36);
            ForeColor = Color.Gainsboro;
            Font = new Font("Segoe UI", 9.5f);

            var bar = new FlowLayoutPanel { Dock = DockStyle.Top, Height = S(40), Padding = new Padding(S(8), S(8), S(8), 0) };
            AddField(bar, "FPGA IP", ip, o.Ip, S(110));
            AddField(bar, "Port", port, o.Port.ToString(), S(48));
            AddField(bar, "Flows", flows, o.Flows.ToString(), S(32));
            AddField(bar, "Resolution", res, o.Width + "x" + o.Height, S(80));
            AddField(bar, "FPS", fps, o.Fps.ToString(), S(40));
            AddField(bar, "Seconds", secs, o.Seconds.ToString(CultureInfo.InvariantCulture), S(36));
            AddField(bar, "Sweep FPS", sweep, o.Sweep != null ? string.Join(",", o.Sweep) : "60,90,100,110,120,125,130", S(170));
            foreach (var b in new[] { start, sweepB, stopB })
            {
                b.Width = S(70); b.Height = S(26); b.FlatStyle = FlatStyle.Flat; b.BackColor = Color.FromArgb(60, 60, 68);
                b.Margin = new Padding(S(10), 0, 0, 0);
                bar.Controls.Add(b);
            }
            start.Click += delegate { Begin(false); };
            sweepB.Click += delegate { Begin(true); };
            stopB.Click += delegate { stopReq = true; Native.lb_stop(); };

            var gridT = new TableLayoutPanel { Dock = DockStyle.Fill, ColumnCount = 2, RowCount = 4, Padding = new Padding(S(8)) };
            gridT.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 50));
            gridT.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 50));
            gridT.RowStyles.Add(new RowStyle(SizeType.Absolute, S(24)));
            gridT.RowStyles.Add(new RowStyle(SizeType.Percent, 52));
            gridT.RowStyles.Add(new RowStyle(SizeType.Percent, 48));
            gridT.RowStyles.Add(new RowStyle(SizeType.Absolute, S(118)));
            leftCap.Text = "Sent"; rightCap.Text = "Received (echoed by the FPGA, compared byte by byte)";
            foreach (var l in new[] { leftCap, rightCap }) { l.Dock = DockStyle.Fill; l.TextAlign = ContentAlignment.MiddleLeft; }
            foreach (var p in new[] { left, right }) { p.Dock = DockStyle.Fill; p.SizeMode = PictureBoxSizeMode.Zoom; p.BackColor = Color.Black; }
            gridT.Controls.Add(leftCap, 0, 0); gridT.Controls.Add(rightCap, 1, 0);
            gridT.Controls.Add(left, 0, 1); gridT.Controls.Add(right, 1, 1);
            chart.Dock = DockStyle.Fill; chart.BackColor = Color.FromArgb(24, 24, 28); chart.ForeColor = ForeColor;
            chart.Title = "Sweep: press Sweep to find the highest frame rate that comes back intact";
            gridT.Controls.Add(chart, 0, 2); gridT.SetColumnSpan(chart, 2);
            stats.Dock = DockStyle.Fill; stats.BackColor = BackColor; stats.ForeColor = ForeColor;
            gridT.Controls.Add(stats, 0, 3); gridT.SetColumnSpan(stats, 2);

            Controls.Add(gridT);
            Controls.Add(bar);
            ui.Tick += delegate { RefreshUi(); };
            if (o.Auto) Shown += delegate { Begin(o.Sweep != null); };
            FormClosing += delegate { stopReq = true; Native.lb_stop(); if (worker != null) worker.Join(3000); Native.lb_close(); };
        }

        static void AddField(Control parent, string label, TextBox box, string value, int width)
        {
            parent.Controls.Add(new Label { Text = label, AutoSize = true, Margin = new Padding(6, 5, 2, 0) });
            box.Text = value; box.Width = width; box.BackColor = Color.FromArgb(50, 50, 56); box.ForeColor = Color.White;
            box.BorderStyle = BorderStyle.FixedSingle;
            parent.Controls.Add(box);
        }

        void Begin(bool isSweep)
        {
            int[] list;
            try
            {
                o.Ip = ip.Text.Trim();
                o.Port = int.Parse(port.Text);
                o.Flows = int.Parse(flows.Text);
                var p = res.Text.Split('x');
                o.Width = int.Parse(p[0]); o.Height = int.Parse(p[1]);
                o.Fps = int.Parse(fps.Text);
                o.Seconds = double.Parse(secs.Text, CultureInfo.InvariantCulture);
                list = isSweep ? Options.ParseList(sweep.Text) : new[] { o.Fps };
            }
            catch (Exception e) { MessageBox.Show(this, e.Message, "Invalid settings"); return; }
            start.Enabled = sweepB.Enabled = false; stopB.Enabled = true;
            stopReq = false;
            results.Clear();
            chart.Steps.Clear();
            chart.Title = isSweep ? string.Format("Sweep {0}x{1}: running ...", o.Width, o.Height) : string.Format("{0}x{1} @ {2} fps", o.Width, o.Height, o.Fps);
            chart.Invalidate();
            worker = new Thread(() => Work(list, isSweep)) { IsBackground = true };
            worker.Start();
            ui.Start();
        }

        // open (or reuse) the engine, render and hand over the cycle frames, check the echo
        bool Setup()
        {
            string key = string.Join("|", o.Ip, o.Port, o.Flows, o.Width, o.Height, o.Payload, o.Cycle, o.RxThreads, o.TxThreads);
            if (key == openKey) return true;
            Native.lb_close();
            openKey = null;
            status = "allocating buffers ...";
            var c = new Native.Config { Ip = o.Ip, Port = o.Port, Flows = o.Flows, Width = o.Width, Height = o.Height,
                                        Payload = o.Payload, Cycle = o.Cycle, RxThreads = o.RxThreads, TxThreads = o.TxThreads };
            if (Native.lb_open(ref c) == 0) { status = "lb_open: " + Native.Error(); return false; }
            var gen = new FrameGenerator(o.Width, o.Height);
            int pw = 640, ph = Math.Max(1, 640 * o.Height / o.Width);
            previews = new Bitmap[o.Cycle];
            for (int i = 0; i < o.Cycle; i++)
            {
                status = string.Format("rendering frame {0}/{1} ...", i + 1, o.Cycle);
                var b = gen.Render(i, o.Cycle);
                Imaging.CopyTo(b, Native.lb_frame(i));
                previews[i] = Imaging.Scaled(b, pw, ph);
            }
            rxFrame = new byte[o.Width * o.Height * 3];
            status = "checking the echo of every flow ...";
            if (Native.lb_prepare() == 0) { status = Native.Error(); Native.lb_close(); return false; }
            openKey = key;
            return true;
        }

        void Work(int[] list, bool isSweep)
        {
            try
            {
                if (!Setup()) return;
                foreach (int f in list)
                {
                    if (stopReq) break;
                    curFps = f;
                    rxId = -1;
                    status = isSweep ? string.Format("sweep step {0} fps ...", f) : "running ...";
                    Native.lb_run(f, o.Seconds, o.Spread, o.MaxGbps);
                    Native.Stats s;
                    do { Thread.Sleep(50); Native.lb_get_stats(out s); } while (s.Running != 0);
                    var r = new StepResult { Fps = f, Seconds = o.Seconds, S = s };
                    lock (results) results.Add(r);
                    if (isSweep)
                    {
                        // stop after two failed steps in a row
                        int n = results.Count;
                        if (n >= 2 && !results[n - 1].Pass && !results[n - 2].Pass) break;
                    }
                    Thread.Sleep(500);
                }
                status = "done";
            }
            finally { BeginInvoke((Action)Done); }
        }

        void Done()
        {
            ui.Stop();
            RefreshUi();
            start.Enabled = sweepB.Enabled = true; stopB.Enabled = false;
            try
            {
                Directory.CreateDirectory(o.OutDir);
                File.WriteAllText(Path.Combine(o.OutDir, "summary.txt"), Report());
                if (o.Shot != null)
                {
                    Activate();
                    Refresh();
                    Application.DoEvents();
                    Thread.Sleep(300);
                    using (var b = new Bitmap(ClientSize.Width, ClientSize.Height))
                    using (var g = Graphics.FromImage(b))
                    {
                        g.CopyFromScreen(PointToScreen(Point.Empty), Point.Empty, b.Size);
                        b.Save(o.Shot, ImageFormat.Png);
                    }
                }
            }
            catch { }
            if (o.Exit) Close();
        }

        string Line(StepResult r)
        {
            return string.Format(CultureInfo.InvariantCulture,
                "{0}x{1} @ {2,3} fps  frames {3,5} sent {4,5} intact {5} corrupted {6} incomplete   packets lost {7:F4} %   TX {8:F2} / RX {9:F2} Gbps   latency {10:F1} / {11:F1} ms",
                o.Width, o.Height, r.Fps, r.S.FramesSent, r.S.FramesOk, r.S.FramesBad, r.Incomplete, r.LostPct,
                r.TxGbps, r.RxGbps, r.S.LatencyAvgMs, r.S.LatencyMaxMs);
        }

        string Report()
        {
            var sb = new StringBuilder();
            sb.AppendFormat("FPGA {0} (+0..{2}) port {1}, {3} flows   payload {4} B   {5} packets/frame   {6} s per step\r\n",
                o.Ip, o.Port, o.Flows - 1, o.Flows, o.Payload,
                (o.Width * o.Height * 3 + o.Payload - 1) / o.Payload, o.Seconds);
            lock (results) foreach (var r in results) sb.AppendLine(Line(r));
            if (status != "done") sb.AppendLine(status);
            var best = BestPass();
            if (best != null)
                sb.AppendFormat(CultureInfo.InvariantCulture, "Ceiling: {0}x{1} @ {2} fps, {3:F2} Gbps each way, all frames intact\r\n",
                    o.Width, o.Height, best.Fps, best.RxGbps);
            return sb.ToString();
        }

        StepResult BestPass()
        {
            lock (results) return results.Where(r => r.Pass).OrderByDescending(r => r.Fps).FirstOrDefault();
        }

        void RefreshUi()
        {
            if (previews != null)
            {
                Native.Stats s;
                Native.lb_get_stats(out s);
                int cyc = s.FramesSent > 0 ? (int)((s.FramesSent - 1) % o.Cycle) : 0;
                if (cyc != shownCycle)
                {
                    shownCycle = cyc;
                    left.Image = previews[cyc];
                    leftCap.Text = string.Format("Sent   frame {0}   ({1}x{2}, {3} packets)", Math.Max(0, s.FramesSent - 1), o.Width, o.Height, s.PacketsPerFrame);
                }
                long id = rxId;
                if (rxFrame != null && Native.lb_latest(rxFrame, ref id) == 1)
                {
                    rxId = id;
                    using (var full = Imaging.FromBytes(rxFrame, o.Width, o.Height))
                    {
                        var old = right.Image;
                        right.Image = Imaging.Scaled(full, previews[0].Width, previews[0].Height);
                        if (old != null) old.Dispose();
                    }
                    rightCap.Text = string.Format("Received   frame {0}   intact (byte-exact)", id);
                }
                var live = new StepResult { Fps = curFps, Seconds = o.Seconds, S = s };
                var sb = new StringBuilder();
                sb.AppendLine(status);
                if (s.Running != 0) sb.AppendLine("now:  " + Line(live));
                lock (results) foreach (var r in results.Skip(Math.Max(0, results.Count - 4))) sb.AppendLine(Line(r));
                stats.Text = sb.ToString();
            }
            else stats.Text = status;

            lock (results)
            {
                if (chart.Steps.Count != results.Count)
                {
                    chart.Steps.Clear();
                    chart.Steps.AddRange(results);
                    var best = BestPass();
                    bool running = worker != null && worker.IsAlive;
                    if (results.Count > 1 || !running)
                        chart.Title = best != null
                            ? string.Format(CultureInfo.InvariantCulture, "{0}x{1} video loopback ceiling: {2} fps = {3:F1} Gbps each way, every frame intact{4}",
                                o.Width, o.Height, best.Fps, best.RxGbps, running ? "  (sweep running)" : "")
                            : string.Format("{0}x{1}: no step came back intact", o.Width, o.Height);
                    chart.Invalidate();
                }
            }
        }
    }

    static class Program
    {
        [DllImport("user32.dll")]
        static extern bool SetProcessDPIAware();

        [STAThread]
        static void Main(string[] args)
        {
            SetProcessDPIAware();
            Application.EnableVisualStyles();
            Application.SetCompatibleTextRenderingDefault(false);
            Application.Run(new MainForm(Options.Parse(args)));
        }
    }
}
