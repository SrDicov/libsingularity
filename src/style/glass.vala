namespace Singularity.Style {

    [CCode (cname = "singularity_glass_supported", cheader_filename = "wayland/surface_effect.h")]
    private extern bool native_glass_supported();

    [CCode (cname = "singularity_widget_glass_accelerated", cheader_filename = "wayland/surface_effect.h")]
    private extern bool native_glass_accelerated(Gtk.Widget widget);

    [CCode (cname = "singularity_widget_set_glass", cheader_filename = "wayland/surface_effect.h")]
    private extern bool set_native_widget_glass(Gtk.Widget widget, bool enabled, float blur,
        float refraction, float bezel, float zoom, float saturation, float opacity);

    [CCode (cname = "singularity_snapshot_append_glass", cheader_filename = "wayland/surface_effect.h")]
    private extern bool append_native_glass(Gtk.Snapshot snapshot, Gsk.RoundedRect shape, float blur,
        float refraction, float bezel, float zoom, float saturation, float opacity);

    /**
     * The desktop material tuning, shared by compositor glass and the glass
     * drawn inside windows. `changed` fires when the user moves a slider in
     * Desktop settings.
     */
    public class GlassTuning : Object {

        private static GlassTuning? instance = null;

        private GLib.Settings? _settings;

        public double vibrancy { get; private set; default = 0.5; }

        public double refraction { get; private set; default = 0.5; }

        public double highlight { get; private set; default = 0.5; }

        public BackgroundEffectMode mode { get; private set; default = BackgroundEffectMode.DISABLED; }

        public signal void changed();

        public static GlassTuning get_default() {
            if (instance == null) instance = new GlassTuning();
            return instance;
        }

        construct {
            _settings = Singularity.Core.safe_settings(Singularity.Runtime.desktop_settings_schema);
            read();
            if (_settings == null) return;
            _settings.changed.connect((key) => {
                switch (key) {
                    case "background-effect":
                    case "glass-vibrancy":
                    case "liquid-refraction":
                    case "liquid-highlight":
                        read();
                        changed();
                        break;
                }
            });
        }

        private double fraction(string key) {
            if (_settings == null || !_settings.settings_schema.has_key(key)) return 0.5;
            return _settings.get_int(key).clamp(0, 100) / 100.0;
        }

        private void read() {
            vibrancy = fraction("glass-vibrancy");
            refraction = fraction("liquid-refraction");
            highlight = fraction("liquid-highlight");
            mode = BackgroundEffect.read(_settings);
        }
    }

    /**
     * Glass drawn inside a window: whatever is already painted behind a
     * shape, seen through a lens that blurs, magnifies, saturates and bends
     * it at the rim. Tint and highlights stay in CSS, drawn on top.
     *
     * It needs SIT and a window that renders on a GPU. On any other GTK
     * `supported` is false; with Cairo or a software driver
     * {@link accelerated} is false. In both cases nothing is drawn and
     * widgets keep their CSS look.
     *
     * {@link lens} is clear and magnifying, for knobs and selection
     * indicators that travel over content. {@link frosted} is blurred, for
     * floating bars and cards. Both follow {@link GlassTuning}.
     */
    public class Glass : Object {

        private static int support = -1;

        public double blur { get; set; default = 0.0; }

        public double refraction { get; set; default = 6.0; }

        public double bezel { get; set; default = 8.0; }

        public double zoom { get; set; default = 1.0; }

        public double saturation { get; set; default = 1.0; }

        public double opacity { get; set; default = 1.0; }

        public static bool supported {
            get {
                if (support < 0) support = native_glass_supported() ? 1 : 0;
                return support == 1;
            }
        }

        public static bool accelerated(Gtk.Widget widget) {
            return supported && native_glass_accelerated(widget);
        }

        public static Glass lens() {
            var tuning = GlassTuning.get_default();
            return new Glass() {
                blur = 0.0,
                refraction = 1.5 + tuning.refraction * 4.0,
                bezel = 6.0,
                zoom = 1.06 + tuning.refraction * 0.12,
                saturation = 1.0 + tuning.vibrancy * 0.8
            };
        }

        public static Glass frosted() {
            var tuning = GlassTuning.get_default();
            return new Glass() {
                blur = 14.0,
                refraction = 2.0 + tuning.refraction * 8.0,
                bezel = 12.0,
                zoom = 1.0,
                saturation = 1.0 + tuning.vibrancy * 0.9
            };
        }

        public Glass copy() {
            return new Glass() {
                blur = blur,
                refraction = refraction,
                bezel = bezel,
                zoom = zoom,
                saturation = saturation,
                opacity = opacity
            };
        }

        public bool apply(Gtk.Widget widget) {
            if (!supported) return false;
            return set_native_widget_glass(widget, opacity > 0.0, (float) blur, (float) refraction,
                (float) bezel, (float) zoom, (float) saturation, (float) opacity);
        }

        public static void remove(Gtk.Widget widget) {
            if (!supported) return;
            set_native_widget_glass(widget, false, 0, 0, 0, 1, 1, 0);
        }

        public bool append(Gtk.Snapshot snapshot, Gsk.RoundedRect shape) {
            if (!supported || opacity <= 0.0) return false;
            return append_native_glass(snapshot, shape, (float) blur, (float) refraction,
                (float) bezel, (float) zoom, (float) saturation, (float) opacity);
        }
    }
}
