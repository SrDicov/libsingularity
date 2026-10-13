namespace Singularity.Animation {

    /**
     * Liquid motion for the knob of a `Gtk.Switch`.
     *
     * Pressing the switch turns the knob into a round glass lens that grows
     * past the track and magnifies it. The lens follows a drag, stretches
     * with its speed while it travels and settles back into a solid knob on
     * a bouncy spring once the switch is released and at rest. Without SIT
     * the knob keeps its CSS fill and only the motion is played.
     */
    public class SwitchMotion : Object {

        public const double LENS_SCALE = 1.45;
        public const double STRETCH = 0.025;
        public const double MAX_STRETCH = 0.28;

        private const string DATA_KEY = "singularity-switch-motion";
        private const string LENS_CLASS = "glass-lens";

        private Gtk.Widget? _slider = null;
        private ChildTransform? _transform = null;
        private SpringAnimation? _motion = null;
        private SpringAnimation? _lens_spring = null;
        private Singularity.Style.Glass _glass;
        private double _position = 0.0;
        private double _velocity = 0.0;
        private double _lens = 0.0;
        private double _drag_start = 0.0;
        private double _press_x = 0.0;
        private bool _pressed = false;
        private bool _dragging = false;
        private bool _traveling = false;
        private ulong _tuning_handler = 0;

        public unowned Gtk.Switch target { get; construct; }

        public double position {
            get { return _position; }
        }

        public double lens {
            get { return _lens; }
        }

        private SwitchMotion(Gtk.Switch target) {
            Object(target: target);
        }

        construct {
            _position = target.active ? 1.0 : 0.0;
            _glass = Singularity.Style.Glass.lens();
            target.notify["active"].connect(on_active);
            var events = new Gtk.EventControllerLegacy();
            events.propagation_phase = Gtk.PropagationPhase.CAPTURE;
            events.event.connect(on_event);
            target.add_controller(events);
            unowned SwitchMotion self = this;
            _tuning_handler = Singularity.Style.GlassTuning.get_default().changed.connect(() => {
                self._glass = Singularity.Style.Glass.lens();
                self.reshape();
            });
            target.destroy.connect(() => {
                if (_tuning_handler != 0) Singularity.Style.GlassTuning.get_default().disconnect(_tuning_handler);
                _tuning_handler = 0;
            });
        }

        public static SwitchMotion attach(Gtk.Switch target) {
            var existing = target.get_data<SwitchMotion>(DATA_KEY);
            if (existing != null) return existing;
            var motion = new SwitchMotion(target);
            target.set_data<SwitchMotion>(DATA_KEY, motion);
            return motion;
        }

        public static SwitchMotion? lookup(Gtk.Switch target) {
            return target.get_data<SwitchMotion>(DATA_KEY);
        }

        private Gtk.Widget? slider() {
            if (_slider != null && _slider.get_parent() == target) return _slider;
            for (var child = target.get_first_child(); child != null; child = child.get_next_sibling()) {
                if (child.get_css_name() == "slider" || child.get_type().name() == "GtkGizmo") {
                    _slider = child;
                    return child;
                }
            }
            return null;
        }

        private ChildTransform? transform() {
            if (_transform != null) return _transform;
            var knob = slider();
            if (knob == null) return null;
            _transform = ChildTransform.for_widget(knob, place);
            return _transform;
        }

        private void place(out int width, out int height, out double x, out double y) {
            int minimum, natural, minimum_baseline, natural_baseline;
            _slider.measure(Gtk.Orientation.HORIZONTAL, -1, out minimum, out natural,
                out minimum_baseline, out natural_baseline);
            width = minimum;
            height = target.get_height();
            x = _position.clamp(-0.1, 1.1) * (target.get_width() - width);
            y = 0.0;
            _transform.origin_x = 0.5;
            _transform.origin_y = 0.5;
        }

        private double travel() {
            var knob = slider();
            if (knob == null) return 1.0;
            int minimum, natural, minimum_baseline, natural_baseline;
            knob.measure(Gtk.Orientation.HORIZONTAL, -1, out minimum, out natural,
                out minimum_baseline, out natural_baseline);
            return double.max(1.0, target.get_width() - minimum);
        }

        private SpringAnimation motion() {
            if (_motion != null) return _motion;
            _motion = new SpringAnimation(target, _position, _position, Singularity.Motion.Spring.SNAPPY);
            _motion.set_sink((value) => {
                _position = value;
                _velocity = _motion.velocity;
                reshape();
            });
            _motion.done.connect(() => {
                _velocity = 0.0;
                _traveling = false;
                update_lens();
                reshape();
            });
            return _motion;
        }

        private void on_active() {
            double to = target.active ? 1.0 : 0.0;
            if (!target.get_mapped() || transform() == null) {
                _position = to;
                if (_motion != null) _motion.set_current(to);
                return;
            }
            if (_dragging) return;
            _traveling = true;
            update_lens();
            motion().retarget(to);
        }

        private bool on_event(Gdk.Event event) {
            double x = 0.0, y = 0.0;
            switch (event.get_event_type()) {
                case Gdk.EventType.BUTTON_PRESS:
                case Gdk.EventType.TOUCH_BEGIN:
                    if (_pressed || !event.get_position(out x, out y)) return false;
                    _press_x = x;
                    _drag_start = _position;
                    press(true);
                    break;
                case Gdk.EventType.MOTION_NOTIFY:
                case Gdk.EventType.TOUCH_UPDATE:
                    if (!_pressed || !event.get_position(out x, out y)) return false;
                    on_drag(x - _press_x);
                    break;
                case Gdk.EventType.BUTTON_RELEASE:
                case Gdk.EventType.TOUCH_END:
                case Gdk.EventType.TOUCH_CANCEL:
                    if (!_pressed) return false;
                    finish_drag();
                    press(false);
                    break;
                default:
                    break;
            }
            return false;
        }

        private void on_drag(double offset_x) {
            if (!_dragging && offset_x.abs() < 3.0) return;
            if (transform() == null) return;
            if (!_dragging) {
                _dragging = true;
                update_lens();
            }
            double raw = _drag_start + offset_x / travel();
            double over = raw < 0.0 ? raw : (raw > 1.0 ? raw - 1.0 : 0.0);
            var spring = motion();
            spring.track(raw.clamp(0.0, 1.0) + over * 0.3);
            _position = spring.value;
            _velocity = spring.velocity;
            reshape();
        }

        private void finish_drag() {
            if (!_dragging) return;
            Idle.add(() => {
                _dragging = false;
                _traveling = true;
                update_lens();
                motion().release(target.active ? 1.0 : 0.0);
                return Source.REMOVE;
            });
        }

        public void press(bool pressed) {
            if (_pressed == pressed) return;
            _pressed = pressed;
            update_lens();
        }

        private void update_lens() {
            var knob = transform();
            if (knob == null) return;
            double to = (_pressed || _dragging || _traveling) ? 1.0 : 0.0;
            if (Singularity.Motion.reduced()) {
                _lens = 0.0;
                reshape();
                return;
            }
            if (to > 0.0) knob.hold = true;
            if (_lens_spring == null) {
                _lens_spring = new SpringAnimation(target, _lens, to,
                    to > 0.0 ? Singularity.Motion.Spring.SNAPPY : Singularity.Motion.Spring.BOUNCY);
                _lens_spring.set_sink((value) => {
                    _lens = value;
                    reshape();
                });
                _lens_spring.done.connect(() => {
                    _lens = _lens_spring.value_to;
                    reshape();
                });
            }
            if (_lens_spring.value_to == to && _lens_spring.state == AnimationState.PLAYING) return;
            _lens_spring.use_spring(to > 0.0 ? Singularity.Motion.Spring.SNAPPY : Singularity.Motion.Spring.BOUNCY);
            _lens_spring.set_current(_lens);
            _lens_spring.retarget(to);
        }

        private void reshape() {
            var knob = transform();
            if (knob == null) return;
            var glass_on = Singularity.Style.Glass.supported && _lens > 0.02;
            if (glass_on) target.add_css_class(LENS_CLASS);
            else target.remove_css_class(LENS_CLASS);
            double grow = 1.0 + (LENS_SCALE - 1.0) * _lens;
            double stretch = Singularity.Motion.reduced() ? 0.0 : (_velocity.abs() * STRETCH).clamp(0.0, MAX_STRETCH);
            var glass = _glass.copy();
            glass.opacity = _lens.clamp(0.0, 1.0);
            glass.zoom = _glass.zoom / double.max(grow, 0.5);
            if (glass_on) glass.apply(_slider);
            else Singularity.Style.Glass.remove(_slider);
            knob.scale_x = grow * (1.0 + stretch);
            knob.scale_y = grow * (1.0 - stretch * 0.5);
            bool idle = _lens.abs() < 0.001 && !_pressed && !_dragging && !_traveling;
            knob.hold = !idle;
            target.queue_allocate();
        }
    }

    /**
     * Installs the automatic motion of every application: switches, page
     * stacks inside `Singularity.Widgets.Window` content and popovers.
     */
    public class WidgetMotion : Object {

        private static bool installed = false;

        public static void install() {
            if (installed) return;
            installed = true;
            typeof(Gtk.Switch).class_ref();
            typeof(Gtk.Stack).class_ref();
            typeof(Gtk.Popover).class_ref();
            uint map_signal = Signal.lookup("map", typeof(Gtk.Widget));
            Signal.add_emission_hook(map_signal, 0, (hint, values) => {
                var widget = values[0].get_object() as Gtk.Widget;
                if (widget is Gtk.Switch) {
                    SwitchMotion.attach((Gtk.Switch) widget);
                } else if (widget is Gtk.Stack) {
                    attach_stack((Gtk.Stack) widget);
                } else if (widget is Gtk.Popover) {
                    PopoverMotion.enter((Gtk.Popover) widget);
                }
                return true;
            });
        }

        private static void attach_stack(Gtk.Stack stack) {
            if (PageTransition.lookup(stack) != null || PageTransition.is_excluded(stack)) return;
            if (!PageTransition.is_page_like(stack.transition_type)) return;
            var root = stack.get_root() as Singularity.Widgets.Window;
            if (root == null || stack.get_native() != root || !stack.is_ancestor(root.content_area)) return;
            PageTransition.attach(stack);
        }
    }

    /**
     * Popover entrance: fades in over MEDIUM while the content grows from
     * 0.96 at the side the popover points from.
     */
    public class PopoverMotion : Object {

        private const string SKIP_KEY = "singularity-popover-motion-skip";

        public static void exclude(Gtk.Popover popover) {
            popover.set_data<bool>(SKIP_KEY, true);
        }

        public static void origin_for(Gtk.PositionType position, out double x, out double y) {
            switch (position) {
                case Gtk.PositionType.TOP: x = 0.5; y = 1.0; return;
                case Gtk.PositionType.LEFT: x = 1.0; y = 0.5; return;
                case Gtk.PositionType.RIGHT: x = 0.0; y = 0.5; return;
                default: x = 0.5; y = 0.0; return;
            }
        }

        public static void enter(Gtk.Popover popover) {
            if (popover.get_data<bool>(SKIP_KEY)) return;
            var content = popover.child;
            if (content == null) return;
            popover.opacity = 0.0;
            Singularity.Motion.tween(popover, "opacity", 1.0,
                Singularity.Motion.Duration.MEDIUM, Singularity.Motion.Curve.ENTER, popover);
            if (Singularity.Motion.reduced()) return;
            var transform = ChildTransform.for_widget(content, (out width, out height, out x, out y) => {
                var parent = content.get_parent();
                width = parent != null ? parent.get_width() : content.get_width();
                height = parent != null ? parent.get_height() : content.get_height();
                x = 0.0;
                y = 0.0;
            });
            double ox, oy;
            origin_for(popover.position, out ox, out oy);
            transform.origin_x = ox;
            transform.origin_y = oy;
            transform.scale_x = Singularity.Motion.ENTER_SCALE;
            transform.scale_y = Singularity.Motion.ENTER_SCALE;
            Singularity.Motion.tween(transform, "scale-x", 1.0,
                Singularity.Motion.Duration.MEDIUM, Singularity.Motion.Curve.ENTER, popover);
            Singularity.Motion.tween(transform, "scale-y", 1.0,
                Singularity.Motion.Duration.MEDIUM, Singularity.Motion.Curve.ENTER, popover);
        }
    }
}
