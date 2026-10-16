using GLib;

namespace Singularity {

    public class ResourceMonitor : Object {
        private uint _timer_id = 0;
        private uint _cooldown_id = 0;
        private bool _mem_alert_active = false;
        private bool _cpu_alert_active = false;

        private const int CHECK_INTERVAL_SEC = 5;
        private const int COOLDOWN_SEC = 120;

        private const double MEM_WARNING_PCT = 0.85;
        private const double MEM_CRITICAL_PCT = 0.95;
        private const double CPU_SPIKE_PCT = 90.0;
        private const int CPU_SPIKE_SAMPLES = 12;

        private int64 _prev_idle = 0;
        private int64 _prev_total = 0;

        public ResourceMonitor() {}

        public void start() {
            if (_timer_id != 0) return;
            _prev_idle = 0;
            _prev_total = 0;
            _timer_id = Timeout.add_seconds(CHECK_INTERVAL_SEC, check_resources);
            check_resources();
        }

        public void stop() {
            if (_timer_id != 0) {
                Source.remove(_timer_id);
                _timer_id = 0;
            }
        }

        private bool check_resources() {
            check_memory();
            check_cpu();
            return Source.CONTINUE;
        }

        private void check_memory() {
            int64 mem_total = 0;
            int64 mem_available = 0;
            var f = FileStream.open("/proc/meminfo", "r");
            if (f == null) return;
            string? line;
            while ((line = f.read_line()) != null) {
                if (line.has_prefix("MemTotal:")) {
                    mem_total = parse_kb(line);
                } else if (line.has_prefix("MemAvailable:")) {
                    mem_available = parse_kb(line);
                }
                if (mem_total > 0 && mem_available > 0) break;
            }
            if (mem_total == 0) return;
            double used_pct = 1.0 - (double)mem_available / (double)mem_total;
            if (used_pct >= MEM_CRITICAL_PCT && !_mem_alert_active) {
                _mem_alert_active = true;
                send_alert("Critical Memory Usage",
                    "Memory at %.0f%% used. Applications may become unstable.".printf(used_pct * 100),
                    "dialog-warning");
                start_mem_cooldown();
            } else if (used_pct >= MEM_WARNING_PCT && !_mem_alert_active) {
                _mem_alert_active = true;
                send_alert("High Memory Usage",
                    "Memory at %.0f%% used. Consider closing unused applications.".printf(used_pct * 100),
                    "dialog-information");
                start_mem_cooldown();
            }
        }

        private void check_cpu() {
            var f = FileStream.open("/proc/stat", "r");
            if (f == null) return;
            string? line = f.read_line();
            if (line == null || !line.has_prefix("cpu ")) return;
            int64[] vals = {};
            foreach (var p in line.split(" ")) {
                if (p == "" || p == "cpu") continue;
                vals += int64.parse(p);
            }
            if (vals.length < 5) return;
            int64 busy = vals[0] + vals[1] + vals[2];
            for (int i = 5; i < vals.length && i < 8; i++) busy += vals[i];
            int64 idle = vals[3];
            if (_prev_total == 0) {
                _prev_idle = idle;
                _prev_total = busy;
                return;
            }
            int64 d_busy = busy - _prev_total;
            int64 d_idle = idle - _prev_idle;
            _prev_idle = idle;
            _prev_total = busy;
            if (d_busy < 0 || d_idle < 0 || d_busy + d_idle <= 0) {
                _cpu_spike_streak = 0;
                return;
            }
            double cpu_pct = ((double) d_busy / (double) (d_busy + d_idle)) * 100.0;

            if (cpu_pct >= CPU_SPIKE_PCT) _cpu_spike_streak++;
            else _cpu_spike_streak = 0;

            if (_cpu_spike_streak >= CPU_SPIKE_SAMPLES && !_cpu_alert_active) {
                _cpu_alert_active = true;
                start_cpu_cooldown();
                var before = process_times();
                Timeout.add_seconds(2, () => {
                    if (_cpu_spike_streak < CPU_SPIKE_SAMPLES) {
                        _cpu_alert_active = false;
                        return Source.REMOVE;
                    }
                    string name;
                    double share = top_process(before, process_times(), 2.0, out name);
                    if (name != "") {
                        send_alert(_("High CPU Usage"),
                            _("%s has been using %.0f%% of a processor core for over a minute.").printf(name, share),
                            "dialog-information");
                    } else {
                        send_alert(_("High CPU Usage"),
                            _("The processor has been busy for over a minute."),
                            "dialog-information");
                    }
                    return Source.REMOVE;
                });
            }
        }

        private static HashTable<string, int64?> process_times() {
            var times = new HashTable<string, int64?>(str_hash, str_equal);
            Dir dir;
            try {
                dir = Dir.open("/proc");
            } catch (FileError e) {
                return times;
            }
            string? entry;
            while ((entry = dir.read_name()) != null) {
                if (entry[0] < '0' || entry[0] > '9') continue;
                string stat;
                try {
                    if (!FileUtils.get_contents("/proc/%s/stat".printf(entry), out stat)) continue;
                } catch (FileError e) {
                    continue;
                }
                int open = stat.index_of_char('(');
                int close = stat.last_index_of_char(')');
                if (open < 0 || close < open) continue;
                string[] fields = stat.substring(close + 2).split(" ");
                if (fields.length < 13) continue;
                string name = stat.substring(open + 1, close - open - 1);
                times["%s\t%s".printf(entry, name)] = int64.parse(fields[11]) + int64.parse(fields[12]);
            }
            return times;
        }

        private static double top_process(HashTable<string, int64?> before, HashTable<string, int64?> after,
                                          double seconds, out string name) {
            string best_key = "";
            int64 best = 0;
            var iter = HashTableIter<string, int64?>(after);
            unowned string key;
            int64? value;
            while (iter.next(out key, out value)) {
                int64? old = before[key];
                if (old == null || value == null) continue;
                int64 delta = value - old;
                if (delta > best) {
                    best = delta;
                    best_key = key;
                }
            }
            name = "";
            if (best_key != "") {
                string[] parts = best_key.split("\t", 2);
                if (parts.length > 1) name = parts[1].make_valid();
            }
            long ticks = Posix.sysconf(Posix._SC_CLK_TCK);
            if (ticks <= 0) ticks = 100;
            return best * 100.0 / (ticks * seconds);
        }
        private int _cpu_spike_streak = 0;

        public signal void alert(string summary, string body, string icon);

        private void send_alert(string summary, string body, string icon) {
            alert(summary, body, icon);
        }

        private void start_mem_cooldown() {
            if (_cooldown_id != 0) Source.remove(_cooldown_id);
            _cooldown_id = Timeout.add_seconds(COOLDOWN_SEC, () => {
                _cooldown_id = 0;
                _mem_alert_active = false;
                return Source.REMOVE;
            });
        }

        private void start_cpu_cooldown() {
            if (_cpu_cooldown_id != 0) Source.remove(_cpu_cooldown_id);
            _cpu_cooldown_id = Timeout.add_seconds(COOLDOWN_SEC, () => {
                _cpu_cooldown_id = 0;
                _cpu_alert_active = false;
                return Source.REMOVE;
            });
        }

        private uint _cpu_cooldown_id = 0;

        private static int64 parse_kb(string line) {
            string[] parts = line.split(" ", 0);
            for (int i = 1; i < parts.length; i++) {
                if (parts[i].length > 0) return int64.parse(parts[i]);
            }
            return 0;
        }
    }
}