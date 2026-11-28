// 스크롤 캡처 이어 붙이기.
// 같은 영역을 조금씩 스크롤하며 찍은 화면들을 받아, 앞 화면과 겹치는 위치를 찾아 한 장으로 잇는다.
// 화면 처리와 무관한 순수 계산이라 test/StitchTest.cs 로 따로 검사한다.
using System;

sealed class Stitcher
{
    public enum Result
    {
        Added,     // 새 부분을 이어 붙였다
        NoChange,  // 앞 화면과 같다 (끝까지 스크롤됨)
        NoMatch    // 겹치는 위치를 찾지 못했다
    }

    readonly int w, h;
    readonly int hashW;   // 줄 비교에 쓰는 너비. 오른쪽 스크롤 막대 부분은 뺀다
    int[] canvas;
    int rows;             // 지금까지 이어 붙인 높이
    int pos;              // 마지막 화면의 맨 윗줄이 놓인 위치
    long[] prevHash;
    readonly int maxRows;

    public Stitcher(int width, int height, int[] first, int maxRows)
    {
        w = width;
        h = height;
        this.maxRows = Math.Max(maxRows, height);
        int margin = Math.Min(32, w / 6);
        hashW = Math.Max(1, w - margin);
        canvas = new int[w * h * 2];
        Array.Copy(first, 0, canvas, 0, w * h);
        rows = h;
        bool[] unused;
        prevHash = HashRows(first, out unused);
    }

    public int Width { get { return w; } }
    public int Rows { get { return rows; } }
    public int[] Canvas { get { return canvas; } }
    public bool Full { get { return rows >= maxRows; } }

    // 줄마다 해시를 만들고, 한 가지 색으로만 된 줄(빈 줄)을 표시한다
    long[] HashRows(int[] px, out bool[] uniform)
    {
        long[] hash = new long[h];
        uniform = new bool[h];
        for (int y = 0; y < h; y++)
        {
            int o = y * w;
            int first = px[o];
            bool same = true;
            long v = 1469598103934665603L;
            for (int x = 0; x < hashW; x++)
            {
                int p = px[o + x];
                if (p != first) same = false;
                v = unchecked((v ^ p) * 1099511628211L);
            }
            hash[y] = v;
            uniform[y] = same;
        }
        return hash;
    }

    // 새 화면을 넣는다. expect 는 예상 이동량(모르면 0 이하), offset 은 실제로 찾은 이동량
    public Result Add(int[] frame, int expect, out int offset)
    {
        offset = 0;
        bool[] uniform;
        long[] cur = HashRows(frame, out uniform);

        int same = 0;
        for (int y = 0; y < h; y++) if (cur[y] == prevHash[y]) same++;
        if (same == h) return Result.NoChange;

        // 위·아래에 그대로인 줄 수 (고정된 머리글·바닥글)
        int top = 0;
        while (top < h && cur[top] == prevHash[top]) top++;
        int bottom = 0;
        while (bottom < h - top && cur[h - 1 - bottom] == prevHash[h - 1 - bottom]) bottom++;

        int d = FindOffset(cur, uniform, top, h - bottom, expect);
        if (d <= 0) return same * 10 >= h * 9 ? Result.NoChange : Result.NoMatch;

        pos += d;
        int newRows = Math.Min(pos + h, maxRows);
        if (newRows * w > canvas.Length)
        {
            int[] bigger = new int[Math.Max(canvas.Length * 2, newRows * w)];
            Array.Copy(canvas, 0, bigger, 0, rows * w);
            canvas = bigger;
        }
        // 새로 드러난 띠와 그 아래(바닥글)만 덮어쓴다. 위쪽 고정 머리글은 건드리지 않는다
        int from = h - bottom - d;
        for (int y = from; y < h; y++)
        {
            int row = pos + y;
            if (row >= newRows) break;
            Array.Copy(frame, y * w, canvas, row * w, w);
        }
        rows = Math.Max(rows, newRows);
        prevHash = cur;
        offset = d;
        return Result.Added;
    }

    // 앞 화면의 [lo+d, hi) 와 새 화면의 [lo, hi-d) 가 가장 잘 맞는 d 를 찾는다
    int FindOffset(long[] cur, bool[] uniform, int lo, int hi, int expect)
    {
        int zone = hi - lo;
        if (zone < 24) return -1;
        int minOverlap = Math.Max(12, zone / 8);
        int maxD = zone - minOverlap;
        double[] score = new double[maxD + 1];
        double best = 0;
        for (int d = 1; d <= maxD; d++)
        {
            int total = 0, match = 0;
            for (int y = lo; y < hi - d; y++)
            {
                if (uniform[y]) continue;   // 빈 줄은 어디에나 맞으므로 세지 않는다
                total++;
                if (cur[y] == prevHash[y + d]) match++;
            }
            if (total < 8) continue;
            score[d] = (double)match / total;
            if (score[d] > best) best = score[d];
        }
        if (best < 0.7) return -1;

        // 점수가 거의 같은 후보가 여럿이면(반복되는 내용) 예상 이동량에 가까운 것, 없으면 가장 작은 것
        int pick = -1;
        for (int d = 1; d <= maxD; d++)
        {
            if (score[d] < best - 0.01) continue;
            if (pick < 0) { pick = d; if (expect <= 0) break; continue; }
            if (Math.Abs(d - expect) < Math.Abs(pick - expect)) pick = d;
        }
        return pick;
    }
}
