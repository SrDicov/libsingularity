namespace Singularity.Widgets {

    public enum GlassMaterial {
        LENS,
        FROSTED
    }

    /**
     * A container drawn as glass over the window content behind it, for
     * bars, cards and overlays that float over an app's content.
     *
     * With SIT on a GPU the content behind is refracted and the
     * `glass-native` class is set, so CSS only adds tint and rim light.
     * Otherwise the bin keeps a translucent CSS fill. The shape is the CSS border box, so
     * `border-radius` shapes the glass too.
     */
    public class GlassBin : Gtk.Widget {

        private Gtk.Widget? _child = null;
        private GlassMaterial _material = GlassMaterial.FROSTED;
        private ulong _tuning_handler = 0;

        public Gtk.Widget? child {
            get { return _child; }
            set {
                if (_child == value) return;
                if (_child != null) _child.unparent();
                _child = value;
                if (_child != null) _child.set_parent(this);
            }
        }

        public GlassMaterial material {
            get { return _material; }
            set {
                if (_material == value) return;
                _material = value;
                refresh();
            }
        }

        static construct {
            set_layout_manager_type(typeof(Gtk.BinLayout));
            set_css_name("glass");
        }

        public GlassBin(Gtk.Widget? child = null, GlassMaterial material = GlassMaterial.FROSTED) {
            Object(child: child, material: material);
        }

        construct {
            add_css_class("glass-bin");
            unowned GlassBin self = this;
            _tuning_handler = Singularity.Style.GlassTuning.get_default().changed.connect(() => self.refresh());
            realize.connect_after(refresh);
            refresh();
        }

        private void refresh() {
            var glass = _material == GlassMaterial.LENS
                ? Singularity.Style.Glass.lens()
                : Singularity.Style.Glass.frosted();
            if (glass.apply(this) && Singularity.Style.Glass.accelerated(this)) add_css_class("glass-native");
            else remove_css_class("glass-native");
            if (_material == GlassMaterial.LENS) add_css_class("lens");
            else remove_css_class("lens");
        }

        public override void dispose() {
            if (_tuning_handler != 0) Singularity.Style.GlassTuning.get_default().disconnect(_tuning_handler);
            _tuning_handler = 0;
            if (_child != null) {
                _child.unparent();
                _child = null;
            }
            base.dispose();
        }
    }
}
