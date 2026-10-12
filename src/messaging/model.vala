namespace Singularity.Messaging {

    public errordomain MessagingError {
        NOT_SUPPORTED,
        NETWORK,
        AUTH,
        NOT_FOUND,
        PROTOCOL
    }

    public enum ConversationKind {
        DIRECT,
        GROUP,
        CHANNEL;

        public string to_id() {
            switch (this) {
                case GROUP: return "group";
                case CHANNEL: return "channel";
                default: return "direct";
            }
        }

        public static ConversationKind parse(string id) {
            switch (id) {
                case "group": return GROUP;
                case "channel": return CHANNEL;
                default: return DIRECT;
            }
        }
    }

    public enum MessageState {
        SENT,
        PENDING,
        FAILED;

        public string to_id() {
            switch (this) {
                case PENDING: return "pending";
                case FAILED: return "failed";
                default: return "sent";
            }
        }

        public static MessageState parse(string id) {
            switch (id) {
                case "pending": return PENDING;
                case "failed": return FAILED;
                default: return SENT;
            }
        }
    }

    [Flags]
    public enum Features {
        NONE = 0,
        ATTACHMENTS = 1 << 0,
        REPLIES = 1 << 1,
        EDIT = 1 << 2,
        DELETE = 1 << 3,
        REACTIONS = 1 << 4,
        READ_MARKERS = 1 << 5,
        NEW_CONVERSATION = 1 << 6
    }

    public enum Realtime {
        POLL,
        LONG_POLL,
        PUSH
    }

    public class Peer : Object {
        public string id { get; construct; }
        public string name { get; construct; }
        public string detail { get; construct; }

        public Peer(string id, string name, string detail = "") {
            Object(id: id, name: name, detail: detail);
        }
    }

    public class Attachment : Object {
        public string name { get; set; default = ""; }
        public string mime { get; set; default = ""; }
        public string url { get; set; default = ""; }
        public int64 size { get; set; default = 0; }
        public string path { get; set; default = ""; }

        public bool is_image {
            get { return mime.has_prefix("image/"); }
        }

        public Json.Object to_json() {
            var o = new Json.Object();
            o.set_string_member("name", name);
            if (mime != "") o.set_string_member("mime", mime);
            if (url != "") o.set_string_member("url", url);
            if (size > 0) o.set_int_member("size", size);
            if (path != "") o.set_string_member("path", path);
            return o;
        }

        public static Attachment from_json(Json.Object o) {
            var a = new Attachment();
            a.name = o.get_string_member_with_default("name", "");
            a.mime = o.get_string_member_with_default("mime", "");
            a.url = o.get_string_member_with_default("url", "");
            a.size = o.get_int_member_with_default("size", 0);
            a.path = o.get_string_member_with_default("path", "");
            return a;
        }
    }

    public class Message : Object {
        public string id { get; set; default = ""; }
        public string conversation { get; set; default = ""; }
        public string author_id { get; set; default = ""; }
        public string author_name { get; set; default = ""; }
        public string text { get; set; default = ""; }
        public int64 time { get; set; default = 0; }
        public bool outgoing { get; set; default = false; }
        public bool edited { get; set; default = false; }
        public bool deleted { get; set; default = false; }
        public bool system { get; set; default = false; }
        public string reply_to { get; set; default = ""; }
        public string reply_preview { get; set; default = ""; }
        public MessageState state { get; set; default = MessageState.SENT; }
        public Gee.ArrayList<Attachment> attachments { get; default = new Gee.ArrayList<Attachment>(); }
        public Gee.TreeMap<string, int> reactions { get; default = new Gee.TreeMap<string, int>(); }
        public Gee.HashSet<string> own_reactions { get; default = new Gee.HashSet<string>(); }

        public string preview() {
            if (deleted) return _("Message deleted");
            if (text.strip() != "") return text.strip().replace("\n", " ");
            if (attachments.size > 0) return attachments[0].name != "" ? attachments[0].name : _("Attachment");
            return "";
        }

        public Json.Object to_json() {
            var o = new Json.Object();
            o.set_string_member("id", id);
            o.set_string_member("conversation", conversation);
            o.set_string_member("author", author_id);
            o.set_string_member("name", author_name);
            o.set_string_member("text", text);
            o.set_int_member("time", time);
            if (outgoing) o.set_boolean_member("out", true);
            if (edited) o.set_boolean_member("edited", true);
            if (deleted) o.set_boolean_member("deleted", true);
            if (system) o.set_boolean_member("system", true);
            if (reply_to != "") o.set_string_member("reply", reply_to);
            if (reply_preview != "") o.set_string_member("reply_preview", reply_preview);
            if (state != MessageState.SENT) o.set_string_member("state", state.to_id());
            if (attachments.size > 0) {
                var arr = new Json.Array();
                foreach (var a in attachments) arr.add_object_element(a.to_json());
                o.set_array_member("attachments", arr);
            }
            if (reactions.size > 0) {
                var r = new Json.Object();
                foreach (var e in reactions.entries) r.set_int_member(e.key, e.value);
                o.set_object_member("reactions", r);
            }
            if (own_reactions.size > 0) {
                var arr = new Json.Array();
                foreach (string s in own_reactions) arr.add_string_element(s);
                o.set_array_member("mine", arr);
            }
            return o;
        }

        public static Message from_json(Json.Object o) {
            var m = new Message();
            m.id = o.get_string_member_with_default("id", "");
            m.conversation = o.get_string_member_with_default("conversation", "");
            m.author_id = o.get_string_member_with_default("author", "");
            m.author_name = o.get_string_member_with_default("name", "");
            m.text = o.get_string_member_with_default("text", "");
            m.time = o.get_int_member_with_default("time", 0);
            m.outgoing = o.get_boolean_member_with_default("out", false);
            m.edited = o.get_boolean_member_with_default("edited", false);
            m.deleted = o.get_boolean_member_with_default("deleted", false);
            m.system = o.get_boolean_member_with_default("system", false);
            m.reply_to = o.get_string_member_with_default("reply", "");
            m.reply_preview = o.get_string_member_with_default("reply_preview", "");
            m.state = MessageState.parse(o.get_string_member_with_default("state", "sent"));
            if (o.has_member("attachments")) {
                foreach (var n in o.get_array_member("attachments").get_elements()) m.attachments.add(Attachment.from_json(n.get_object()));
            }
            if (o.has_member("reactions")) {
                var r = o.get_object_member("reactions");
                foreach (string k in r.get_members()) m.reactions[k] = (int) r.get_int_member(k);
            }
            if (o.has_member("mine")) {
                foreach (var n in o.get_array_member("mine").get_elements()) m.own_reactions.add(n.get_string());
            }
            return m;
        }
    }

    public class Conversation : Object {
        public string id { get; set; default = ""; }
        public string title { get; set; default = ""; }
        public ConversationKind kind { get; set; default = ConversationKind.DIRECT; }
        public string avatar_url { get; set; default = ""; }
        public string peer { get; set; default = ""; }
        public int unread { get; set; default = 0; }
        public bool mentioned { get; set; default = false; }
        public int64 activity { get; set; default = 0; }
        public string last_preview { get; set; default = ""; }
        public string last_author { get; set; default = ""; }
        public bool read_only { get; set; default = false; }
        public bool muted { get; set; default = false; }
        public bool mentions_only { get; set; default = false; }

        public bool counts {
            get { return !muted && (!mentions_only || mentioned); }
        }

        public Json.Object to_json() {
            var o = new Json.Object();
            o.set_string_member("id", id);
            o.set_string_member("title", title);
            o.set_string_member("kind", kind.to_id());
            if (avatar_url != "") o.set_string_member("avatar", avatar_url);
            if (peer != "") o.set_string_member("peer", peer);
            o.set_int_member("unread", unread);
            if (mentioned) o.set_boolean_member("mentioned", true);
            o.set_int_member("activity", activity);
            o.set_string_member("preview", last_preview);
            if (last_author != "") o.set_string_member("last_author", last_author);
            if (read_only) o.set_boolean_member("read_only", true);
            if (muted) o.set_boolean_member("muted", true);
            if (mentions_only) o.set_boolean_member("mentions_only", true);
            return o;
        }

        public static Conversation from_json(Json.Object o) {
            var c = new Conversation();
            c.id = o.get_string_member_with_default("id", "");
            c.title = o.get_string_member_with_default("title", "");
            c.kind = ConversationKind.parse(o.get_string_member_with_default("kind", "direct"));
            c.avatar_url = o.get_string_member_with_default("avatar", "");
            c.peer = o.get_string_member_with_default("peer", "");
            c.unread = (int) o.get_int_member_with_default("unread", 0);
            c.mentioned = o.get_boolean_member_with_default("mentioned", false);
            c.activity = o.get_int_member_with_default("activity", 0);
            c.last_preview = o.get_string_member_with_default("preview", "");
            c.last_author = o.get_string_member_with_default("last_author", "");
            c.read_only = o.get_boolean_member_with_default("read_only", false);
            c.muted = o.get_boolean_member_with_default("muted", false);
            c.mentions_only = o.get_boolean_member_with_default("mentions_only", false);
            return c;
        }
    }
}
