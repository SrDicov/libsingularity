namespace Singularity {
    public class Compute : Object {
        public delegate uint8[] Producer();

        [CCode (has_target = false)]
        private delegate int RawFn(void* arg, void* out_buf, size_t out_len);
        [CCode (has_target = false)]
        private delegate void* CtxNewFn(size_t budget);
        [CCode (has_target = false)]
        private delegate void CtxFreeFn(void* ctx);
        [CCode (has_target = false)]
        private delegate void ReportFn(void* ctx, void* report);
        [CCode (has_target = false)]
        private delegate int CallFn(void* ctx, uint32 region, void* key, size_t key_len,
                                    void* inputs, size_t n_inputs, void* out_buf, size_t out_len,
                                    RawFn fn, void* arg);

        private class Pending {
            public unowned Producer producer;
            public uint8[]? bytes;
        }

        private static Module? library;
        private static bool probed;
        private static CtxNewFn? ctx_new;
        private static CtxFreeFn? ctx_free;
        private static CallFn? ctx_call;
        private static ReportFn? ctx_report;

        private void* ctx;
        private uint flush_id;

        public Compute(size_t budget = 0) {
            if (load()) ctx = ctx_new(budget);
        }

        ~Compute() {
            if (flush_id != 0) Source.remove(flush_id);
            if (ctx != null) ctx_free(ctx);
        }

        public static bool available() {
            return load();
        }

        private static bool load() {
            if (probed) return library != null;
            probed = true;
            var module = Module.open("libsintycompute.so.0", ModuleFlags.LAZY | ModuleFlags.LOCAL);
            if (module == null) return false;
            void* a = null;
            void* b = null;
            void* c = null;
            void* d = null;
            if (!module.symbol("sinty_compute_ctx_new", out a)
                    || !module.symbol("sinty_compute_ctx_free", out b)
                    || !module.symbol("sinty_compute_call", out c)
                    || !module.symbol("sinty_compute_ctx_report", out d))
                return false;
            ctx_new = (CtxNewFn) a;
            ctx_free = (CtxFreeFn) b;
            ctx_call = (CallFn) c;
            ctx_report = (ReportFn) d;
            library = (owned) module;
            return true;
        }

        public static uint8[] key(string kind, uint8[] data) {
            var sum = new Checksum(ChecksumType.SHA256);
            sum.update(kind.data, kind.length);
            sum.update({ 0 }, 1);
            sum.update(data, data.length);
            uint8[] digest = new uint8[32];
            size_t len = digest.length;
            sum.get_digest(digest, ref len);
            return digest;
        }

        private static int produce_size(void* arg, void* out_buf, size_t out_len) {
            unowned Pending p = (Pending) arg;
            p.bytes = p.producer();
            uint32 n = p.bytes.length;
            Memory.copy(out_buf, &n, sizeof(uint32));
            return 0;
        }

        private static int produce_bytes(void* arg, void* out_buf, size_t out_len) {
            unowned Pending p = (Pending) arg;
            if (p.bytes == null) p.bytes = p.producer();
            if (p.bytes.length != out_len) return -1;
            Memory.copy(out_buf, p.bytes, out_len);
            return 0;
        }

        private void schedule_flush() {
            if (flush_id != 0) return;
            flush_id = Timeout.add_seconds(1, () => {
                flush_id = 0;
                uint64 report[6];
                ctx_report(ctx, report);
                return Source.REMOVE;
            });
        }

        public uint8[] call(uint32 region, uint8[] key, Producer producer) {
            if (ctx == null) return producer();
            schedule_flush();
            var pending = new Pending();
            pending.producer = producer;
            uint32 size = 0;
            int r = ctx_call(ctx, region * 2, key, key.length, null, 0, &size, sizeof(uint32),
                             produce_size, pending);
            if (r != 0) return pending.bytes ?? producer();
            uint8[] result = new uint8[size];
            r = ctx_call(ctx, region * 2 + 1, key, key.length, null, 0, result, size,
                         produce_bytes, pending);
            if (r != 0) return pending.bytes ?? producer();
            return result;
        }
    }
}
