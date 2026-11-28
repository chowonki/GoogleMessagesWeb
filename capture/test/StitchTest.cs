// Stitcher 검사. 가짜 긴 페이지를 조금씩 내려 찍은 화면들을 이어 붙여 원본과 같은지 본다.
// 빌드: csc /out:stitch_test.exe src\Stitcher.cs test\StitchTest.cs
using System;

static class StitchTest
{
    const int W = 300, H = 400;
    const int BarW = 16;   // 스크롤 막대 (화면마다 모양이 달라진다)

    static int[] MakePage(int rows, int seed)
    {
        Random rnd = new Random(seed);
        int[] page = new int[rows * W];
        for (int y = 0; y < rows; y++)
        {
            bool blank = rnd.Next(4) == 0;   // 빈 줄도 섞는다
            for (int x = 0; x < W; x++)
                page[y * W + x] = blank ? 0xFFFFFF : rnd.Next(0x1000000);
        }
        return page;
    }

    // 스크롤 위치 s 에서 보이는 화면. 위 header 줄·아래 footer 줄은 고정
    static int[] Frame(int[] page, int s, int header, int footer, int[] head, int[] foot)
    {
        int[] f = new int[W * H];
        for (int y = 0; y < H; y++)
        {
            int[] src; int sy;
            if (y < header) { src = head; sy = y; }
            else if (y >= H - footer) { src = foot; sy = y - (H - footer); }
            else { src = page; sy = s + y; }
            Array.Copy(src, sy * W, f, y * W, W);
            for (int x = W - BarW; x < W; x++) f[y * W + x] = (y + s) % 37 == 0 ? 0x333333 : 0xEEEEEE;
        }
        return f;
    }

    static bool Run(string name, int header, int footer, int[] steps)
    {
        int total = 0;
        foreach (int st in steps) total += st;
        int[] page = MakePage(total + H, 7);
        int[] head = MakePage(Math.Max(header, 1), 11);
        int[] foot = MakePage(Math.Max(footer, 1), 13);

        int s = 0;
        Stitcher st2 = new Stitcher(W, H, Frame(page, 0, header, footer, head, foot), 100000);
        foreach (int step in steps)
        {
            s += step;
            int off;
            Stitcher.Result r = st2.Add(Frame(page, s, header, footer, head, foot), 0, out off);
            if (r != Stitcher.Result.Added || off != step)
            {
                Console.WriteLine("FAIL {0}: step {1} -> {2} offset {3}", name, step, r, off);
                return false;
            }
        }
        // 같은 화면을 한 번 더 넣으면 끝으로 판단해야 한다
        int off2;
        if (st2.Add(Frame(page, s, header, footer, head, foot), 0, out off2) != Stitcher.Result.NoChange)
        {
            Console.WriteLine("FAIL {0}: end not detected", name);
            return false;
        }
        if (st2.Rows != s + H)
        {
            Console.WriteLine("FAIL {0}: rows {1}, expected {2}", name, st2.Rows, s + H);
            return false;
        }
        // 기대 결과: 머리글 + 본문 + 바닥글
        for (int y = 0; y < st2.Rows; y++)
        {
            int[] src; int sy;
            if (y < header) { src = head; sy = y; }
            else if (y >= st2.Rows - footer) { src = foot; sy = y - (st2.Rows - footer); }
            else { src = page; sy = y; }
            for (int x = 0; x < W - BarW; x++)
            {
                if (st2.Canvas[y * W + x] != src[sy * W + x])
                {
                    Console.WriteLine("FAIL {0}: pixel mismatch at row {1}", name, y);
                    return false;
                }
            }
        }
        Console.WriteLine("ok   {0}", name);
        return true;
    }

    static int Main()
    {
        bool ok = true;
        ok &= Run("plain", 0, 0, new int[] { 100, 100, 100, 37 });
        ok &= Run("header", 60, 0, new int[] { 120, 120, 120, 55 });
        ok &= Run("header+footer", 60, 40, new int[] { 90, 150, 150, 150, 12 });
        ok &= Run("small steps", 50, 30, new int[] { 3, 20, 20, 20, 20, 1 });
        ok &= Run("big steps", 30, 20, new int[] { 200, 200, 200, 180 });

        // 전혀 다른 화면은 못 찾음으로 나와야 한다
        int[] a = MakePage(H, 1), b = MakePage(H, 2);
        int off;
        Stitcher s = new Stitcher(W, H, a, 100000);
        if (s.Add(b, 0, out off) != Stitcher.Result.NoMatch) { Console.WriteLine("FAIL unrelated frames"); ok = false; }
        else Console.WriteLine("ok   unrelated frames");

        Console.WriteLine(ok ? "ALL PASSED" : "FAILED");
        return ok ? 0 : 1;
    }
}
