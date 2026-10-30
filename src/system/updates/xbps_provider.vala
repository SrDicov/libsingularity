using GLib;

namespace Singularity.Updates {

    /**
     * Updates provider for Void Linux's native package manager. PackageKit on
     * Void only ships the dummy/test backends, so without this the Updates
     * page has no working service at all.
     *
     * check() runs unprivileged `xbps-install -un` (reads the cached repo
     * index). download()/schedule() use pkexec so the polkit agent prompts.
     */
    public class XbpsProvider : Provider {
        public override string kind {
            get { return "xbps"; }
        }

        private static string? tool(string name) {
            return Environment.find_program_in_path(name);
        }

        private static string required(string name) throws Error {
            string? path = tool(name);
            if (path == null) throw new IOError.NOT_FOUND(_("%s is not installed").printf(name));
            return path;
        }

        public override async bool probe() {
            if (tool("xbps-install") == null || tool("xbps-query") == null) return false;
            name = _("Void Linux (XBPS)");
            description = _("Updated through xbps");
            current_version = HardwareInfo.os_name();
            can_download = true;
            can_schedule = true;
            can_unschedule = false;
            has_history = false;
            state = State.UNKNOWN;
            return true;
        }

        /* `foo-1.1_1 update x86_64 <repo> <n> <bytes>`; the first field is the
         * candidate pkgver, so split after the last hyphen. */
        public static Gee.List<Package> parse_updates(string output) {
            var result = new Gee.ArrayList<Package>();
            try {
                var re = new Regex("^\\S+\\s+update(\\s|$)");
                foreach (unowned string raw in output.split("\n")) {
                    string line = raw.strip();
                    if (line == "" || !re.match(line)) continue;
                    string pkgver = line.split(" ")[0];
                    int dash = pkgver.last_index_of("-");
                    if (dash <= 0 || dash + 1 >= pkgver.length) continue;
                    result.add(new Package(pkgver.substring(0, dash),
                                           pkgver.substring(dash + 1), "", false));
                }
            } catch (RegexError e) {
                warning("Updates: xbps parse failed: %s", e.message);
            }
            return result;
        }

        private async void run(string[] argv) throws Error {
            var launcher = new SubprocessLauncher(
                SubprocessFlags.STDOUT_PIPE | SubprocessFlags.STDERR_PIPE);
            var proc = launcher.spawnv(argv);
            string stdout_buf;
            string stderr_buf;
            yield proc.communicate_utf8_async(null, null, out stdout_buf, out stderr_buf);
            if (proc.get_successful()) return;
            string message = (stderr_buf ?? "").strip();
            if (message == "") message = (stdout_buf ?? "").strip();
            throw new IOError.FAILED(message != "" ? message : _("xbps command failed"));
        }

        private async string run_text(string[] argv) throws Error {
            var launcher = new SubprocessLauncher(
                SubprocessFlags.STDOUT_PIPE | SubprocessFlags.STDERR_PIPE);
            var proc = launcher.spawnv(argv);
            string stdout_buf;
            string stderr_buf;
            yield proc.communicate_utf8_async(null, null, out stdout_buf, out stderr_buf);
            if (!proc.get_successful()) {
                string message = (stderr_buf ?? "").strip();
                if (message == "") message = (stdout_buf ?? "").strip();
                throw new IOError.FAILED(message != "" ? message : _("xbps command failed"));
            }
            return stdout_buf ?? "";
        }

        public override async void check() throws Error {
            state = State.CHECKING;
            progress = -1;
            last_error = "";
            changed();
            try {
                string output = yield run_text({ required("xbps-install"), "-un" });
                var found = parse_updates(output);
                _packages.clear();
                _packages.add_all(found);
                last_check = get_real_time() / 1000000;
                available_version = "";
                state = found.size > 0 ? State.AVAILABLE : State.UP_TO_DATE;
                changed();
            } catch (Error e) {
                fail(e);
                throw e;
            }
        }

        public override async void download() throws Error {
            state = State.DOWNLOADING;
            progress = -1;
            last_error = "";
            changed();
            try {
                yield run({ "pkexec", required("xbps-install"), "-S", "-D", "-u", "-y" });
                progress = -1;
                state = State.READY;
                changed();
            } catch (Error e) {
                fail(e);
                throw e;
            }
        }

        public override async void schedule() throws Error {
            // xbps has no offline "install at next boot" mode: install now and
            // let the UI offer the reboot it already suggests after READY.
            state = State.DOWNLOADING;
            progress = -1;
            last_error = "";
            changed();
            try {
                yield run({ "pkexec", required("xbps-install"), "-u", "-y" });
                last_check = get_real_time() / 1000000;
                _packages.clear();
                progress = -1;
                state = State.SCHEDULED;
                changed();
            } catch (Error e) {
                fail(e);
                throw e;
            }
        }

        public override async void unschedule() throws Error {
            throw new IOError.NOT_SUPPORTED(_("xbps installs updates immediately"));
        }

        public override async Gee.List<HistoryEntry> history() throws Error {
            return new Gee.ArrayList<HistoryEntry>();
        }
    }
}
