namespace Singularity.Text {

    /**
     * Turns on spell checking for every text field of an application.
     *
     * Once installed, any Gtk.TextView or Gtk.Entry that takes the keyboard
     * focus in one of the application's windows gets misspelled words
     * underlined, with corrections and "Add to Dictionary" in its context
     * menu. Password, number, email, URL and terminal fields are skipped, as
     * are fields that set Gtk.InputHints.NO_SPELLCHECK and source code views
     * that do not ask for Gtk.InputHints.SPELLCHECK.
     */
    public class SpellIntegration : Object {
        private const string DATA_KEY = "singularity-speller";
        private const string LANGUAGE_KEY = "singularity-spell-language";

        /** Starts spell checking the text fields of `app`. */
        public static void install(Gtk.Application app) {
            app.window_added.connect(watch_window);
            foreach (var window in app.get_windows()) watch_window(window);
        }

        /** Spell checks `widget` now if it is a text field that wants it. */
        public static void attach(Gtk.Widget? widget) {
            if (widget == null || widget.get_data<Object>(DATA_KEY) != null) return;
            if (widget is Gtk.Entry) {
                attach(((Gtk.Editable) widget).get_delegate() as Gtk.Widget);
                return;
            }
            if (widget is Gtk.TextView) {
                var view = (Gtk.TextView) widget;
                bool source_view = view.get_type().name().has_prefix("GtkSource")
                    && (view.input_hints & Gtk.InputHints.SPELLCHECK) == 0;
                if (!view.editable || source_view || !wanted(view.input_purpose, view.input_hints)) return;
                widget.set_data<Object>(DATA_KEY, new TextViewSpeller(view));
            } else if (widget is Gtk.Text) {
                var text = (Gtk.Text) widget;
                if (!text.visibility || text.attributes != null
                        || !wanted(text.input_purpose, text.input_hints)) return;
                widget.set_data<Object>(DATA_KEY, new EntrySpeller(text));
            }
        }

        public static void set_language(Gtk.Widget widget, string? language) {
            widget.set_data<string>(LANGUAGE_KEY, language);
            if (widget is Gtk.Entry) {
                var child = ((Gtk.Editable) widget).get_delegate() as Gtk.Widget;
                if (child != null) set_language(child, language);
                return;
            }
            attach(widget);
            var speller = widget.get_data<Object>(DATA_KEY);
            if (speller is TextViewSpeller) ((TextViewSpeller) speller).recheck_all();
            if (speller is EntrySpeller) ((EntrySpeller) speller).schedule_recheck();
        }

        internal static SpellChecker checker_for(Gtk.Widget widget) {
            string? language = widget.get_data<string>(LANGUAGE_KEY);
            return language != null ? SpellChecker.for_language(language) : SpellChecker.get_default();
        }

        private static void watch_window(Gtk.Window window) {
            var reference = WeakRef(window);
            window.notify["focus-widget"].connect(() => {
                var watched = reference.get() as Gtk.Window;
                if (watched != null) attach(watched.get_focus());
            });
        }

        internal static bool wanted(Gtk.InputPurpose purpose, Gtk.InputHints hints) {
            if ((hints & Gtk.InputHints.NO_SPELLCHECK) != 0) return false;
            return purpose == Gtk.InputPurpose.FREE_FORM || purpose == Gtk.InputPurpose.ALPHA
                || purpose == Gtk.InputPurpose.NAME;
        }

        internal static bool checkable(string word) {
            if (word.char_count() < 2) return false;
            unichar c;
            int i = 0;
            while (word.get_next_char(ref i, out c)) {
                if (c.isdigit() || c == '_' || c == '@' || c == '/') return false;
            }
            return true;
        }

        internal static GLib.Menu suggestion_menu(string word) {
            return suggestions(word, SpellChecker.get_default());
        }

        internal static GLib.Menu suggestions(string word, SpellChecker checker) {
            var menu = new GLib.Menu();
            foreach (string suggestion in checker.suggest(word)) {
                var item = new GLib.MenuItem(suggestion, null);
                item.set_action_and_target_value("spell.replace", new Variant.string(suggestion));
                menu.append_item(item);
            }
            var add = new GLib.MenuItem(_("Add to Dictionary"), null);
            add.set_action_and_target_value("spell.add", new Variant.string(word));
            menu.append_item(add);
            return menu;
        }
    }

    internal class TextViewSpeller : Object {
        private class DirtyRange : Object {
            private Gtk.TextBuffer buffer;
            public Gtk.TextMark start;
            public Gtk.TextMark end;

            public DirtyRange(Gtk.TextBuffer buffer, Gtk.TextIter start, Gtk.TextIter end) {
                this.buffer = buffer;
                this.start = buffer.create_mark(null, start, true);
                this.end = buffer.create_mark(null, end, false);
            }

            ~DirtyRange() {
                if (!start.get_deleted()) buffer.delete_mark(start);
                if (!end.get_deleted()) buffer.delete_mark(end);
            }
        }

        private WeakRef view_ref = WeakRef(null);
        private Gtk.TextView? view { owned get { return view_ref.get() as Gtk.TextView; } }
        private Gtk.TextBuffer buffer;
        private Gtk.TextTag tag;
        private GLib.Menu section = new GLib.Menu();
        private Gtk.TextMark word_start;
        private Gtk.TextMark word_end;
        private Gtk.TextMark previous_cursor;
        private Gee.ArrayList<DirtyRange> dirty = new Gee.ArrayList<DirtyRange>();
        private Gee.HashSet<SpellChecker> observed = new Gee.HashSet<SpellChecker>();
        private Gee.HashSet<Gtk.TextTag> language_tags = new Gee.HashSet<Gtk.TextTag>();
        private SpellChecker menu_checker;
        private ulong[] buffer_handlers = {};
        private ulong[] table_handlers = {};
        private uint recheck_id = 0;
        private bool composing = false;

        public TextViewSpeller(Gtk.TextView view) {
            view_ref.set(view);
            menu_checker = SpellChecker.get_default();
            observe(menu_checker);
            var extra = new GLib.Menu();
            extra.append_section(null, section);
            if (view.extra_menu != null) extra.append_section(null, view.extra_menu);
            view.extra_menu = extra;

            var actions = new SimpleActionGroup();
            var replace = new SimpleAction("replace", VariantType.STRING);
            replace.activate.connect((param) => replace_word(param.get_string()));
            actions.add_action(replace);
            var add = new SimpleAction("add", VariantType.STRING);
            add.activate.connect((param) => menu_checker.add_to_dictionary(param.get_string()));
            actions.add_action(add);
            view.insert_action_group("spell", actions);

            var click = new Gtk.GestureClick();
            click.button = Gdk.BUTTON_SECONDARY;
            click.set_propagation_phase(Gtk.PropagationPhase.CAPTURE);
            click.pressed.connect((n, x, y) => prepare_menu(x, y));
            view.add_controller(click);
            view.notify["buffer"].connect(bind_buffer);
            view.notify["has-focus"].connect(cursor_moved);
            view.notify["input-hints"].connect(recheck_all);
            view.notify["input-purpose"].connect(recheck_all);
            view.preedit_changed.connect((preedit) => {
                composing = preedit != "";
                if (!composing) cursor_moved();
            });
            bind_buffer();
        }

        ~TextViewSpeller() {
            unbind_buffer();
        }

        private void observe(SpellChecker checker) {
            if (!observed.add(checker)) return;
            checker.changed.connect(recheck_all);
        }

        private void stop_check() {
            if (recheck_id == 0) return;
            Source.remove(recheck_id);
            recheck_id = 0;
        }

        private void unbind_buffer() {
            stop_check();
            dirty.clear();
            language_tags.clear();
            if (buffer == null) return;
            foreach (ulong id in buffer_handlers) {
                if (SignalHandler.is_connected(buffer, id)) SignalHandler.disconnect(buffer, id);
            }
            foreach (ulong id in table_handlers) {
                if (SignalHandler.is_connected(buffer.get_tag_table(), id)) SignalHandler.disconnect(buffer.get_tag_table(), id);
            }
            buffer_handlers = {};
            table_handlers = {};
            section.remove_all();
            buffer.get_tag_table().remove(tag);
            buffer.delete_mark(word_start);
            buffer.delete_mark(word_end);
            buffer.delete_mark(previous_cursor);
        }

        private void bind_buffer() {
            if (view == null) return;
            unbind_buffer();
            buffer = view.buffer;
            tag = buffer.create_tag(null, "underline", Pango.Underline.ERROR);
            Gtk.TextIter start, cursor;
            buffer.get_start_iter(out start);
            buffer.get_iter_at_mark(out cursor, buffer.get_insert());
            word_start = buffer.create_mark(null, start, true);
            word_end = buffer.create_mark(null, start, false);
            previous_cursor = buffer.create_mark(null, cursor, true);
            buffer_handlers += buffer.insert_text.connect(inserted);
            buffer_handlers += buffer.delete_range.connect(queue_range);
            buffer_handlers += buffer.notify["cursor-position"].connect(cursor_moved);
            buffer_handlers += buffer.apply_tag.connect_after(language_range);
            buffer_handlers += buffer.remove_tag.connect_after(language_range);
            var table = buffer.get_tag_table();
            table.@foreach((applied) => {
                if (applied.language_set) language_tags.add(applied);
            });
            table_handlers += table.tag_changed.connect((changed, size_changed) => {
                bool known = language_tags.contains(changed);
                if (changed.language_set) language_tags.add(changed);
                else language_tags.remove(changed);
                if (known || changed.language_set) recheck_all();
            });
            table_handlers += table.tag_added.connect((added) => {
                if (added.language_set) language_tags.add(added);
            });
            table_handlers += table.tag_removed.connect((removed) => {
                if (language_tags.remove(removed) || removed.language_set) recheck_all();
            });
            recheck_all();
        }

        private void inserted(ref Gtk.TextIter position, string text, int length) {
            queue_range(position, position);
        }

        private void language_range(Gtk.TextTag language, Gtk.TextIter start, Gtk.TextIter end) {
            if (language.language_set) {
                language_tags.add(language);
                queue_range(start, end);
            }
        }

        private void cursor_moved() {
            if (view == null || buffer == null) return;
            Gtk.TextIter previous, cursor;
            buffer.get_iter_at_mark(out previous, previous_cursor);
            buffer.get_iter_at_mark(out cursor, buffer.get_insert());
            queue_range(previous, previous);
            queue_range(cursor, cursor);
            buffer.move_mark(previous_cursor, cursor);
        }

        private void queue_range(Gtk.TextIter start, Gtk.TextIter end) {
            if (view == null) return;
            var from = start;
            var to = end;
            if (from.backward_char() && !from.starts_word()) from.backward_word_start();
            if (to.forward_char() && !to.ends_word()) to.forward_word_end();
            for (int i = dirty.size - 1; i >= 0; i--) {
                Gtk.TextIter left, right;
                buffer.get_iter_at_mark(out left, dirty[i].start);
                buffer.get_iter_at_mark(out right, dirty[i].end);
                if (from.compare(right) > 0 || to.compare(left) < 0) continue;
                if (left.compare(from) < 0) from = left;
                if (right.compare(to) > 0) to = right;
                dirty.remove_at(i);
            }
            dirty.insert(0, new DirtyRange(buffer, from, to));
            stop_check();
            recheck_id = Timeout.add(300, () => {
                recheck_id = 0;
                start_check();
                return Source.REMOVE;
            });
        }

        internal void recheck_all() {
            if (view == null || buffer == null) return;
            stop_check();
            dirty.clear();
            Gtk.TextIter start, end;
            buffer.get_bounds(out start, out end);
            dirty.add(new DirtyRange(buffer, start, end));
            start_check();
        }

        private void start_check() {
            recheck_id = Idle.add(() => {
                bool more = check_slice();
                if (!more) recheck_id = 0;
                return more;
            }, Priority.LOW);
        }

        private SpellChecker checker_at(Gtk.TextIter iter) {
            var checker = SpellIntegration.checker_for(view);
            foreach (var applied in iter.get_tags()) {
                if (!applied.language_set) continue;
                checker = SpellChecker.for_language(iter.get_language().to_string());
                break;
            }
            observe(checker);
            return checker;
        }

        private bool check_slice() {
            var field = view;
            if (field == null || dirty.size == 0) return Source.REMOVE;
            if (!SpellChecker.get_default().enabled || !SpellIntegration.wanted(field.input_purpose, field.input_hints)) {
                Gtk.TextIter start, end;
                buffer.get_bounds(out start, out end);
                buffer.remove_tag(tag, start, end);
                dirty.clear();
                return Source.REMOVE;
            }
            var range = dirty[0];
            Gtk.TextIter start, limit, cursor;
            buffer.get_iter_at_mark(out start, range.start);
            buffer.get_iter_at_mark(out limit, range.end);
            buffer.get_iter_at_mark(out cursor, buffer.get_insert());
            var stop = start;
            for (int i = 0; i < 128 && stop.compare(limit) < 0; i++) {
                var before = stop;
                stop.forward_word_end();
                if (stop.equal(before)) break;
            }
            if (stop.compare(limit) > 0) stop = limit;
            buffer.remove_tag(tag, start, stop);
            var iter = start;
            while (iter.compare(stop) < 0) {
                var before = iter;
                iter.forward_word_end();
                if (iter.equal(before) || iter.compare(stop) > 0 || !iter.ends_word()) break;
                var begin = iter;
                begin.backward_word_start();
                if ((field.has_focus || composing) && (cursor.in_range(begin, iter) || cursor.equal(iter))) continue;
                string word = buffer.get_text(begin, iter, false);
                if (SpellIntegration.checkable(word) && !checker_at(begin).check(word)) buffer.apply_tag(tag, begin, iter);
            }
            if (stop.compare(limit) >= 0 || stop.equal(start)) dirty.remove_at(0);
            else buffer.move_mark(range.start, stop);
            return dirty.size > 0;
        }

        private void prepare_menu(double x, double y) {
            section.remove_all();
            int bx, by;
            view.window_to_buffer_coords(Gtk.TextWindowType.WIDGET, (int) x, (int) y, out bx, out by);
            Gtk.TextIter iter;
            if (!view.get_iter_at_location(out iter, bx, by)) return;
            if (!iter.inside_word() && !iter.ends_word()) return;
            var start = iter;
            var end = iter;
            if (!start.starts_word()) start.backward_word_start();
            if (!end.ends_word()) end.forward_word_end();
            string word = buffer.get_text(start, end, false);
            menu_checker = checker_at(start);
            if (!menu_checker.enabled || !SpellIntegration.checkable(word) || menu_checker.check(word)) return;
            buffer.move_mark(word_start, start);
            buffer.move_mark(word_end, end);
            section.append_section(null, SpellIntegration.suggestions(word, menu_checker));
        }

        private void replace_word(string replacement) {
            Gtk.TextIter start, end;
            buffer.get_iter_at_mark(out start, word_start);
            buffer.get_iter_at_mark(out end, word_end);
            buffer.begin_user_action();
            buffer.delete(ref start, ref end);
            buffer.insert(ref start, replacement, -1);
            buffer.end_user_action();
        }
    }

    internal class EntrySpeller : Object {
        private WeakRef field_ref = WeakRef(null);
        private Gtk.Text? text { owned get { return field_ref.get() as Gtk.Text; } }
        private SpellChecker checker;
        private Gee.HashSet<SpellChecker> observed = new Gee.HashSet<SpellChecker>();
        private bool composing = false;
        private Pango.AttrList? spell_attrs;
        private GLib.Menu section = new GLib.Menu();
        private int word_start = 0;
        private int word_end = 0;
        private uint recheck_id = 0;

        public EntrySpeller(Gtk.Text text) {
            field_ref.set(text);
            checker = SpellIntegration.checker_for(text);
            observe(SpellChecker.get_default());
            observe(checker);
            var extra = new GLib.Menu();
            extra.append_section(null, section);
            if (text.extra_menu != null) extra.append_section(null, text.extra_menu);
            text.extra_menu = extra;

            var actions = new SimpleActionGroup();
            var replace = new SimpleAction("replace", VariantType.STRING);
            replace.activate.connect((param) => replace_word(param.get_string()));
            actions.add_action(replace);
            var add = new SimpleAction("add", VariantType.STRING);
            add.activate.connect((param) => checker.add_to_dictionary(param.get_string()));
            actions.add_action(add);
            text.insert_action_group("spell", actions);

            var click = new Gtk.GestureClick();
            click.button = Gdk.BUTTON_SECONDARY;
            click.set_propagation_phase(Gtk.PropagationPhase.CAPTURE);
            click.pressed.connect(() => prepare_menu());
            text.add_controller(click);

            text.changed.connect(schedule_recheck);
            text.notify["cursor-position"].connect(schedule_recheck);
            text.notify["has-focus"].connect(schedule_recheck);
            text.notify["input-hints"].connect(schedule_recheck);
            text.notify["input-purpose"].connect(schedule_recheck);
            text.notify["visibility"].connect(schedule_recheck);
            text.preedit_changed.connect((preedit) => {
                composing = preedit != "";
                if (!composing) schedule_recheck();
            });
            recheck();
        }

        ~EntrySpeller() {
            if (recheck_id != 0) Source.remove(recheck_id);
        }

        private void observe(SpellChecker checker) {
            if (observed.add(checker)) checker.changed.connect(schedule_recheck);
        }

        internal void schedule_recheck() {
            if (recheck_id != 0) Source.remove(recheck_id);
            recheck_id = Timeout.add(300, () => {
                recheck_id = 0;
                recheck();
                return Source.REMOVE;
            });
        }

        private void recheck() {
            var field = text;
            if (field == null || (field.attributes != null && field.attributes != spell_attrs)) return;
            checker = SpellIntegration.checker_for(field);
            observe(checker);
            var attrs = new Pango.AttrList();
            if (field.visibility && SpellIntegration.wanted(field.input_purpose, field.input_hints) && checker.enabled && checker.available) {
                string content = field.text;
                int cursor_byte = content.index_of_nth_char(field.get_position());
                int i = 0;
                while (i < content.length) {
                    int start, end;
                    if (!next_word(content, ref i, out start, out end)) break;
                    if ((field.has_focus || composing) && cursor_byte >= start && cursor_byte <= end) continue;
                    string word = content.substring(start, end - start);
                    if (SpellIntegration.checkable(word) && !checker.check(word)) {
                        var underline = Pango.attr_underline_new(Pango.Underline.ERROR);
                        underline.start_index = start;
                        underline.end_index = end;
                        attrs.insert((owned) underline);
                    }
                }
            }
            spell_attrs = attrs;
            field.attributes = attrs;
        }

        private static bool next_word(string content, ref int index, out int start, out int end) {
            start = end = index;
            unichar c;
            int position = index;
            while (position < content.length) {
                int before = position;
                content.get_next_char(ref position, out c);
                if (c.isalpha()) {
                    start = before;
                    end = position;
                    int inner = position;
                    while (inner < content.length) {
                        int prev = inner;
                        content.get_next_char(ref inner, out c);
                        if (!c.isalpha() && c != '\'') {
                            inner = prev;
                            break;
                        }
                        end = inner;
                    }
                    index = end;
                    return true;
                }
            }
            index = content.length;
            return false;
        }

        private void replace_word(string replacement) {
            var field = text;
            if (field == null) return;
            field.delete_text(word_start, word_end);
            int position = word_start;
            field.insert_text(replacement, -1, ref position);
        }

        private void prepare_menu() {
            section.remove_all();
            checker = SpellIntegration.checker_for(text);
            if (!checker.enabled) return;
            string content = text.text;
            int cursor_byte = content.index_of_nth_char(text.get_position());
            int i = 0;
            int start, end;
            while (next_word(content, ref i, out start, out end)) {
                if (cursor_byte < start || cursor_byte > end) continue;
                string word = content.substring(start, end - start);
                if (!SpellIntegration.checkable(word) || checker.check(word)) return;
                word_start = (int) content.char_count(start);
                word_end = (int) content.char_count(end);
                section.append_section(null, SpellIntegration.suggestions(word, checker));
                return;
            }
        }
    }
}
