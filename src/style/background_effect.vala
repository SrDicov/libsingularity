namespace Singularity.Style {

    public enum BackgroundEffectMode {
        DISABLED,
        GLASS,
        BLUR,
        LIQUID;

        public static BackgroundEffectMode from_token(string token) {
            switch (token) {
                case "glass": return GLASS;
                case "blur": return BLUR;
                case "liquid": return LIQUID;
                default: return DISABLED;
            }
        }

        public string to_token() {
            switch (this) {
                case GLASS: return "glass";
                case BLUR: return "blur";
                case LIQUID: return "liquid";
                default: return "disabled";
            }
        }
    }

    [CCode (cname = "singularity_surface_effect_set", cheader_filename = "wayland/surface_effect.h")]
    private extern void set_native_surface_effect(Gtk.Widget widget, uint32 mode,
                                                   int x, int y, int width, int height,
                                                   uint32 strength);

    [CCode (cname = "singularity_surface_effect_set_card", cheader_filename = "wayland/surface_effect.h")]
    private extern bool set_native_card_effect(Gtk.Widget window, Gtk.Widget bin,
        Gtk.Widget card, Gsk.Transform? transform, uint32 mode, uint32 strength,
        bool visible);

    [CCode (cname = "singularity_surface_effect_set_frame", cheader_filename = "wayland/surface_effect.h")]
    private extern bool set_native_frame_effect(Gtk.Widget window, Gtk.Widget frame,
        uint32 mode, uint32 strength);

    [CCode (cname = "singularity_surface_effect_set_shapes", cheader_filename = "wayland/surface_effect.h")]
    private extern bool set_native_shapes_effect(Gtk.Widget window,
        [CCode (array_length_type = "int")] Gtk.Widget[] shapes, uint32 mode, uint32 strength);

    public delegate Gtk.Widget[] EffectShapes();

    public class BackgroundEffect : Object {

        private static GLib.Settings? cached_settings;

        public static BackgroundEffectMode read(GLib.Settings? settings) {
            if (settings == null || !settings.settings_schema.has_key("background-effect")) {
                return BackgroundEffectMode.DISABLED;
            }
            return BackgroundEffectMode.from_token(settings.get_string("background-effect"));
        }

        public static int read_strength(GLib.Settings? settings = null) {
            var source = settings;
            if (source == null) {
                if (cached_settings == null) {
                    cached_settings = Singularity.Core.safe_settings(
                        Singularity.Runtime.desktop_settings_schema);
                }
                source = cached_settings;
            }
            if (source == null || !source.settings_schema.has_key("blur-strength")) {
                return 60;
            }
            return source.get_int("blur-strength").clamp(0, 100);
        }

        internal static void apply_card(Gtk.Widget window, Singularity.Animation.MotionBin bin,
                                        BackgroundEffectMode mode) {
            if (bin.child == null) return;
            set_native_card_effect(window, bin, bin.child, bin.uses_native_transform ? null : bin.get_visual_transform(),
                (uint32) mode, (uint32) Math.round(read_strength() * bin.opacity),
                bin.opacity > 0);
        }

        internal static void update_classes(Gtk.Widget widget, BackgroundEffectMode mode) {
            bool glass = mode == BackgroundEffectMode.GLASS || mode == BackgroundEffectMode.LIQUID;
            if (!glass) widget.remove_css_class("singularity-glass");
            if (mode != BackgroundEffectMode.LIQUID) widget.remove_css_class("singularity-liquid");
            if (mode != BackgroundEffectMode.BLUR) widget.remove_css_class("singularity-blur");
            if (mode == BackgroundEffectMode.LIQUID) widget.add_css_class("singularity-liquid");
            if (glass) {
                widget.add_css_class("singularity-glass");
            } else if (mode == BackgroundEffectMode.BLUR) {
                widget.add_css_class("singularity-blur");
            }
        }

        internal static void apply_frame(Gtk.Widget window, Gtk.Widget frame,
                                         BackgroundEffectMode mode) {
            update_classes(window, mode);
            if (!window.get_mapped()) return;
            if (set_native_frame_effect(window, frame, (uint32) mode, (uint32) read_strength())) return;
            Graphene.Rect bounds;
            if (frame.compute_bounds(window, out bounds)) {
                set_native_surface_effect(window, (uint32) mode,
                    (int) bounds.origin.x, (int) bounds.origin.y,
                    (int) bounds.size.width, (int) bounds.size.height, (uint32) read_strength());
            }
        }

        public static void apply_shapes(Gtk.Widget window, Gtk.Widget[] shapes,
                                        BackgroundEffectMode mode) {
            update_classes(window, mode);
            if (!window.get_mapped()) return;
            if (set_native_shapes_effect(window, shapes, (uint32) mode, (uint32) read_strength())) return;
            set_native_surface_effect(window, (uint32) mode, 0, 0, 0, 0, (uint32) read_strength());
        }

        public static void track(Gtk.Window window, owned EffectShapes shapes) {
            unowned Gtk.Widget target = window;
            var settings = Singularity.Core.safe_settings(Singularity.Runtime.desktop_settings_schema);
            var mode = read(settings);
            update_classes(target, mode);
            ulong settings_handler = 0;
            ulong paint_handler = 0;
            Gdk.FrameClock? clock = null;
            if (settings != null && settings.settings_schema.has_key("background-effect")) {
                settings_handler = settings.changed["background-effect"].connect(() => {
                    mode = read(settings);
                    apply_shapes(target, shapes(), mode);
                });
            }
            target.realize.connect(() => {
                clock = target.get_frame_clock();
                if (clock != null) {
                    paint_handler = clock.after_paint.connect(() => apply_shapes(target, shapes(), mode));
                }
            });
            target.unrealize.connect(() => {
                if (clock != null && paint_handler != 0) clock.disconnect(paint_handler);
                clock = null;
                paint_handler = 0;
            });
            target.destroy.connect(() => {
                if (settings != null && settings_handler != 0) settings.disconnect(settings_handler);
                settings_handler = 0;
            });
            target.map.connect_after(() => apply_shapes(target, shapes(), mode));
        }

        public static void apply(Gtk.Widget widget, BackgroundEffectMode mode,
                                 int x = 0, int y = 0, int width = 0, int height = 0) {
            update_classes(widget, mode);
            if (widget.get_mapped()) {
                set_native_surface_effect(widget, (uint32) mode,
                    x, y, width, height, (uint32) read_strength());
            }
        }
    }
}
