// 캡처 결과 창: 이미지를 보여 주고 복사·저장한다
using System;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Imaging;
using System.IO;
using System.Windows.Forms;

sealed class PreviewForm : Form
{
    readonly Bitmap image;
    string savedPath;
    readonly Panel scroller;
    readonly PictureBox picture;
    readonly Label status;

    public PreviewForm(Bitmap image, string savedPath, string note, Icon icon)
    {
        this.image = image;
        this.savedPath = savedPath;

        Text = string.Format("캡처 결과 - {0} × {1}", image.Width, image.Height);
        Icon = icon;
        Font = SystemFonts.MessageBoxFont;
        AutoScaleMode = AutoScaleMode.None;   // 글자 크기에 맞춰 스스로 커지는 배치라 따로 배율을 곱하지 않는다
        StartPosition = FormStartPosition.CenterScreen;
        KeyPreview = true;
        MinimumSize = new Size(420, 300);

        FlowLayoutPanel bar = new FlowLayoutPanel();
        bar.Dock = DockStyle.Top;
        bar.AutoSize = true;
        bar.Padding = new Padding(6);
        bar.Controls.Add(MakeButton("복사 (Ctrl+C)", delegate { Copy(); }));
        bar.Controls.Add(MakeButton("다른 이름으로 저장 (Ctrl+S)", delegate { SaveAs(); }));
        bar.Controls.Add(MakeButton("저장 폴더 열기", delegate { OpenFolder(); }));
        bar.Controls.Add(MakeButton("닫기 (Esc)", delegate { Close(); }));

        status = new Label();
        status.Dock = DockStyle.Bottom;
        status.AutoSize = false;
        status.Height = Font.Height + 12;
        status.Padding = new Padding(8, 5, 8, 0);
        status.AutoEllipsis = true;

        picture = new PictureBox();
        picture.Image = image;
        picture.SizeMode = PictureBoxSizeMode.Zoom;
        picture.Location = Point.Empty;

        scroller = new Panel();
        scroller.Dock = DockStyle.Fill;
        scroller.AutoScroll = true;
        scroller.BackColor = Color.FromArgb(60, 60, 60);
        scroller.Controls.Add(picture);
        scroller.Resize += delegate { Layout2(); };

        Controls.Add(scroller);
        Controls.Add(status);
        Controls.Add(bar);

        // 창 크기: 이미지에 맞추되 화면의 75% 를 넘지 않게
        Rectangle wa = Screen.FromPoint(Cursor.Position).WorkingArea;
        int cw = Math.Max(480, Math.Min(image.Width + 40, wa.Width * 3 / 4));
        int ch = Math.Max(320, Math.Min(image.Height + 140, wa.Height * 3 / 4));
        ClientSize = new Size(cw, ch);

        string msg = savedPath != null ? "저장됨: " + savedPath : "저장하지 않음";
        if (Settings.AutoCopy) msg += "  ·  클립보드에 복사됨";
        if (note != null) msg = note + "  ·  " + msg;
        status.Text = msg;
    }

    Button MakeButton(string text, EventHandler onClick)
    {
        Button b = new Button();
        b.Text = text;
        b.AutoSize = true;
        b.AutoSizeMode = AutoSizeMode.GrowAndShrink;
        b.Padding = new Padding(6, 3, 6, 3);
        b.Click += onClick;
        return b;
    }

    // 이미지를 창에 맞춘다. 세로로 긴 이미지(스크롤 캡처)는 너비에 맞추고 세로로 스크롤한다
    void Layout2()
    {
        int pw = scroller.ClientSize.Width, ph = scroller.ClientSize.Height;
        if (pw <= 0 || ph <= 0) return;
        double scale = Math.Min(1.0, (double)pw / image.Width);
        bool tall = image.Height * scale > ph * 1.5;
        if (tall)
        {
            int avail = pw - SystemInformation.VerticalScrollBarWidth;
            scale = Math.Min(1.0, (double)Math.Max(avail, 50) / image.Width);
            scale = Math.Min(scale, 30000.0 / image.Height);
        }
        else
        {
            scale = Math.Min(scale, (double)ph / image.Height);
        }
        Size s = new Size(Math.Max(1, (int)(image.Width * scale)), Math.Max(1, (int)(image.Height * scale)));
        if (picture.Size != s) picture.Size = s;
        Point at = scroller.AutoScrollPosition;
        int x = s.Width < pw ? (pw - s.Width) / 2 : at.X;
        int y = s.Height < ph ? (ph - s.Height) / 2 : at.Y;
        picture.Location = new Point(x, y);
    }

    protected override void OnShown(EventArgs e)
    {
        base.OnShown(e);
        Layout2();
        Activate();
    }

    protected override void OnKeyDown(KeyEventArgs e)
    {
        if (e.KeyCode == Keys.Escape) Close();
        else if (e.Control && e.KeyCode == Keys.C) Copy();
        else if (e.Control && e.KeyCode == Keys.S) SaveAs();
        base.OnKeyDown(e);
    }

    protected override void OnFormClosed(FormClosedEventArgs e)
    {
        picture.Image = null;
        image.Dispose();
        base.OnFormClosed(e);
    }

    void Copy()
    {
        try
        {
            Clipboard.SetImage(image);
            status.Text = "클립보드에 복사했습니다.";
        }
        catch (Exception ex) { status.Text = "복사하지 못했습니다: " + ex.Message; }
    }

    void SaveAs()
    {
        using (SaveFileDialog dlg = new SaveFileDialog())
        {
            dlg.Filter = "PNG 이미지|*.png|JPEG 이미지|*.jpg|BMP 이미지|*.bmp";
            dlg.FileName = savedPath != null ? Path.GetFileNameWithoutExtension(savedPath) : FileNames.New();
            if (Directory.Exists(Settings.SaveDir)) dlg.InitialDirectory = Settings.SaveDir;
            if (dlg.ShowDialog(this) != DialogResult.OK) return;
            try
            {
                ImageFormat fmt = dlg.FilterIndex == 2 ? ImageFormat.Jpeg : dlg.FilterIndex == 3 ? ImageFormat.Bmp : ImageFormat.Png;
                image.Save(dlg.FileName, fmt);
                savedPath = dlg.FileName;
                status.Text = "저장됨: " + savedPath;
            }
            catch (Exception ex) { status.Text = "저장하지 못했습니다: " + ex.Message; }
        }
    }

    void OpenFolder()
    {
        try
        {
            if (savedPath != null && File.Exists(savedPath)) Process.Start("explorer.exe", "/select,\"" + savedPath + "\"");
            else
            {
                Directory.CreateDirectory(Settings.SaveDir);
                Process.Start("explorer.exe", "\"" + Settings.SaveDir + "\"");
            }
        }
        catch (Exception ex) { status.Text = "폴더를 열지 못했습니다: " + ex.Message; }
    }
}
