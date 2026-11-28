// 영역·창을 고르는 화면. 찍어 둔 화면 전체를 어둡게 깔고, 고른 부분만 밝게 보여 준다.
using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.Windows.Forms;

enum PickMode
{
    Region,   // 끌어서 영역 지정
    Window,   // 창을 눌러 지정
    Scroll    // 끌거나 창을 눌러 스크롤할 곳 지정
}

sealed class OverlayForm : Form
{
    public Rectangle Result;        // 고른 영역 (화면 좌표)
    public IntPtr ResultWindow;     // 창을 눌러 골랐을 때 그 창
    public bool ResultOccluded;     // 그 창이 다른 창에 가려져 있었는지

    readonly PickMode mode;
    readonly List<WinInfo> wins;
    readonly Point origin;          // 이 창의 왼쪽 위가 화면에서 놓인 위치
    readonly Bitmap bright, dim;
    readonly Font font;
    readonly Rectangle hintScreen;  // 안내 글을 띄울 모니터 (이 창 기준 좌표)

    bool pressed, dragging;
    Point pressAt;
    Rectangle sel;
    int hover = -1;
    Rectangle dirty;

    public OverlayForm(Bitmap shot, Rectangle virt, PickMode mode, List<WinInfo> wins)
    {
        this.mode = mode;
        this.wins = wins ?? new List<WinInfo>();
        origin = virt.Location;

        bright = new Bitmap(shot.Width, shot.Height, PixelFormat.Format32bppPArgb);
        dim = new Bitmap(shot.Width, shot.Height, PixelFormat.Format32bppPArgb);
        Rectangle all = new Rectangle(0, 0, shot.Width, shot.Height);
        using (Graphics g = Graphics.FromImage(bright)) g.DrawImage(shot, all, all, GraphicsUnit.Pixel);
        using (Graphics g = Graphics.FromImage(dim))
        {
            g.DrawImage(shot, all, all, GraphicsUnit.Pixel);
            using (Brush b = new SolidBrush(Color.FromArgb(110, 0, 0, 0))) g.FillRectangle(b, all);
        }

        font = new Font(SystemFonts.MessageBoxFont.FontFamily, 10f);
        Rectangle scr = System.Windows.Forms.Screen.FromPoint(Cursor.Position).Bounds;
        scr.Offset(-origin.X, -origin.Y);
        hintScreen = scr;

        AutoScaleMode = AutoScaleMode.None;
        FormBorderStyle = FormBorderStyle.None;
        StartPosition = FormStartPosition.Manual;
        Bounds = virt;
        TopMost = true;
        ShowInTaskbar = false;
        KeyPreview = true;
        Cursor = Cursors.Cross;
        SetStyle(ControlStyles.AllPaintingInWmPaint | ControlStyles.UserPaint | ControlStyles.OptimizedDoubleBuffer, true);
    }

    bool AllowDrag { get { return mode != PickMode.Window; } }
    bool AllowWindow { get { return mode != PickMode.Region; } }

    protected override void OnShown(EventArgs e)
    {
        base.OnShown(e);
        Bounds = new Rectangle(origin, bright.Size);   // 배율이 다른 모니터에 걸쳐도 크기를 그대로 둔다
        Native.SetForegroundWindow(Handle);
        Activate();
        if (AllowWindow) SetHover(PointToClient(Cursor.Position));
    }

    protected override void Dispose(bool disposing)
    {
        if (disposing)
        {
            bright.Dispose();
            dim.Dispose();
            font.Dispose();
        }
        base.Dispose(disposing);
    }

    protected override void OnKeyDown(KeyEventArgs e)
    {
        if (e.KeyCode == Keys.Escape) { DialogResult = DialogResult.Cancel; }
        base.OnKeyDown(e);
    }

    protected override void OnMouseDown(MouseEventArgs e)
    {
        if (e.Button == MouseButtons.Right) { DialogResult = DialogResult.Cancel; return; }
        if (e.Button == MouseButtons.Left) { pressed = true; dragging = false; pressAt = e.Location; }
    }

    protected override void OnMouseMove(MouseEventArgs e)
    {
        if (pressed && AllowDrag)
        {
            if (!dragging && (Math.Abs(e.X - pressAt.X) > 3 || Math.Abs(e.Y - pressAt.Y) > 3)) { dragging = true; hover = -1; }
            if (dragging)
            {
                sel = Rectangle.FromLTRB(Math.Min(pressAt.X, e.X), Math.Min(pressAt.Y, e.Y), Math.Max(pressAt.X, e.X), Math.Max(pressAt.Y, e.Y));
                sel.Intersect(ClientRectangle);
                Repaint();
                return;
            }
        }
        if (AllowWindow && !dragging) SetHover(e.Location);
    }

    protected override void OnMouseUp(MouseEventArgs e)
    {
        if (e.Button != MouseButtons.Left || !pressed) return;
        pressed = false;
        if (dragging)
        {
            dragging = false;
            if (sel.Width >= 5 && sel.Height >= 5)
            {
                Result = sel;
                Result.Offset(origin);
                DialogResult = DialogResult.OK;
                return;
            }
            sel = Rectangle.Empty;
            Repaint();
            return;
        }
        if (AllowWindow && hover >= 0)
        {
            WinInfo w = wins[hover];
            Result = w.Bounds;
            ResultWindow = w.Handle;
            for (int i = 0; i < hover; i++)
                if (wins[i].Bounds.IntersectsWith(w.Bounds)) { ResultOccluded = true; break; }
            DialogResult = DialogResult.OK;
        }
    }

    void SetHover(Point client)
    {
        Point p = new Point(client.X + origin.X, client.Y + origin.Y);
        int found = -1;
        for (int i = 0; i < wins.Count; i++)
            if (wins[i].Bounds.Contains(p)) { found = i; break; }
        if (found == hover) return;
        hover = found;
        Repaint();
    }

    // 지금 밝게 보일 영역 (이 창 기준 좌표)
    Rectangle Active()
    {
        if (dragging) return sel;
        if (hover >= 0)
        {
            Rectangle r = wins[hover].Bounds;
            r.Offset(-origin.X, -origin.Y);
            return r;
        }
        return Rectangle.Empty;
    }

    string SizeText(Rectangle a) { return string.Format("{0} × {1}", a.Width, a.Height); }

    Rectangle LabelRect(Rectangle a)
    {
        if (a.IsEmpty) return Rectangle.Empty;
        Size s = TextRenderer.MeasureText(SizeText(a), font);
        s.Width += 12; s.Height += 6;
        int y = a.Top - s.Height - 4;
        if (y < 0) y = a.Top + 4;
        return new Rectangle(a.Left, y, s.Width, s.Height);
    }

    void Repaint()
    {
        Rectangle a = Active();
        Rectangle now = Rectangle.Empty;
        if (!a.IsEmpty) now = Rectangle.Union(Rectangle.Inflate(a, 4, 4), LabelRect(a));
        if (!dirty.IsEmpty) Invalidate(dirty);
        if (!now.IsEmpty) Invalidate(now);
        dirty = now;
    }

    protected override void OnPaintBackground(PaintEventArgs e) { }

    protected override void OnPaint(PaintEventArgs e)
    {
        Graphics g = e.Graphics;
        g.InterpolationMode = InterpolationMode.NearestNeighbor;
        g.PixelOffsetMode = PixelOffsetMode.Half;
        g.CompositingMode = CompositingMode.SourceCopy;
        Rectangle clip = e.ClipRectangle;
        g.DrawImage(dim, clip, clip, GraphicsUnit.Pixel);

        Rectangle a = Active();
        if (!a.IsEmpty)
        {
            Rectangle vis = Rectangle.Intersect(a, clip);
            if (!vis.IsEmpty) g.DrawImage(bright, vis, vis, GraphicsUnit.Pixel);
        }
        g.CompositingMode = CompositingMode.SourceOver;
        g.PixelOffsetMode = PixelOffsetMode.Default;
        if (!a.IsEmpty)
        {
            using (Pen pen = new Pen(Color.FromArgb(0, 150, 255), 2f))
                g.DrawRectangle(pen, a.X - 1, a.Y - 1, a.Width + 1, a.Height + 1);
            Rectangle lr = LabelRect(a);
            using (Brush bg = new SolidBrush(Color.FromArgb(220, 0, 0, 0))) g.FillRectangle(bg, lr);
            TextRenderer.DrawText(g, SizeText(a), font, lr, Color.White, TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter);
        }

        // 안내 글 (마우스가 있던 모니터 위쪽 가운데)
        string hint = mode == PickMode.Region ? "캡처할 영역을 끌어서 지정하세요  ·  Esc: 취소"
            : mode == PickMode.Window ? "캡처할 창을 누르세요  ·  Esc: 취소"
            : "스크롤할 영역을 끌어서 지정하거나 창을 누르세요  ·  Esc: 취소";
        Size hs = TextRenderer.MeasureText(hint, font);
        Rectangle hr = new Rectangle(hintScreen.Left + (hintScreen.Width - hs.Width - 28) / 2, hintScreen.Top + 24, hs.Width + 28, hs.Height + 14);
        if (hr.IntersectsWith(clip))
        {
            using (Brush bg = new SolidBrush(Color.FromArgb(215, 20, 20, 20))) g.FillRectangle(bg, hr);
            TextRenderer.DrawText(g, hint, font, hr, Color.White, TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter);
        }
    }
}
