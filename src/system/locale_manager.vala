using GLib;

namespace Singularity {

    [DBus (name = "org.freedesktop.locale1")]
    public interface Locale1 : Object {
        public abstract string[] locale { owned get; }
        public abstract string x11_layout { owned get; }
        public abstract string x11_model { owned get; }
        public abstract string x11_variant { owned get; }
        public abstract string x11_options { owned get; }
        public abstract string vconsole_keymap { owned get; }
        public abstract string vconsole_keymap_toggle { owned get; }
        public abstract void set_locale(string[] locale, bool interactive) throws Error;
        public abstract void set_vconsole_keyboard(string keymap, string keymap_toggle, bool convert, bool interactive) throws Error;
        public abstract void set_x11_keyboard(string layout, string model, string variant, string options, bool convert, bool interactive) throws Error;
    }
    public class LocaleManager : Object {
        private Locale1? proxy;
        // True when locale1 is absent (Void/runit): state lives in
        // /etc/locale.conf plus ~/.config/locale.conf and is applied by the
        // session launcher at login.
        private bool use_local_fallback = false;
        public string[] current_locale { get; private set; default = {}; }
        public signal void state_changed();

        public LocaleManager() {
            init_async.begin();
        }

        private async void init_async() {
            try {
                proxy = yield Bus.get_proxy(BusType.SYSTEM, "org.freedesktop.locale1", "/org/freedesktop/locale1");
                message("LocaleManager: Connected to org.freedesktop.locale1");
                proxy.notify["locale"].connect(() => {
                    update_properties();
                    state_changed();
                });
                update_properties();
            } catch (Error e) {
                use_local_fallback = true;
                read_local();
                state_changed();
                message("LocaleManager: no locale1, using locale.conf (%s)", e.message);
            }
        }

        private static string[] locale_files() {
            string[] paths = { "/etc/locale.conf" };
            paths += Path.build_filename(Environment.get_user_config_dir(), "locale.conf");
            return paths;
        }

        private static bool locale_key(string key) {
            return key == "LANG" || key == "LANGUAGE" || key.has_prefix("LC_");
        }

        private static string unquote(string value) {
            string v = value.strip();
            if (v.length >= 2 && v.has_prefix("\"") && v.has_suffix("\""))
                v = v.substring(1, v.length - 2);
            return v;
        }

        private void read_local() {
            var values = new HashTable<string, string>(str_hash, str_equal);
            foreach (string path in locale_files()) {
                string data;
                try {
                    if (!FileUtils.get_contents(path, out data)) continue;
                } catch (Error e) {
                    continue;
                }
                foreach (string raw in data.split("\n")) {
                    string line = raw.strip();
                    if (line == "" || line.has_prefix("#")) continue;
                    int eq = line.index_of("=");
                    if (eq <= 0) continue;
                    string key = line.substring(0, eq).strip();
                    if (!locale_key(key)) continue;
                    values[key] = unquote(line.substring(eq + 1));
                }
            }
            var list = new Gee.ArrayList<string>();
            string[] order = {
                "LANG", "LANGUAGE", "LC_CTYPE", "LC_NUMERIC", "LC_TIME",
                "LC_COLLATE", "LC_MONETARY", "LC_MESSAGES", "LC_PAPER",
                "LC_NAME", "LC_ADDRESS", "LC_TELEPHONE", "LC_MEASUREMENT",
                "LC_IDENTIFICATION"
            };
            foreach (string key in order) {
                string? value = values.lookup(key);
                if (value != null) list.add(key + "=" + value);
            }
            current_locale = list.to_array();
        }

        private void write_local() {
            var sb = new StringBuilder();
            foreach (string entry in current_locale) sb.append(entry).append_c('\n');
            string path = Path.build_filename(Environment.get_user_config_dir(), "locale.conf");
            try {
                DirUtils.create_with_parents(Path.get_dirname(path), 0700);
                FileUtils.set_contents(path, sb.str);
            } catch (Error e) {
                warning("LocaleManager: cannot write %s: %s", path, e.message);
            }
        }

        private void update_properties() {
            if (proxy == null) return;
            this.current_locale = proxy.locale;
            state_changed();
        }

        private string[] merged_locale(string[] locale_settings) {
            var merged = new Gee.ArrayList<string>();
            foreach (string s in locale_settings) merged.add(s);
            foreach (string current in current_locale) {
                string key = current.split("=", 2)[0];
                bool replaced = false;
                foreach (string s in locale_settings) {
                    if (s.split("=", 2)[0] == key) replaced = true;
                }
                if (!replaced) merged.add(current);
            }
            return merged.to_array();
        }

        // Void ships locale sources but nothing compiled; compile the chosen
        // locale through the distro tool (needs glibc-locales). Best effort:
        // the polkit prompt is shown by pkexec and the result arrives later.
        private void request_generation(string value) {
            int dot = value.index_of(".");
            if (dot <= 0) return;
            string lang = value.substring(0, dot);
            string charset = value.substring(dot + 1).down().replace("-", "");
            if (charset != "utf8") return;
            if (!Regex.match_simple("^[a-z]{2,3}(_[A-Z]{2})?(@[a-z]+)?$", lang)) return;
            if (!FileUtils.test("/etc/default/libc-locales", FileTest.IS_REGULAR)) return;
            if (!FileUtils.test(Path.build_filename("/usr/share/i18n/locales", lang), FileTest.IS_REGULAR)) return;
            if (Environment.find_program_in_path("xbps-reconfigure") == null) return;
            if (Environment.find_program_in_path("pkexec") == null) return;
            string script = "grep -qxF \"$1 UTF-8\" /etc/default/libc-locales || echo \"$1 UTF-8\" >> /etc/default/libc-locales; xbps-reconfigure -f glibc-locales";
            try {
                new Subprocess.newv({ "pkexec", "sh", "-c", script, "_", lang }, SubprocessFlags.NONE);
            } catch (Error e) {
                warning("LocaleManager: cannot generate %s: %s", lang, e.message);
            }
        }

        public void update_locale(string[] locale_settings) {
            if (proxy == null) {
                if (!use_local_fallback) return;
                current_locale = merged_locale(locale_settings);
                write_local();
                var seen = new HashTable<string, string>(str_hash, str_equal);
                foreach (string s in locale_settings) {
                    int eq = s.index_of("=");
                    if (eq <= 0) continue;
                    string value = s.substring(eq + 1).strip();
                    if (value == "" || seen.contains(value)) continue;
                    seen[value] = value;
                    request_generation(value);
                }
                state_changed();
                return;
            }
            try {
                proxy.set_locale(merged_locale(locale_settings), true);
            } catch (Error e) {
                warning("Failed to set locale: %s", e.message);
            }
        }

        private List<string>? locale_sources() {
            string root = "/usr/share/i18n/locales";
            Dir dir;
            try {
                dir = Dir.open(root);
            } catch (Error e) {
                return null;
            }
            var list = new List<string>();
            string? name;
            while ((name = dir.read_name()) != null) {
                if (!Regex.match_simple("^[a-z]{2,3}(_[A-Z]{2})?(@[a-z]+)?$", name)) continue;
                if (!FileUtils.test(Path.build_filename(root, name), FileTest.IS_REGULAR)) continue;
                list.append(name + ".UTF-8");
            }
            return list;
        }

        public List<string> get_available_locales() {
            var list = new List<string>();
            var supported = File.new_for_path("/usr/share/i18n/SUPPORTED");
            if (!supported.query_exists()) {
                var sources = locale_sources();
                if (sources != null) return sources;
                return installed_locales();
            }
            try {
                var dis = new DataInputStream(supported.read());
                string? line;
                while ((line = dis.read_line(null)) != null) {
                    string locale = line.strip().split(" ")[0];
                    if (locale != "") {
                        list.append(locale);
                    }
                }
            } catch (Error e) {
                warning("Failed to read supported locales: %s", e.message);
            }
            return list;
        }

        private List<string> installed_locales() {
            var list = new List<string>();
            string output;
            try {
                Process.spawn_command_line_sync("locale -a", out output, null, null);
            } catch (SpawnError e) {
                warning("Failed to list installed locales: %s", e.message);
                return list;
            }
            foreach (string line in output.split("\n")) {
                string name = line.strip();
                if (name == "" || name == "C" || name == "POSIX" || name.has_prefix("C.")) continue;
                string[] parts = name.split(".", 2);
                if (parts.length == 2 && parts[1].down().replace("-", "") == "utf8") name = parts[0] + ".UTF-8";
                bool seen = false;
                foreach (string l in list) {
                    if (l == name) seen = true;
                }
                if (!seen) list.append(name);
            }
            return list;
        }

        public string get_lang_value() {
            foreach (string s in current_locale) {
                if (s.has_prefix("LANG=")) {
                    return s.substring(5);
                }
            }
            return "";
        }

        public string get_formats_value() {
            foreach (string s in current_locale) {
                if (s.has_prefix("LC_TIME=")) {
                    return s.substring(8);
                }
            }
            return get_lang_value();
        }
    }
}
