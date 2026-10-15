namespace Singularity {

    public class HttpBody {

        public static async Bytes read(Soup.Session session, Soup.Message message, int64 limit,
                                       int priority = Priority.DEFAULT, Cancellable? cancellable = null) throws Error {
            var stream = yield session.send_async(message, priority, cancellable);
            int64 declared = message.response_headers.get_content_length();
            if (declared > limit) {
                close_quietly(stream, priority);
                throw new IOError.MESSAGE_TOO_LARGE("The response is larger than %s", format_size((uint64) limit));
            }
            var body = new ByteArray();
            var chunk = new uint8[65536];
            while (true) {
                ssize_t n = yield stream.read_async(chunk, priority, cancellable);
                if (n <= 0) break;
                if (body.len + n > limit) {
                    close_quietly(stream, priority);
                    throw new IOError.MESSAGE_TOO_LARGE("The response is larger than %s", format_size((uint64) limit));
                }
                body.append(chunk[0:(int) n]);
            }
            close_quietly(stream, priority);
            return ByteArray.free_to_bytes((owned) body);
        }

        public static Bytes read_sync(Soup.Session session, Soup.Message message, int64 limit,
                                      Cancellable? cancellable = null) throws Error {
            var stream = session.send(message, cancellable);
            try {
                if (message.response_headers.get_content_length() > limit)
                    throw new IOError.MESSAGE_TOO_LARGE("The response is larger than %s", format_size((uint64) limit));
                var body = new ByteArray();
                var chunk = new uint8[65536];
                while (true) {
                    ssize_t n = stream.read(chunk, cancellable);
                    if (n <= 0) break;
                    if (body.len + n > limit)
                        throw new IOError.MESSAGE_TOO_LARGE("The response is larger than %s", format_size((uint64) limit));
                    body.append(chunk[0:(int) n]);
                }
                return ByteArray.free_to_bytes((owned) body);
            } finally {
                try {
                    stream.close(null);
                } catch (Error e) {
                }
            }
        }

        private static void close_quietly(InputStream stream, int priority) {
            stream.close_async.begin(priority, null, (obj, res) => {
                try {
                    stream.close_async.end(res);
                } catch (Error e) {
                }
            });
        }
    }
}
