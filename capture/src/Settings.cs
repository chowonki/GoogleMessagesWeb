// 설정 (%APPDATA%\ScreenCapture\settings.ini 에 key=value 로 저장)
using System;
using System.IO;
using System.Text;

static class Settings
{
    public static bool AutoCopy = true;      // 캡처하면 클립보드에 복사
    public static bool AutoSave = true;      // 캡처하면 파일로 저장
    public static bool ShowPreview = true;   // 캡처 뒤 결과 창 띄우기
    public static string SaveDir = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.MyPictures), "화면캡처");

    static string FilePath
    {
        get { return Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "ScreenCapture", "settings.ini"); }
    }

    public static void Load()
    {
        try
        {
            if (!File.Exists(FilePath)) return;
            foreach (string line in File.ReadAllLines(FilePath, Encoding.UTF8))
            {
                int i = line.IndexOf('=');
                if (i <= 0) continue;
                string key = line.Substring(0, i).Trim(), value = line.Substring(i + 1).Trim();
                if (key == "AutoCopy") AutoCopy = value == "1";
                else if (key == "AutoSave") AutoSave = value == "1";
                else if (key == "ShowPreview") ShowPreview = value == "1";
                else if (key == "SaveDir" && value.Length > 0) SaveDir = value;
            }
        }
        catch { }   // 설정을 못 읽으면 기본값으로
    }

    public static void Save()
    {
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(FilePath));
            File.WriteAllLines(FilePath, new string[]
            {
                "AutoCopy=" + (AutoCopy ? "1" : "0"),
                "AutoSave=" + (AutoSave ? "1" : "0"),
                "ShowPreview=" + (ShowPreview ? "1" : "0"),
                "SaveDir=" + SaveDir
            }, Encoding.UTF8);
        }
        catch { }
    }
}
