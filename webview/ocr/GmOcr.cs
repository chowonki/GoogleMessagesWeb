// 이미지 글자 인식 보조 프로그램 (Windows 내장 OCR: Windows.Media.Ocr)
// 사용법: gm_ocr.exe <이미지 파일 경로>
// 결과를 표준 출력에 JSON 한 줄로 내보내고 끝난다. 인터넷으로 아무것도 보내지 않는다.
//   {"ok":true,"w":1080,"h":720,"lines":[{"words":[{"t":"글자","x":1,"y":2,"w":3,"h":4}]}]}
//   {"ok":false,"error":"..."}
using System;
using System.IO;
using System.Text;
using Windows.Graphics.Imaging;
using Windows.Media.Ocr;
using Windows.Storage;
using Windows.Storage.Streams;

static class GmOcr
{
    static OcrEngine engine;
    static StreamWriter output;

    static int Main(string[] args)
    {
        // 창 없는 프로그램이라 콘솔 설정 대신 표준 출력 스트림을 UTF-8 로 직접 감싼다
        output = new StreamWriter(Console.OpenStandardOutput(), new UTF8Encoding(false));
        output.AutoFlush = true;
        if (args.Length != 1)
        {
            output.WriteLine(Error("usage: gm_ocr.exe <image file>"));
            return 2;
        }
        try
        {
            // 사용자 언어(한국어 등)로 만들고, 안 되면 설치된 아무 언어로
            engine = OcrEngine.TryCreateFromUserProfileLanguages();
            if (engine == null)
            {
                foreach (Windows.Globalization.Language lang in OcrEngine.AvailableRecognizerLanguages)
                {
                    engine = OcrEngine.TryCreateFromLanguage(lang);
                    if (engine != null) break;
                }
            }
            if (engine == null)
            {
                output.WriteLine(Error("Windows 에 OCR 언어 팩이 없습니다."));
                return 1;
            }
            output.WriteLine(Recognize(args[0]));
            return 0;
        }
        catch (Exception e)
        {
            output.WriteLine(Error((e.InnerException ?? e).Message));
            return 1;
        }
    }

    static string Recognize(string path)
    {
        StorageFile file = StorageFile.GetFileFromPathAsync(Path.GetFullPath(path)).AsTask().Result;
        using (IRandomAccessStream stream = file.OpenAsync(FileAccessMode.Read).AsTask().Result)
        {
            BitmapDecoder decoder = BitmapDecoder.CreateAsync(stream).AsTask().Result;
            if (decoder.PixelWidth > OcrEngine.MaxImageDimension || decoder.PixelHeight > OcrEngine.MaxImageDimension)
            {
                return Error("이미지가 너무 큽니다.");
            }
            using (SoftwareBitmap bitmap = decoder.GetSoftwareBitmapAsync(
                BitmapPixelFormat.Bgra8, BitmapAlphaMode.Premultiplied).AsTask().Result)
            {
                OcrResult ocr = engine.RecognizeAsync(bitmap).AsTask().Result;
                StringBuilder sb = new StringBuilder();
                sb.Append("{\"ok\":true,\"w\":").Append(decoder.PixelWidth)
                  .Append(",\"h\":").Append(decoder.PixelHeight).Append(",\"lines\":[");
                bool firstLine = true;
                foreach (OcrLine l in ocr.Lines)
                {
                    if (!firstLine) sb.Append(',');
                    firstLine = false;
                    sb.Append("{\"words\":[");
                    bool firstWord = true;
                    foreach (OcrWord w in l.Words)
                    {
                        if (!firstWord) sb.Append(',');
                        firstWord = false;
                        Windows.Foundation.Rect r = w.BoundingRect;
                        sb.Append("{\"t\":\"").Append(Escape(w.Text)).Append("\",\"x\":").Append(Num(r.X))
                          .Append(",\"y\":").Append(Num(r.Y)).Append(",\"w\":").Append(Num(r.Width))
                          .Append(",\"h\":").Append(Num(r.Height)).Append('}');
                    }
                    sb.Append("]}");
                }
                sb.Append("]}");
                return sb.ToString();
            }
        }
    }

    static string Num(double v)
    {
        return Math.Round(v, 1).ToString(System.Globalization.CultureInfo.InvariantCulture);
    }

    static string Error(string message)
    {
        return "{\"ok\":false,\"error\":\"" + Escape(message) + "\"}";
    }

    static string Escape(string s)
    {
        StringBuilder sb = new StringBuilder(s.Length + 8);
        foreach (char c in s)
        {
            if (c == '"' || c == '\\') sb.Append('\\').Append(c);
            else if (c < 0x20) sb.Append("\\u").Append(((int)c).ToString("x4"));
            else sb.Append(c);
        }
        return sb.ToString();
    }
}
