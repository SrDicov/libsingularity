namespace Singularity.Messaging {

    public interface Provider : Object {
        public abstract string id { owned get; }
        public abstract string name { owned get; }
        public abstract string icon_name { owned get; }

        public signal void channels_changed();

        public abstract async Gee.List<Channel> discover() throws Error;
    }

    public abstract class Channel : Object {
        public string id { get; construct; }
        public string provider_id { get; construct; }
        public string title { get; set; default = ""; }
        public string icon_name { get; set; default = "chat-message-new-symbolic"; }
        public string self_id { get; set; default = ""; }
        public string account_id { get; set; default = ""; }
        public Features features { get; set; default = Features.NONE; }
        public Realtime realtime { get; set; default = Realtime.POLL; }
        public uint poll_seconds { get; set; default = 30; }
        public string attention { get; set; default = ""; }

        public signal void incoming(string conversation, Gee.List<Message> messages);
        public signal void conversations_changed();

        public bool supports(Features f) {
            return (features & f) == f;
        }

        public abstract async Gee.List<Conversation> conversations(Cancellable? cancel = null) throws Error;

        public abstract async Gee.List<Message> messages(string conversation, string? after, int limit, Cancellable? cancel = null) throws Error;

        public abstract async Message send(string conversation, string text, string? reply_to, Cancellable? cancel = null) throws Error;

        public virtual async Message upload(string conversation, File file, string caption, Cancellable? cancel = null) throws Error {
            throw new MessagingError.NOT_SUPPORTED(_("This service cannot send files"));
        }

        public virtual async void mark_read(string conversation, string message, Cancellable? cancel = null) throws Error {
        }

        public virtual async void edit(string conversation, string message, string text, Cancellable? cancel = null) throws Error {
            throw new MessagingError.NOT_SUPPORTED(_("This service cannot edit messages"));
        }

        public virtual async void remove(string conversation, string message, Cancellable? cancel = null) throws Error {
            throw new MessagingError.NOT_SUPPORTED(_("This service cannot delete messages"));
        }

        public virtual async void react(string conversation, string message, string emoji, bool add, Cancellable? cancel = null) throws Error {
            throw new MessagingError.NOT_SUPPORTED(_("This service has no reactions"));
        }

        public virtual async string start(string peer, Cancellable? cancel = null) throws Error {
            throw new MessagingError.NOT_SUPPORTED(_("This service cannot start conversations here"));
        }

        public virtual async Bytes? download(Attachment attachment, Cancellable? cancel = null) throws Error {
            return null;
        }

        public virtual async Gee.List<Peer> search_people(string query, Cancellable? cancel = null) throws Error {
            return new Gee.ArrayList<Peer>();
        }

        public virtual async bool wait(string conversation, string after, Cancellable cancel) throws Error {
            return false;
        }

        public virtual void close() {
        }
    }
}
