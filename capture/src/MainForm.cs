// 주 창 + 트레이 아이콘 + 전역 단축키. 캡처 명령은 모두 여기서 시작한다.
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Imaging;
using System.IO;
using System.Windows.Forms;

enum CaptureKind { Region = 1, Window = 2, Scroll = 3, Full = 4 }

static class FileNames
{
    public static string New()
    {
        return "캡처_" + DateTime.Now.ToString("yyyyMMdd_HHmmss");
    }
}

sealed class MainForm : Form
{
    readonly NotifyIcon tray;
    readonly Icon appIcon;
    readonly Dictionary<CaptureKind, bool> hotkeyOk = new Dictionary<CaptureKind, bool>();
    readonly Label folderLabel;
    bool busy, exiting, trayTipShown;

    static readonly string[] HotkeyNames = { "", "PrtSc", "Alt+PrtSc", "Shift+PrtSc", "Ctrl+PrtSc" };
    static readonly uint[] HotkeyMods = { 0, 0, Native.MOD_ALT, Native.MOD_SHIFT, Native.MOD_CONTROL };
    static readonly string[] KindNames = { "", "영역 캡처", "창 캡처", "스크롤 캡처", "전체 화면 캡처" };

    public MainForm()
    {
        appIcon = MakeIcon();
        Text = "화면 캡처";
        Icon = appIcon;
        Font = SystemFonts.MessageBoxFont;
        AutoScaleMode = AutoScaleMode.None;   // 글자 크기에 맞춰 스스로 커지는 배치라 따로 배율을 곱하지 않는다
        FormBorderStyle = FormBorderStyle.FixedSingle;
        MaximizeBox = false;
        StartPosition = FormStartPosition.CenterScreen;
        AutoSize = true;
        AutoSizeMode = AutoSizeMode.GrowAndShrink;

        // 단축키는 창 핸들에 묶이므로 화면을 만들기 전에 먼저 등록해 결과를 버튼 글자에 반영한다
        for (int k = 1; k <= 4; k++)
            hotkeyOk[(CaptureKind)k] = Native.RegisterHotKey(Handle, k, HotkeyMods[k] | Native.MOD_NOREPEAT, Native.VK_SNAPSHOT);

        TableLayoutPanel root = new TableLayoutPanel();
        root.ColumnCount = 1;
        root.AutoSize = true;
        root.AutoSizeMode = AutoSizeMode.GrowAndShrink;
        root.Padding = new Padding(12);
        root.Dock = DockStyle.Fill;

        for (int k = 1; k <= 4; k++) root.Controls.Add(MakeCaptureButton((CaptureKind)k));

        root.Controls.Add(MakeCheck("캡처하면 클립보드에 복사", Settings.AutoCopy, delegate(bool v) { Settings.AutoCopy = v; }));
        root.Controls.Add(MakeCheck("캡처하면 파일로 자동 저장", Settings.AutoSave, delegate(bool v) { Settings.AutoSave = v; }));
        root.Controls.Add(MakeCheck("캡처 뒤 결과 창 보기", Settings.ShowPreview, delegate(bool v) { Settings.ShowPreview = v; }));

        folderLabel = new Label();
        folderLabel.AutoSize = true;
        folderLabel.MaximumSize = new Size(LogicalToDeviceUnitsCompat(330), 0);
        folderLabel.Margin = new Padding(3, 10, 3, 3);
        root.Controls.Add(folderLabel);
        UpdateFolderLabel();

        FlowLayoutPanel folderButtons = new FlowLayoutPanel();
        folderButtons.AutoSize = true;
        folderButtons.Margin = new Padding(0);
        folderButtons.Controls.Add(MakeSmallButton("폴더 바꾸기", delegate { ChooseFolder(); }));
        folderButtons.Controls.Add(MakeSmallButton("폴더 열기", delegate { OpenFolder(); }));
        root.Controls.Add(folderButtons);

        Label hint = new Label();
        hint.AutoSize = true;
        hint.ForeColor = SystemColors.GrayText;
        hint.MaximumSize = new Size(LogicalToDeviceUnitsCompat(330), 0);
        hint.Margin = new Padding(3, 10, 3, 3);
        hint.Text = "창을 닫아도 트레이에 남아 단축키로 캡처할 수 있습니다.";
        root.Controls.Add(hint);

        Controls.Add(root);

        ContextMenuStrip menu = new ContextMenuStrip();
        for (int k = 1; k <= 4; k++)
        {
            CaptureKind kind = (CaptureKind)k;
            menu.Items.Add(ButtonText(kind), null, delegate { Start(kind, false); });
        }
        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add("창 열기", null, delegate { ShowMain(); });
        menu.Items.Add("저장 폴더 열기", null, delegate { OpenFolder(); });
        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add("끝내기", null, delegate { exiting = true; Close(); });

        tray = new NotifyIcon();
        tray.Icon = appIcon;
        tray.Text = "화면 캡처";
        tray.ContextMenuStrip = menu;
        tray.Visible = true;
        tray.MouseClick += delegate(object s, MouseEventArgs e) { if (e.Button == MouseButtons.Left) ShowMain(); };
    }

    // 96dpi 기준 길이를 지금 배율에 맞춘다
    int LogicalToDeviceUnitsCompat(int v)
    {
        using (Graphics g = CreateGraphics()) return (int)(v * g.DpiX / 96f);
    }

    string ButtonText(CaptureKind kind)
    {
        int k = (int)kind;
        return KindNames[k] + "   (" + (hotkeyOk[kind] ? HotkeyNames[k] : "단축키 사용 불가") + ")";
    }

    Button MakeCaptureButton(CaptureKind kind)
    {
        Button b = new Button();
        b.Text = ButtonText(kind);
        b.AutoSize = true;
        b.Dock = DockStyle.Fill;
        b.MinimumSize = new Size(LogicalToDeviceUnitsCompat(330), LogicalToDeviceUnitsCompat(40));
        b.Margin = new Padding(3, 3, 3, 6);
        b.Click += delegate { Start(kind, true); };
        return b;
    }

    Button MakeSmallButton(string text, EventHandler onClick)
    {
        Button b = new Button();
        b.Text = text;
        b.AutoSize = true;
        b.AutoSizeMode = AutoSizeMode.GrowAndShrink;
        b.Padding = new Padding(6, 3, 6, 3);
        b.Click += onClick;
        return b;
    }

    CheckBox MakeCheck(string text, bool value, Action<bool> set)
    {
        CheckBox c = new CheckBox();
        c.Text = text;
        c.AutoSize = true;
        c.Checked = value;
        c.CheckedChanged += delegate { set(c.Checked); Settings.Save(); };
        return c;
    }

    void UpdateFolderLabel() { folderLabel.Text = "저장 폴더: " + Settings.SaveDir; }

    void ChooseFolder()
    {
        using (FolderBrowserDialog dlg = new FolderBrowserDialog())
        {
            dlg.Description = "캡처 이미지를 저장할 폴더";
            if (Directory.Exists(Settings.SaveDir)) dlg.SelectedPath = Settings.SaveDir;
            if (dlg.ShowDialog(this) != DialogResult.OK) return;
            Settings.SaveDir = dlg.SelectedPath;
            Settings.Save();
            UpdateFolderLabel();
        }
    }

    void OpenFolder()
    {
        try
        {
            Directory.CreateDirectory(Settings.SaveDir);
            Process.Start("explorer.exe", "\"" + Settings.SaveDir + "\"");
        }
        catch (Exception ex) { MessageBox.Show(this, ex.Message, Text, MessageBoxButtons.OK, MessageBoxIcon.Warning); }
    }

    void ShowMain()
    {
        Show();
        if (WindowState == FormWindowState.Minimized) WindowState = FormWindowState.Normal;
        Activate();
    }

    protected override void WndProc(ref Message m)
    {
        if (m.Msg == Native.WM_HOTKEY)
        {
            int id = m.WParam.ToInt32();
            if (id >= 1 && id <= 4) Start((CaptureKind)id, false);
            return;
        }
        base.WndProc(ref m);
    }

    protected override void OnFormClosing(FormClosingEventArgs e)
    {
        if (!exiting && e.CloseReason == CloseReason.UserClosing)
        {
            // 닫기 = 트레이로 숨기기
            e.Cancel = true;
            Hide();
            if (!trayTipShown)
            {
                trayTipShown = true;
                tray.ShowBalloonTip(3000, "화면 캡처", "트레이에서 계속 실행 중입니다. 끝내려면 트레이 아이콘을 오른쪽 클릭하세요.", ToolTipIcon.Info);
            }
            return;
        }
        base.OnFormClosing(e);
    }

    protected override void OnFormClosed(FormClosedEventArgs e)
    {
        for (int k = 1; k <= 4; k++) Native.UnregisterHotKey(Handle, k);
        tray.Visible = false;
        tray.Dispose();
        base.OnFormClosed(e);
    }

    // fromUi: 주 창의 버튼으로 시작했으면 주 창을 잠깐 숨기고 찍는다
    void Start(CaptureKind kind, bool fromUi)
    {
        if (busy) return;
        busy = true;
        bool hidden = false;
        try
        {
            if (fromUi && Visible)
            {
                Hide();
                hidden = true;
                Grab.Wait(250);   // 창이 사라지는 효과가 끝날 때까지
            }
            string note;
            Bitmap result = Take(kind, out note);
            if (hidden) { Show(); hidden = false; }
            if (result != null) Deliver(result, note);
        }
        catch (Exception ex)
        {
            MessageBox.Show("캡처하지 못했습니다.\n" + ex.Message, "화면 캡처", MessageBoxButtons.OK, MessageBoxIcon.Warning);
        }
        finally
        {
            if (hidden) Show();
            busy = false;
        }
    }

    Bitmap Take(CaptureKind kind, out string note)
    {
        note = null;
        if (kind == CaptureKind.Full)
            return Grab.Screen(Screen.FromPoint(Cursor.Position).Bounds);

        Rectangle virt = SystemInformation.VirtualScreen;
        PickMode mode = kind == CaptureKind.Region ? PickMode.Region : kind == CaptureKind.Window ? PickMode.Window : PickMode.Scroll;
        List<WinInfo> wins = mode == PickMode.Region ? null : Grab.Windows();

        Rectangle rect;
        IntPtr window;
        bool occluded;
        using (Bitmap shot = Grab.Screen(virt))
        {
            using (OverlayForm ov = new OverlayForm(shot, virt, mode, wins))
            {
                if (ov.ShowDialog() != DialogResult.OK) return null;
                rect = ov.Result;
                window = ov.ResultWindow;
                occluded = ov.ResultOccluded;
            }
            rect.Intersect(virt);
            if (rect.Width < 2 || rect.Height < 2) return null;

            // 영역, 또는 가려지지 않은 창: 처음 찍어 둔 화면에서 잘라 낸다 (본 그대로)
            if (kind == CaptureKind.Region || (kind == CaptureKind.Window && !occluded))
            {
                Rectangle local = rect;
                local.Offset(-virt.X, -virt.Y);
                return Grab.Crop(shot, local);
            }
        }

        if (kind == CaptureKind.Window)
        {
            // 가려진 창은 앞으로 가져온 뒤 다시 찍는다
            Native.SetForegroundWindow(window);
            Grab.Wait(350);
            return Grab.Screen(rect);
        }

        Grab.Wait(200);   // 선택 화면이 사라질 때까지
        return ScrollCapture.Run(rect, out note);
    }

    void Deliver(Bitmap image, string note)
    {
        string path = null;
        if (Settings.AutoSave)
        {
            try
            {
                Directory.CreateDirectory(Settings.SaveDir);
                string name = FileNames.New();
                path = Path.Combine(Settings.SaveDir, name + ".png");
                for (int i = 2; File.Exists(path); i++) path = Path.Combine(Settings.SaveDir, name + "_" + i + ".png");
                image.Save(path, ImageFormat.Png);
            }
            catch (Exception ex)
            {
                path = null;
                note = "자동 저장 실패: " + ex.Message;
            }
        }
        if (Settings.AutoCopy)
        {
            try { Clipboard.SetImage(image); }
            catch { }   // 다른 프로그램이 클립보드를 잡고 있으면 건너뛴다
        }
        if (Settings.ShowPreview)
        {
            new PreviewForm(image, path, note, appIcon).Show();   // 이미지는 결과 창이 닫힐 때 정리한다
            return;
        }
        string msg = path != null ? "저장됨: " + path : Settings.AutoCopy ? "클립보드에 복사했습니다." : "캡처했지만 복사·저장 설정이 모두 꺼져 있습니다.";
        if (note != null) msg = note + "\n" + msg;
        tray.ShowBalloonTip(3000, "화면 캡처", msg, ToolTipIcon.Info);
        image.Dispose();
    }

    // 트레이·창 아이콘 (점선 사각형)
    static Icon MakeIcon()
    {
        using (Bitmap bmp = new Bitmap(32, 32, PixelFormat.Format32bppArgb))
        {
            using (Graphics g = Graphics.FromImage(bmp))
            {
                g.Clear(Color.Transparent);
                using (Brush b = new SolidBrush(Color.FromArgb(0, 120, 215))) g.FillRectangle(b, 2, 4, 28, 24);
                using (Pen p = new Pen(Color.White, 2f))
                {
                    p.DashPattern = new float[] { 2f, 1.5f };
                    g.DrawRectangle(p, 8, 10, 16, 12);
                }
            }
            IntPtr h = bmp.GetHicon();
            try { return (Icon)Icon.FromHandle(h).Clone(); }
            finally { Native.DestroyIcon(h); }
        }
    }
}
