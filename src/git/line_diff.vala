namespace Singularity.Git {

    public enum LineChangeKind {
        ADDED,
        MODIFIED,
        DELETED
    }

    public class LineChange : Object {
        public LineChangeKind kind;
        public int start;
        public int count;
        public int old_start;
        public string[] old_lines;
    }

    private class DiffRow {
        public int[] v;
    }

    public class LineDiff : Object {

        public static string[] split_lines(string text) {
            var lines = text.split("\n");
            if (lines.length > 0 && lines[lines.length - 1] == "") lines = lines[0:lines.length - 1];
            return lines;
        }

        public static LineChange[] compare(string old_text, string new_text) {
            var a = split_lines(old_text);
            var b = split_lines(new_text);
            int n = a.length;
            int m = b.length;
            int prefix = 0;
            while (prefix < n && prefix < m && a[prefix] == b[prefix]) prefix++;
            int suffix = 0;
            while (suffix < n - prefix && suffix < m - prefix && a[n - 1 - suffix] == b[m - 1 - suffix]) suffix++;
            var edits = myers(a[prefix:n - suffix], b[prefix:m - suffix]);
            LineChange[] result = {};
            int i = 0;
            int j = 0;
            int k = 0;
            while (k < edits.length) {
                if (edits[k] == 0) {
                    i++;
                    j++;
                    k++;
                    continue;
                }
                int del = 0;
                int add = 0;
                int old_at = i;
                int new_at = j;
                while (k < edits.length && edits[k] != 0) {
                    if (edits[k] < 0) {
                        del++;
                        i++;
                    } else {
                        add++;
                        j++;
                    }
                    k++;
                }
                var c = new LineChange();
                c.start = prefix + new_at;
                c.old_start = prefix + old_at;
                string[] removed = {};
                for (int x = 0; x < del; x++) removed += a[prefix + old_at + x];
                c.old_lines = removed;
                if (del > 0 && add > 0) {
                    c.kind = LineChangeKind.MODIFIED;
                    c.count = add;
                } else if (add > 0) {
                    c.kind = LineChangeKind.ADDED;
                    c.count = add;
                } else {
                    c.kind = LineChangeKind.DELETED;
                    c.count = 0;
                }
                result += c;
            }
            return result;
        }

        private static int[] myers(string[] a, string[] b) {
            int n = a.length;
            int m = b.length;
            int max = n + m;
            if (max == 0) return new int[0];
            if (n * (long) m > 4000000) {
                int[] all = {};
                for (int x = 0; x < n; x++) all += -1;
                for (int x = 0; x < m; x++) all += 1;
                return all;
            }
            int offset = max;
            var v = new int[2 * max + 2];
            var trace = new GenericArray<DiffRow>();
            bool done = false;
            for (int d = 0; d <= max && !done; d++) {
                if (d > 3000) {
                    int[] all = {};
                    for (int x = 0; x < n; x++) all += -1;
                    for (int x = 0; x < m; x++) all += 1;
                    return all;
                }
                var row = new DiffRow();
                row.v = v.copy();
                trace.add(row);
                for (int k = -d; k <= d; k += 2) {
                    int x;
                    if (k == -d || (k != d && v[offset + k - 1] < v[offset + k + 1])) x = v[offset + k + 1];
                    else x = v[offset + k - 1] + 1;
                    int y = x - k;
                    while (x < n && y < m && a[x] == b[y]) {
                        x++;
                        y++;
                    }
                    v[offset + k] = x;
                    if (x >= n && y >= m) {
                        done = true;
                        break;
                    }
                }
            }
            int[] ops = {};
            int x = n;
            int y = m;
            for (int d = (int) trace.length - 1; d >= 0 && (x > 0 || y > 0); d--) {
                var vv = trace[d].v;
                int k = x - y;
                int prev_k;
                if (k == -d || (k != d && vv[offset + k - 1] < vv[offset + k + 1])) prev_k = k + 1;
                else prev_k = k - 1;
                int prev_x = vv[offset + prev_k];
                int prev_y = prev_x - prev_k;
                while (x > prev_x && y > prev_y) {
                    ops += 0;
                    x--;
                    y--;
                }
                if (d > 0) {
                    if (x == prev_x) ops += 1;
                    else ops += -1;
                }
                x = prev_x;
                y = prev_y;
            }
            int[] fwd = new int[ops.length];
            for (int z = 0; z < ops.length; z++) fwd[z] = ops[ops.length - 1 - z];
            return fwd;
        }
    }
}
