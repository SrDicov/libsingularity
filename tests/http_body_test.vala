Soup.Server start_server(out uint port) {
    var server = new Soup.Server("server-header", "test");
    server.add_handler(null, (srv, msg, path, query) => {
        msg.set_status(200, null);
        if (path == "/small") {
            msg.set_response("text/plain", Soup.MemoryUse.COPY, new uint8[100]);
        } else if (path == "/big") {
            msg.set_response("text/plain", Soup.MemoryUse.COPY, new uint8[2 * 1024 * 1024]);
        } else {
            msg.get_response_headers().set_encoding(Soup.Encoding.CHUNKED);
            var body = msg.get_response_body();
            for (int i = 0; i < 32; i++) body.append_take(new uint8[65536]);
            body.complete();
        }
    });
    try {
        server.listen_local(0, 0);
    } catch (Error e) {
        error("%s", e.message);
    }
    port = server.get_uris().data.get_port();
    return server;
}

Bytes? fetch(Soup.Session session, uint port, string path, out Error? failure) {
    failure = null;
    var loop = new MainLoop();
    Bytes? result = null;
    Error? err = null;
    var msg = new Soup.Message("GET", "http://127.0.0.1:%u%s".printf(port, path));
    Singularity.HttpBody.read.begin(session, msg, 1024 * 1024, Priority.DEFAULT, null, (obj, res) => {
        try {
            result = Singularity.HttpBody.read.end(res);
        } catch (Error e) {
            err = e;
        }
        loop.quit();
    });
    loop.run();
    failure = err;
    return result;
}

void test_limits() {
    uint port;
    var server = start_server(out port);
    var session = new Soup.Session();
    Error? failure;
    var small = fetch(session, port, "/small", out failure);
    assert(failure == null && small != null && small.get_size() == 100);
    fetch(session, port, "/big", out failure);
    assert(failure is IOError.MESSAGE_TOO_LARGE);
    fetch(session, port, "/chunked", out failure);
    assert(failure is IOError.MESSAGE_TOO_LARGE);
    small = fetch(session, port, "/small", out failure);
    assert(failure == null && small != null && small.get_size() == 100);
    server.disconnect();
}

void test_sync_limits() {
    uint port;
    var server = start_server(out port);
    Bytes? got = null;
    Error? big_error = null;
    Error? chunked_error = null;
    var worker = new Thread<bool>("http", () => {
        var session = new Soup.Session();
        try {
            got = Singularity.HttpBody.read_sync(session, new Soup.Message("GET", "http://127.0.0.1:%u/small".printf(port)), 1024 * 1024);
        } catch (Error e) {
        }
        try {
            Singularity.HttpBody.read_sync(session, new Soup.Message("GET", "http://127.0.0.1:%u/big".printf(port)), 1024 * 1024);
        } catch (Error e) {
            big_error = e;
        }
        try {
            Singularity.HttpBody.read_sync(session, new Soup.Message("GET", "http://127.0.0.1:%u/chunked".printf(port)), 1024 * 1024);
        } catch (Error e) {
            chunked_error = e;
        }
        return true;
    });
    var loop = new MainLoop();
    Timeout.add(20, () => {
        if (big_error != null && chunked_error != null) {
            loop.quit();
            return false;
        }
        return true;
    });
    loop.run();
    worker.join();
    assert(got != null && got.get_size() == 100);
    assert(big_error is IOError.MESSAGE_TOO_LARGE);
    assert(chunked_error is IOError.MESSAGE_TOO_LARGE);
    server.disconnect();
}

void main(string[] args) {
    Test.init(ref args);
    Test.add_func("/http-body/limits", test_limits);
    Test.add_func("/http-body/sync-limits", test_sync_limits);
    Test.run();
}
