// 화면 찍기와 창 목록
using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;
using System.Windows.Forms;

sealed class WinInfo
{
    public IntPtr Handle;
    public Rectangle Bounds;   // 화면 좌표 (그림자 제외한 실제 테두리)
}

static class Grab
{
    // 화면의 r 영역을 찍는다
    public static Bitmap Screen(Rectangle r)
    {
        Bitmap bmp = new Bitmap(r.Width, r.Height, PixelFormat.Format32bppRgb);
        try
        {
            using (Graphics g = Graphics.FromImage(bmp))
                g.CopyFromScreen(r.Location, Point.Empty, r.Size, CopyPixelOperation.SourceCopy);
        }
        catch
        {
            bmp.Dispose();
            throw;
        }
        return bmp;
    }

    public static int[] Pixels(Bitmap bmp)
    {
        int[] px = new int[bmp.Width * bmp.Height];
        BitmapData d = bmp.LockBits(new Rectangle(0, 0, bmp.Width, bmp.Height), ImageLockMode.ReadOnly, PixelFormat.Format32bppRgb);
        try { Marshal.Copy(d.Scan0, px, 0, px.Length); }
        finally { bmp.UnlockBits(d); }
        return px;
    }

    public static Bitmap FromPixels(int[] px, int w, int h)
    {
        Bitmap bmp = new Bitmap(w, h, PixelFormat.Format32bppRgb);
        BitmapData d = bmp.LockBits(new Rectangle(0, 0, w, h), ImageLockMode.WriteOnly, PixelFormat.Format32bppRgb);
        try { Marshal.Copy(px, 0, d.Scan0, w * h); }
        finally { bmp.UnlockBits(d); }
        return bmp;
    }

    public static Bitmap Crop(Bitmap src, Rectangle r)
    {
        r.Intersect(new Rectangle(0, 0, src.Width, src.Height));
        return src.Clone(r, PixelFormat.Format32bppRgb);
    }

    // 보이는 창을 위에 있는 것부터 차례로 돌려준다
    public static List<WinInfo> Windows()
    {
        List<WinInfo> list = new List<WinInfo>();
        Rectangle virt = SystemInformation.VirtualScreen;
        Native.EnumWindows(delegate(IntPtr hWnd, IntPtr lParam)
        {
            if (!Native.IsWindowVisible(hWnd) || Native.IsIconic(hWnd)) return true;
            int cloaked;
            if (Native.DwmGetWindowAttribute(hWnd, Native.DWMWA_CLOAKED, out cloaked, 4) == 0 && cloaked != 0) return true;
            // 마우스가 통과하는 투명 덮개 창은 고를 대상이 아니다
            if ((Native.GetWindowLong(hWnd, Native.GWL_EXSTYLE) & Native.WS_EX_TRANSPARENT) != 0) return true;

            Native.RECT rc;
            if (Native.DwmGetWindowAttribute(hWnd, Native.DWMWA_EXTENDED_FRAME_BOUNDS, out rc, 16) != 0)
            {
                if (!Native.GetWindowRect(hWnd, out rc)) return true;
            }
            Rectangle b = Rectangle.FromLTRB(rc.Left, rc.Top, rc.Right, rc.Bottom);
            b.Intersect(virt);
            if (b.Width < 8 || b.Height < 8) return true;

            WinInfo info = new WinInfo();
            info.Handle = hWnd;
            info.Bounds = b;
            list.Add(info);
            return true;
        }, IntPtr.Zero);
        return list;
    }

    // 창 목록을 그대로 두고 잠깐 기다린다 (화면이 다시 그려질 시간)
    public static void Wait(int ms)
    {
        int end = Environment.TickCount + ms;
        while (true)
        {
            Application.DoEvents();
            int left = end - Environment.TickCount;
            if (left <= 0) break;
            System.Threading.Thread.Sleep(Math.Min(left, 15));
        }
    }
}
