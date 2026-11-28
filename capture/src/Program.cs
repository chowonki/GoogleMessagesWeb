// 화면 캡처 프로그램 시작점
using System;
using System.Threading;
using System.Windows.Forms;

static class Program
{
    [STAThread]
    static void Main()
    {
        // 모니터마다 배율이 달라도 실제 픽셀 그대로 찍도록 한다 (app.manifest 에도 같은 설정이 있다)
        try
        {
            if (!Native.SetProcessDpiAwarenessContext(new IntPtr(-4))) Native.SetProcessDPIAware();
        }
        catch { try { Native.SetProcessDPIAware(); } catch { } }

        bool first;
        using (Mutex mutex = new Mutex(true, "ScreenCapture_SingleInstance_7c1f", out first))
        {
            if (!first)
            {
                MessageBox.Show("화면 캡처가 이미 실행 중입니다. 트레이 아이콘을 확인하세요.", "화면 캡처", MessageBoxButtons.OK, MessageBoxIcon.Information);
                return;
            }
            Application.EnableVisualStyles();
            Application.SetCompatibleTextRenderingDefault(false);
            Settings.Load();
            Application.Run(new MainForm());
        }
    }
}
