[CCode (cname = "singularity_spell_test_count", cheader_filename = "spell_probe.h")]
extern uint checked_words();
[CCode (cname = "singularity_spell_test_reset", cheader_filename = "spell_probe.h")]
extern void reset_checks();

bool gtk_ready = false;

bool ready(bool italian = false) {
    if (!gtk_ready) {
        Test.skip("no display");
        return false;
    }
    if (!Singularity.Text.SpellChecker.for_language("en_US").available
            || (italian && !Singularity.Text.SpellChecker.for_language("it_IT").available)) {
        Test.skip("required dictionary not installed");
        return false;
    }
    return true;
}

delegate bool Condition();

void wait_until(owned Condition condition, int seconds = 60) {
    int64 deadline = get_monotonic_time() + seconds * TimeSpan.SECOND;
    while (!condition() && get_monotonic_time() < deadline) {
        MainContext.default().iteration(false);
        Thread.usleep(1000);
    }
    if (!condition()) Test.message("Timed out: checks=%u enabled=%s available=%s", checked_words(), Singularity.Text.SpellChecker.get_default().enabled.to_string(), Singularity.Text.SpellChecker.get_default().available.to_string());
    assert(condition());
}

void settle(uint milliseconds = 700) {
    var loop = new GLib.MainLoop();
    GLib.Timeout.add(milliseconds, () => { loop.quit(); return GLib.Source.REMOVE; });
    loop.run();
}

bool underlined(Gtk.TextBuffer buffer, int offset) {
    Gtk.TextIter iter;
    buffer.get_iter_at_offset(out iter, offset);
    foreach (var tag in iter.get_tags()) {
        if (tag.underline == Pango.Underline.ERROR) return true;
    }
    return false;
}

Gtk.Window show_view(Gtk.TextView view) {
    var button = new Gtk.Button.with_label("Focus elsewhere");
    var box = new Gtk.Box(Gtk.Orientation.VERTICAL, 6);
    var scroller = new Gtk.ScrolledWindow();
    scroller.child = view;
    scroller.vexpand = true;
    box.append(scroller);
    box.append(button);
    var window = new Gtk.Window();
    window.set_default_size(480, 240);
    window.set_child(box);
    window.present();
    button.grab_focus();
    return window;
}

void incremental_edit() {
    if (!ready(false)) return;
    var buffer = new Gtk.TextBuffer(null);
    var content = new StringBuilder();
    for (int i = 0; i < 5000; i++) content.append("hello world\n");
    buffer.set_text(content.str);
    var view = new Gtk.TextView.with_buffer(buffer);
    var window = show_view(view);
    reset_checks();
    Singularity.Text.SpellIntegration.attach(view);
    wait_until(() => checked_words() >= 10000);
    assert(!view.has_focus);
    assert(!underlined(buffer, 1));
    reset_checks();
    Gtk.TextIter iter;
    buffer.get_iter_at_offset(out iter, 2);
    buffer.insert(ref iter, "x", -1);
    wait_until(() => underlined(buffer, 1));
    settle(350);
    uint count = checked_words();
    Test.message("A one-character edit checked %u words in a 10000-word buffer", count);
    assert(underlined(buffer, 1));
    assert(count <= 16);
    window.destroy();
}

void long_buffer() {
    if (!ready(false)) return;
    var buffer = new Gtk.TextBuffer(null);
    var content = new StringBuilder("zzqzxword\n");
    for (int i = 0; i < 40000; i++) content.append("hello\n");
    content.append("zzqzxtail\n");
    buffer.set_text(content.str);
    var view = new Gtk.TextView.with_buffer(buffer);
    var window = show_view(view);
    Singularity.Text.SpellIntegration.attach(view);
    wait_until(() => underlined(buffer, buffer.get_char_count() - 3), 180);
    Test.message("Large buffer: %d characters, first misspelling underlined=%s", buffer.get_char_count(), underlined(buffer, 1).to_string());
    assert(underlined(buffer, 1));
    window.destroy();
}

void unicode_undo() {
    if (!ready(true)) return;
    var buffer = new Gtk.TextBuffer(null);
    buffer.enable_undo = true;
    buffer.set_text("città buongiorno zzqzxword\n");
    var view = new Gtk.TextView.with_buffer(buffer);
    var window = show_view(view);
    Singularity.Text.SpellIntegration.set_language(view, "it-IT");
    settle();
    assert(!underlined(buffer, 1));
    assert(!underlined(buffer, 7));
    assert(underlined(buffer, 18));
    Gtk.TextIter iter;
    buffer.get_iter_at_offset(out iter, 1);
    buffer.begin_user_action();
    buffer.insert(ref iter, "ä", -1);
    buffer.end_user_action();
    settle();
    assert(underlined(buffer, 1));
    assert(buffer.can_undo);
    buffer.undo();
    settle();
    assert(buffer.text == "città buongiorno zzqzxword\n");
    assert(!underlined(buffer, 1));
    assert(buffer.can_redo);
    buffer.redo();
    settle();
    assert(underlined(buffer, 1));
    buffer.undo();
    settle();
    assert(!underlined(buffer, 1));
    window.destroy();
}

void mixed_languages() {
    if (!ready(true)) return;
    var buffer = new Gtk.TextBuffer(null);
    buffer.set_text("buongiorno knowledge zzqzxword\n");
    var italian = buffer.create_tag(null, "language", "it");
    var style = buffer.create_tag(null, "foreground", "blue");
    Gtk.TextIter start, end;
    buffer.get_bounds(out start, out end);
    buffer.apply_tag(style, start, end);
    buffer.get_iter_at_offset(out end, 10);
    buffer.apply_tag(italian, start, end);
    var view = new Gtk.TextView.with_buffer(buffer);
    var window = show_view(view);
    Singularity.Text.SpellIntegration.attach(view);
    settle();
    assert(!underlined(buffer, 1));
    assert(!underlined(buffer, 12));
    assert(underlined(buffer, 22));
    buffer.remove_tag(italian, start, end);
    settle();
    assert(underlined(buffer, 1));
    buffer.apply_tag(italian, start, end);
    settle();
    assert(!underlined(buffer, 1));
    italian.language = "en-US";
    settle();
    assert(underlined(buffer, 1));
    italian.language = "it-IT";
    Singularity.Text.SpellIntegration.set_language(view, "it-IT");
    settle();
    assert(!underlined(buffer, 1));
    assert(underlined(buffer, 12));
    var english = buffer.create_tag(null, "language", "en-US");
    buffer.get_iter_at_offset(out start, 11);
    buffer.get_iter_at_offset(out end, 20);
    buffer.apply_tag(english, start, end);
    settle();
    assert(!underlined(buffer, 12));
    english.language_set = false;
    settle();
    assert(underlined(buffer, 12));
    buffer.get_iter_at_offset(out start, 1);
    assert(start.has_tag(style));
    reset_checks();
    style.foreground = "red";
    settle();
    Test.message("Changing a color checked %u words", checked_words());
    assert(checked_words() == 0);
    window.destroy();
}

void replace_buffer_lifecycle() {
    if (!ready(false)) return;
    var old_buffer = new Gtk.TextBuffer(null);
    old_buffer.set_text("zzqzxword\n");
    Gtk.TextView? view = new Gtk.TextView.with_buffer(old_buffer);
    Gtk.Window? window = show_view(view);
    Singularity.Text.SpellIntegration.attach(view);
    settle();
    assert(underlined(old_buffer, 1));
    var buffer = new Gtk.TextBuffer(null);
    buffer.set_text("hello\n");
    view.buffer = buffer;
    settle();
    assert(old_buffer.get_tag_table().get_size() == 0);
    assert(!underlined(buffer, 1));
    reset_checks();
    Gtk.TextIter iter;
    old_buffer.get_start_iter(out iter);
    old_buffer.insert(ref iter, "x", -1);
    settle();
    assert(checked_words() == 0);
    var watched = WeakRef(view);
    buffer.get_start_iter(out iter);
    buffer.insert(ref iter, "zzqzxword ", -1);
    window.destroy();
    view = null;
    window = null;
    settle();
    assert(watched.get() == null);
    assert(buffer.get_tag_table().get_size() == 0);
}

bool entry_underlined(Gtk.Entry entry) {
    var field = ((Gtk.Editable) entry).get_delegate() as Gtk.Text;
    var attrs = field.attributes;
    if (attrs == null) return false;
    var iter = attrs.get_iterator();
    do {
        unowned Pango.Attribute? underline = iter.get(Pango.AttrType.UNDERLINE);
        if (underline != null && ((Pango.AttrInt) underline).value == Pango.Underline.ERROR) return true;
    } while (iter.next());
    return false;
}

void entry_language() {
    if (!ready(true)) return;
    var entry = new Gtk.Entry();
    entry.text = "buongiorno";
    var button = new Gtk.Button.with_label("Focus elsewhere");
    var box = new Gtk.Box(Gtk.Orientation.VERTICAL, 6);
    box.append(entry);
    box.append(button);
    var window = new Gtk.Window();
    window.set_child(box);
    window.present();
    button.grab_focus();
    Singularity.Text.SpellIntegration.attach(entry);
    settle();
    assert(entry_underlined(entry));
    Singularity.Text.SpellIntegration.set_language(entry, "it-IT");
    settle();
    assert(!entry_underlined(entry));
    Singularity.Text.SpellIntegration.set_language(entry, null);
    settle();
    assert(entry_underlined(entry));
    var field = ((Gtk.Editable) entry).get_delegate() as Gtk.Text;
    var attrs = new Pango.AttrList();
    attrs.insert(Pango.attr_weight_new(Pango.Weight.BOLD));
    field.attributes = attrs;
    Singularity.Text.SpellIntegration.set_language(entry, "it-IT");
    settle();
    assert(field.attributes == attrs);
    window.destroy();
}

void dictionary_language_tags() {
    if (!ready(true)) return;
    var italian = Singularity.Text.SpellChecker.for_language("it_IT");
    assert(italian.available);
    assert(italian.check("buongiorno"));
    assert(!italian.check("knowledge"));
    var pango = Singularity.Text.SpellChecker.for_language("it-it");
    assert(pango == italian);
    var base_language = Singularity.Text.SpellChecker.for_language("it");
    assert(base_language.available);
    assert(base_language.check("buongiorno"));
    assert(!base_language.check("knowledge"));
    var english = Singularity.Text.SpellChecker.for_language("en-us");
    assert(english.available);
    assert(english.check("knowledge"));
    assert(!english.check("buongiorno"));
    assert(!Singularity.Text.SpellChecker.for_language("zz-ZZ").available);
}

int main(string[] args) {
    Test.init(ref args);
    gtk_ready = Gtk.init_check();
    if (gtk_ready) {
        Singularity.Runtime.desktop_settings_schema = "dev.sinty.spelltest";
        var settings = new GLib.Settings(Singularity.Runtime.desktop_settings_schema);
        settings.set_boolean("spell-check-enabled", true);
        settings.set_strv("spell-check-languages", { "en_US" });
    }
    Test.add_func("/spell/incremental-edit", incremental_edit);
    Test.add_func("/spell/large-buffer", long_buffer);
    Test.add_func("/spell/unicode-undo", unicode_undo);
    Test.add_func("/spell/mixed-languages", mixed_languages);
    Test.add_func("/spell/buffer-lifecycle", replace_buffer_lifecycle);
    Test.add_func("/spell/entry-language", entry_language);
    Test.add_func("/spell/dictionary-tags", dictionary_language_tags);
    return Test.run();
}
