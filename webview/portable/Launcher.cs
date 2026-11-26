// 포터블 버전의 실행 파일. 옆의 App\google_messages_web.exe 를 받은 인자 그대로 연다.
// 앱은 App\portable 파일을 보고 설정·로그인 정보를 Data 폴더에 둔다 (lib/portable.dart).
using System;
using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Text;

[assembly: AssemblyTitle("Google 메시지 웹 (포터블)")]
[assembly: AssemblyProduct("Google 메시지 웹")]
[assembly: AssemblyCompany("chowonki")]

static class Launcher
{
    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    static extern int MessageBoxW(IntPtr owner, string text, string caption, uint type);

    [DllImport("user32.dll")]
    static extern bool AllowSetForegroundWindow(int processId);

    // CommandLineToArgvW 가 그대로 되읽도록 인자 하나를 따옴표로 감싼다
    static string Quote(string arg)
    {
        if (arg.Length > 0 && arg.IndexOfAny(new[] { ' ', '\t', '"' }) < 0) return arg;
        var sb = new StringBuilder("\"");
        int backslashes = 0;
        foreach (char c in arg)
        {
            if (c == '\\') { backslashes++; continue; }
            if (c == '"') sb.Append('\\', backslashes * 2 + 1);
            else sb.Append('\\', backslashes);
            backslashes = 0;
            sb.Append(c);
        }
        sb.Append('\\', backslashes * 2).Append('"');
        return sb.ToString();
    }

    [STAThread]
    static int Main(string[] args)
    {
        string root = Path.GetDirectoryName(Assembly.GetExecutingAssembly().Location);
        string appDir = Path.Combine(root, "App");
        string exe = Path.Combine(appDir, "google_messages_web.exe");
        if (!File.Exists(exe))
        {
            MessageBoxW(IntPtr.Zero,
                "App 폴더에서 프로그램을 찾을 수 없습니다.\n압축을 모두 푼 뒤 다시 실행해 주세요.\n\n" + exe,
                "Google 메시지 웹", 0x10);
            return 1;
        }
        try
        {
            Directory.CreateDirectory(Path.Combine(root, "Data"));
        }
        catch (Exception)
        {
            // 쓸 수 없는 곳이면 앱이 %APPDATA% 를 쓴다
        }

        var parts = new string[args.Length];
        for (int i = 0; i < args.Length; i++) parts[i] = Quote(args[i]);
        var info = new ProcessStartInfo(exe, string.Join(" ", parts))
        {
            WorkingDirectory = appDir,
            UseShellExecute = false,
        };
        using (var app = Process.Start(info))
        {
            // 이미 실행 중이던 앱이 창을 앞으로 가져올 수 있게 한다
            AllowSetForegroundWindow(-1);
        }
        return 0;
    }
}
