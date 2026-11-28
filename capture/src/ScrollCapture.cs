// 스크롤 캡처: 지정한 영역 위에서 마우스 휠을 굴려 가며 찍고 한 장으로 잇는다.
using System;
using System.Drawing;
using System.Windows.Forms;

static class ScrollCapture
{
    const int MaxRows = 30000;        // 결과 이미지 최대 높이
    const int MaxPixels = 60000000;   // 결과 이미지 최대 크기 (약 240MB)

    // 끝나면 이어 붙인 이미지를 돌려준다. note 에는 사용자에게 알릴 말이 있으면 담는다
    public static Bitmap Run(Rectangle rect, out string note)
    {
        note = null;
        int w = rect.Width, h = rect.Height;
        int maxRows = Math.Max(h, Math.Min(MaxRows, MaxPixels / w));

        using (FrameForm frame = new FrameForm(rect))
        using (Bitmap buf = new Bitmap(w, h, System.Drawing.Imaging.PixelFormat.Format32bppRgb))
        {
            frame.Show();

            // 영역 가운데로 마우스를 옮기고 그 아래 창을 앞으로 가져온다 (휠 입력이 그 창으로 가도록)
            Point center = new Point(rect.Left + w / 2, rect.Top + h / 2);
            Native.SetCursorPos(center.X, center.Y);
            Native.POINT pt; pt.X = center.X; pt.Y = center.Y;
            IntPtr target = Native.GetAncestor(Native.WindowFromPoint(pt), Native.GA_ROOT);
            if (target != IntPtr.Zero) Native.SetForegroundWindow(target);
            Grab.Wait(250);

            int[] prev = Settle(rect, buf, 0);
            Stitcher st = new Stitcher(w, h, prev, maxRows);
            int notches = 1;
            int perNotch = 0;   // 휠 한 칸에 움직인 줄 수 (지금까지 본 최댓값)
            int stuck = 0;

            while (true)
            {
                if (EscPressed()) { note = "Esc 로 중지했습니다."; break; }
                Native.SetCursorPos(center.X, center.Y);
                Native.mouse_event(Native.MOUSEEVENTF_WHEEL, 0, 0, -120 * notches, UIntPtr.Zero);
                int[] cur = Settle(rect, buf, 120);

                int offset;
                Stitcher.Result r = st.Add(cur, perNotch * notches, out offset);
                if (r == Stitcher.Result.NoChange)
                {
                    // 늦게 반응하는 화면일 수 있으니 한 번 더 굴려 본다
                    if (++stuck >= 2) break;
                    continue;
                }
                if (r == Stitcher.Result.NoMatch)
                {
                    note = "이어지는 부분을 찾지 못해 여기까지만 캡처했습니다.";
                    break;
                }
                stuck = 0;
                if (st.Full) { note = "최대 길이에 도달해 멈췄습니다."; break; }

                // 다음에는 영역 높이의 40% 쯤 움직이도록 휠 칸 수를 맞춘다
                perNotch = Math.Max(perNotch, Math.Max(1, offset / notches));
                notches = Math.Max(1, Math.Min(10, (h * 2 / 5) / perNotch));
            }

            frame.Hide();
            return Grab.FromPixels(st.Canvas, w, st.Rows);
        }
    }

    static bool EscPressed()
    {
        return (Native.GetAsyncKeyState(Native.VK_ESCAPE) & 0x8000) != 0;
    }

    // 스크롤 움직임이 멎을 때까지 기다렸다가 찍는다 (연달아 두 번 같은 화면이 나오면 멎은 것)
    static int[] Settle(Rectangle rect, Bitmap buf, int firstWait)
    {
        Grab.Wait(firstWait);
        int[] a = Shot(rect, buf);
        int start = Environment.TickCount;
        while (Environment.TickCount - start < 1500)
        {
            Grab.Wait(70);
            int[] b = Shot(rect, buf);
            if (Same(a, b)) return b;
            a = b;
        }
        return a;
    }

    static int[] Shot(Rectangle rect, Bitmap buf)
    {
        using (Graphics g = Graphics.FromImage(buf))
            g.CopyFromScreen(rect.Location, Point.Empty, rect.Size, CopyPixelOperation.SourceCopy);
        return Grab.Pixels(buf);
    }

    static bool Same(int[] a, int[] b)
    {
        for (int i = 0; i < a.Length; i++) if (a[i] != b[i]) return false;
        return true;
    }

    // 캡처 중인 영역을 둘러싸는 빨간 테두리. 영역 바깥쪽에만 그려져 캡처에 찍히지 않는다
    sealed class FrameForm : Form
    {
        const int T = 3;

        public FrameForm(Rectangle rect)
        {
            AutoScaleMode = AutoScaleMode.None;
            FormBorderStyle = FormBorderStyle.None;
            StartPosition = FormStartPosition.Manual;
            ShowInTaskbar = false;
            TopMost = true;
            BackColor = Color.Red;
            Bounds = Rectangle.Inflate(rect, T, T);
            Region rg = new Region(new Rectangle(0, 0, rect.Width + T * 2, rect.Height + T * 2));
            rg.Exclude(new Rectangle(T, T, rect.Width, rect.Height));
            Region = rg;
        }

        protected override bool ShowWithoutActivation { get { return true; } }

        protected override CreateParams CreateParams
        {
            get
            {
                CreateParams cp = base.CreateParams;
                cp.ExStyle |= Native.WS_EX_NOACTIVATE | Native.WS_EX_TOOLWINDOW;
                return cp;
            }
        }
    }
}
