using Singularity.Collab;

void exchange_text(Text[] r, string?[] pending) {
    for (int i = 0; i < r.length; i++) {
        if (pending[i] == null) continue;
        for (int j = 0; j < r.length; j++) if (j != i) r[j].merge("peer", pending[i]);
    }
}

void test_text_converges() {
    var rand = new Rand.with_seed(7);
    for (int round_set = 0; round_set < 40; round_set++) {
        Text[] r = { new Text("hello world"), new Text("hello world"), new Text("hello world") };
        for (int round = 0; round < 12; round++) {
            string?[] pending = new string?[3];
            for (int i = 0; i < 3; i++) {
                int edits = rand.int_range(1, 4);
                for (int e = 0; e < edits; e++) {
                    int len = r[i].length;
                    if (len > 0 && rand.boolean()) {
                        int off = rand.int_range(0, len);
                        r[i].delete(off, rand.int_range(1, int.min(4, len - off) + 1));
                    } else {
                        r[i].insert(rand.int_range(0, len + 1), "%c".printf((char) ('a' + rand.int_range(0, 26))) + "xy".substring(0, rand.int_range(0, 3)));
                    }
                }
                pending[i] = r[i].take_outgoing();
            }
            exchange_text(r, pending);
            assert(r[0].to_string() == r[1].to_string());
            assert(r[1].to_string() == r[2].to_string());
        }
    }
}

void test_text_events_match_content() {
    var a = new Text("abc");
    var b = new Text("abc");
    var mirror = new StringBuilder("abc");
    b.inserted.connect((off, text, author) => {
        long byte_off = mirror.str.index_of_nth_char(off);
        mirror.insert((ssize_t) byte_off, text);
    });
    b.removed.connect((off, len, author) => {
        long start = mirror.str.index_of_nth_char(off);
        long end = mirror.str.index_of_nth_char(off + len);
        mirror.erase((ssize_t) start, (ssize_t) (end - start));
    });
    a.insert(1, "ZZ");
    a.delete(4, 1);
    a.insert(0, "è");
    b.merge("a", a.take_outgoing());
    assert(b.to_string() == a.to_string());
    assert(mirror.str == b.to_string());
}

void test_text_snapshot() {
    var a = new Text("abc");
    a.insert(3, "def");
    a.delete(0, 1);
    var b = new Text();
    b.load(a.snapshot());
    assert(b.to_string() == "bcdef");
    b.insert(5, "!");
    a.merge("b", b.take_outgoing());
    assert(a.to_string() == "bcdef!");
}

void test_document_lww() {
    var a = new Document();
    var b = new Document();
    a.set("A1", "1");
    b.set("A1", "2");
    b.set("B1", "x");
    string oa = a.take_outgoing();
    string ob = b.take_outgoing();
    a.merge("b", ob);
    b.merge("a", oa);
    assert(a.get("A1") == b.get("A1"));
    assert(a.get("B1") == "x");
    a.remove("B1");
    b.merge("a", a.take_outgoing());
    assert(b.get("B1") == null);
    var c = new Document();
    c.load(a.snapshot());
    assert(c.get("A1") == a.get("A1"));
    assert(c.keys().size == 1);
}

void test_document_update_diff() {
    var a = new Document();
    var b = new Document();
    var cur = new Gee.HashMap<string, string>();
    cur["s1"] = "one";
    cur["s2"] = "two";
    a.update(cur);
    b.merge("a", a.take_outgoing());
    cur.unset("s1");
    cur["s2"] = "TWO";
    assert(a.update(cur) == 2);
    var seen = new Gee.ArrayList<string>();
    b.changed.connect((k, v, who) => seen.add(k));
    b.merge("a", a.take_outgoing());
    assert(b.get("s1") == null);
    assert(b.get("s2") == "TWO");
    assert(seen.size == 2);
}


void test_text_binding_diff() {
    int start, removed;
    string inserted;
    TextBinding.diff("hello world", "hello brave world", out start, out removed, out inserted);
    assert(start == 6 && removed == 0 && inserted == "brave ");
    TextBinding.diff("caff\u00e8 latte", "caff\u00e8 nero", out start, out removed, out inserted);
    assert(start == 6 && removed == 5 && inserted == "nero");
    TextBinding.diff("aaa", "aa", out start, out removed, out inserted);
    assert(removed == 1 && inserted == "");
}

void test_text_binding_roundtrip() {
    string doc_a = "line one\nline two\n";
    string doc_b = doc_a;
    var ta = new Text(doc_a);
    var tb = new Text(doc_b);
    var ba = new TextBinding(ta, () => doc_a, (t, who) => doc_a = t);
    var bb = new TextBinding(tb, () => doc_b, (t, who) => doc_b = t);
    doc_a = "line one!\nline two\n";
    ba.local_changed();
    doc_b = "line one\nline two, edited\n";
    bb.local_changed();
    string oa = ta.take_outgoing();
    string ob = tb.take_outgoing();
    doc_b = "line one\nline two, edited\nthree\n";
    tb.merge("a", oa);
    ta.merge("b", ob);
    ta.merge("b", tb.take_outgoing());
    var loop = new MainLoop();
    Timeout.add(50, () => { loop.quit(); return false; });
    loop.run();
    assert(doc_a == "line one!\nline two, edited\nthree\n");
    assert(doc_b == doc_a);
}


void test_units_binding_reencoding() {
    var model_a = new Gee.HashMap<string, string>();
    model_a["t1"] = "{\"done\":false,\"title\":\"Milk\"}";
    var a = new Document();
    a.load_values(model_a);
    var b = new Document();
    b.load(a.snapshot());
    var model_b = new Gee.HashMap<string, bool>();
    model_b["t1"] = false;
    var bind_b = new UnitsBinding(b, () => {
        var m = new Gee.HashMap<string, string>();
        foreach (var e in model_b.entries) m[e.key] = "{ \"title\": \"Milk\", \"done\": %s }".printf(e.value.to_string());
        return m;
    }, (changed, who) => {
        foreach (var e in changed.entries) model_b[e.key] = e.value != null && e.value.contains("true");
    });
    bind_b.adopt_local();
    bind_b.local_changed();
    assert(b.take_outgoing() == null);
    a.set("t1", "{\"done\":true,\"title\":\"Milk\"}");
    b.merge("a", a.take_outgoing());
    assert(model_b["t1"] == true);
    bind_b.local_changed();
    assert(b.take_outgoing() == null);
}

int main(string[] args) {
    Test.init(ref args);
    Test.add_func("/collab/text-converges", test_text_converges);
    Test.add_func("/collab/text-events", test_text_events_match_content);
    Test.add_func("/collab/text-snapshot", test_text_snapshot);
    Test.add_func("/collab/document-lww", test_document_lww);
    Test.add_func("/collab/document-update", test_document_update_diff);
    Test.add_func("/collab/binding-diff", test_text_binding_diff);
    Test.add_func("/collab/binding-roundtrip", test_text_binding_roundtrip);
    Test.add_func("/collab/units-reencoding", test_units_binding_reencoding);
    return Test.run();
}
