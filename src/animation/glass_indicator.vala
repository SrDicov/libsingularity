namespace Singularity.Animation {

    [CCode (cname = "singularity_widget_get_border_box", cheader_filename = "wayland/surface_effect.h")]
    private extern bool get_indicator_border_box(Gtk.Widget widget, out Gsk.RoundedRect box);

    /**
     * Selection indicator of a switcher that travels as a glass lens.
     *
     * When the current option changes the indicator lifts off the old
     * option, slides to the new one on a spring, stretches with its speed
     * and magnifies the labels it passes over, then lands and hands back to
     * the CSS highlight of the current option. The host adds
     * {@link MOVING_CLASS} handling in CSS to hide that highlight while the
     * lens is up, and calls {@link snapshot} after drawing its children.
     */
    public class GlassIndicator : Object {

        public const string MOVING_CLASS = "glass-indicator-moving";
        public const double STRETCH = 0.00045;
        public const double MAX_STRETCH = 0.35;
        public const double LIFT = 3.0;

        public unowned Gtk.Widget host { get; construct; }

        public Gdk.RGBA tint { get; set; }

        private SpringAnimation? _x_spring = null;
        private SpringAnimation? _width_spring = null;
        private SpringAnimation? _lift_spring = null;
        private Singularity.Style.Glass _glass;
        private Gtk.Widget? _target = null;
        private double _x = 0.0;
        private double _y = 0.0;
        private double _width = 0.0;
        private double _height = 0.0;
        private double _radius = 0.0;
        private double _lift = 0.0;
        private bool _placed = false;
        private ulong _tuning_handler = 0;

        public GlassIndicator(Gtk.Widget host) {
            Object(host: host);
        }

        construct {
            tint = { 1.0f, 1.0f, 1.0f, 0.12f };
            _glass = Singularity.Style.Glass.lens();
            unowned GlassIndicator self = this;
            _tuning_handler = Singularity.Style.GlassTuning.get_default().changed.connect(() => {
                self._glass = Singularity.Style.Glass.lens();
                self.host.queue_draw();
            });
            host.destroy.connect(() => {
                if (_tuning_handler != 0) Singularity.Style.GlassTuning.get_default().disconnect(_tuning_handler);
                _tuning_handler = 0;
            });
            host.unmap.connect(() => {
                _placed = false;
                settle();
            });
        }

        private bool measure(Gtk.Widget option, out double x, out double y,
                             out double width, out double height, out double radius) {
            x = y = width = height = radius = 0.0;
            Graphene.Rect bounds;
            if (!option.compute_bounds(host, out bounds)) return false;
            if (bounds.size.width <= 0 || bounds.size.height <= 0) return false;
            x = bounds.origin.x;
            y = bounds.origin.y;
            width = bounds.size.width;
            height = bounds.size.height;
            Gsk.RoundedRect box;
            if (get_indicator_border_box(option, out box)) {
                radius = box.corner[0].width;
            } else {
                radius = height / 2.0;
            }
            return true;
        }

        public void move_to(Gtk.Widget? option) {
            if (option == _target) return;
            _target = option;
            if (option == null) {
                settle();
                return;
            }
            if (!_placed || !host.get_mapped() || Singularity.Motion.reduced()) {
                settle();
                return;
            }
            double x, y, width, height, radius;
            if (!measure(option, out x, out y, out width, out height, out radius)) return;
            _y = y;
            _height = height;
            _radius = radius;
            _x_spring = spring(_x_spring, _x, x, (value) => _x = value);
            _width_spring = spring(_width_spring, _width, width, (value) => _width = value);
            lift(1.0);
        }

        private void place_now() {
            if (_target == null) return;
            double x, y, width, height, radius;
            if (!measure(_target, out x, out y, out width, out height, out radius)) return;
            _x = x;
            _y = y;
            _width = width;
            _height = height;
            _radius = radius;
            _placed = true;
        }

        private SpringAnimation spring(SpringAnimation? existing, double from, double to,
                                       owned ValueSink sink) {
            if (existing != null && existing.state == AnimationState.PLAYING) {
                existing.retarget(to);
                return existing;
            }
            var animation = new SpringAnimation(host, from, to, Singularity.Motion.Spring.SNAPPY);
            animation.set_sink((value) => {
                sink(value);
                host.queue_draw();
            });
            animation.done.connect(on_landed);
            animation.play();
            return animation;
        }

        private void on_landed() {
            bool moving = (_x_spring != null && _x_spring.state == AnimationState.PLAYING)
                || (_width_spring != null && _width_spring.state == AnimationState.PLAYING);
            if (!moving) lift(0.0);
        }

        private void lift(double to) {
            if (to > 0.0) host.add_css_class(MOVING_CLASS);
            if (_lift_spring != null && _lift_spring.state == AnimationState.PLAYING) {
                _lift_spring.use_spring(to > 0.0 ? Singularity.Motion.Spring.SNAPPY : Singularity.Motion.Spring.BOUNCY);
                _lift_spring.retarget(to);
                return;
            }
            _lift_spring = new SpringAnimation(host, _lift, to,
                to > 0.0 ? Singularity.Motion.Spring.SNAPPY : Singularity.Motion.Spring.BOUNCY);
            var animation = _lift_spring;
            animation.set_sink((value) => {
                _lift = value;
                host.queue_draw();
            });
            animation.done.connect(() => {
                if (_lift_spring != animation) return;
                _lift = animation.value_to;
                if (_lift <= 0.0) host.remove_css_class(MOVING_CLASS);
                host.queue_draw();
            });
            animation.play();
        }

        private void settle() {
            _lift = 0.0;
            if (_lift_spring != null) _lift_spring.reset();
            if (_x_spring != null) _x_spring.reset();
            if (_width_spring != null) _width_spring.reset();
            host.remove_css_class(MOVING_CLASS);
            place_now();
            host.queue_draw();
        }

        public void snapshot(Gtk.Snapshot snapshot) {
            if (!_placed) place_now();
            if (_lift <= 0.001 || _width <= 0.0) return;
            double amount = _lift.clamp(0.0, 1.2);
            double speed = _x_spring != null && _x_spring.state == AnimationState.PLAYING ? _x_spring.velocity : 0.0;
            double stretch = (speed.abs() * STRETCH).clamp(0.0, MAX_STRETCH);
            double grow = LIFT * amount;
            double width = _width * (1.0 + stretch) + grow * 2.0;
            double height = (_height + grow * 2.0) * (1.0 - stretch * 0.25);
            double cx = _x + _width / 2.0;
            double cy = _y + _height / 2.0;
            var rect = Graphene.Rect() {
                origin = { (float) (cx - width / 2.0), (float) (cy - height / 2.0) },
                size = { (float) width, (float) height }
            };
            float radius = (float) double.min(_radius + grow, height / 2.0);
            var shape = Gsk.RoundedRect();
            shape.init_from_rect(rect, radius);
            double opacity = _lift.clamp(0.0, 1.0);
            var glass = _glass.copy();
            glass.opacity = opacity;
            bool drawn = Singularity.Style.Glass.accelerated(host) && glass.append(snapshot, shape);
            var fill = tint;
            fill.alpha = (float) (tint.alpha * (drawn ? 0.6 : 1.0) * opacity);
            snapshot.push_rounded_clip(shape);
            snapshot.append_color(fill, rect);
            snapshot.pop();
            if (!drawn) return;
            Gdk.RGBA light = { 1.0f, 1.0f, 1.0f, (float) (0.55 * opacity) };
            Gdk.RGBA shade = { 1.0f, 1.0f, 1.0f, (float) (0.18 * opacity) };
            snapshot.append_inset_shadow(shape, light, 0.0f, 1.0f, 0.0f, 1.0f);
            snapshot.append_inset_shadow(shape, shade, 0.0f, -1.0f, 0.0f, 2.0f);
        }
    }
}
