@testable import AnyBrowserCore
import Darwin
import Foundation
import Testing

/// A stand-in for Chromium, compiled once per test run with /usr/bin/cc, so the runtime's process
/// handling runs in CI without the 400 MB engine. It is a real executable at a fixed path, as
/// `owns()` requires: interpreters such as /usr/bin/python3 exec somewhere else.
///
/// Like Chromium it takes `--user-data-dir` and `--remote-debugging-port`, points SingletonLock at
/// its pid, serves `/json/version` on 127.0.0.1 and answers DevTools commands over a WebSocket,
/// logging each one to `<user-data-dir>/cdp.log`. `<user-data-dir>/fake-engine.conf` (key=value
/// lines) changes its behaviour; see `FakeEngine.source`.
enum FakeEngine {
    static func executable() throws -> URL { try compiled.get() }

    private static let compiled: Result<URL, Error> = Result {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("anybrowser-fake-engine-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard let canonical = ProcessInspection.canonicalURL(directory, isDirectory: true) else {
            throw VerificationFailure.message("No canonical path for \(directory.path)")
        }
        let sourceFile = canonical.appendingPathComponent("fake-chromium.c")
        let binary = canonical.appendingPathComponent("fake-chromium")
        try Data(source.utf8).write(to: sourceFile)
        let compiler = Process()
        compiler.executableURL = URL(fileURLWithPath: "/usr/bin/cc")
        compiler.arguments = ["-O1", "-Wno-deprecated-declarations", "-o", binary.path, sourceFile.path]
        let errors = Pipe()
        compiler.standardError = errors
        try compiler.run()
        let message = errors.fileHandleForReading.readDataToEndOfFile()
        compiler.waitUntilExit()
        guard compiler.terminationStatus == 0 else {
            throw VerificationFailure.message("cc failed: \(String(decoding: message, as: UTF8.self))")
        }
        return binary
    }

    // Settings: ready_ms (delay before listening), exit_ms + exit_code (exit early), kill_ms +
    // kill_signal (die by a signal), ignore_term=1, relaunch_ms (close, then start again with the
    // same arguments as a new process, as chrome://restart does), output (a line for stderr),
    // spam_kb (that much stderr before listening), touch + touch_text (write a file at start, path
    // relative to the user data dir), cdp=reply|silent|none and targets (JSON for Target.getTargets).
    static let source = #"""
    #include <CommonCrypto/CommonDigest.h>
    #include <arpa/inet.h>
    #include <errno.h>
    #include <fcntl.h>
    #include <mach-o/dyld.h>
    #include <netinet/in.h>
    #include <pthread.h>
    #include <signal.h>
    #include <stdint.h>
    #include <stdio.h>
    #include <stdlib.h>
    #include <string.h>
    #include <sys/socket.h>
    #include <time.h>
    #include <unistd.h>

    extern char **environ;
    static char udd[4096], lock_path[4300], log_path[4300], self_path[4096];
    static int port, server = -1, ignore_term, exit_code, kill_signal = SIGKILL;
    static long ready_ms, exit_ms = -1, kill_ms = -1, relaunch_ms = -1, spam_kb;
    static char output[4096], cdp[16] = "reply", targets[16384] = "[]", touch[1024], touch_text[1024];
    static char **saved_argv;
    static pthread_mutex_t log_lock = PTHREAD_MUTEX_INITIALIZER;

    static void sleep_ms(long ms) {
        struct timespec t = { ms / 1000, (ms % 1000) * 1000000L };
        while (nanosleep(&t, &t) != 0 && errno == EINTR) {}
    }

    static void on_term(int sig) { (void)sig; unlink(lock_path); _exit(0); }

    static void load_config(void) {
        char path[4300], line[20000];
        snprintf(path, sizeof path, "%s/fake-engine.conf", udd);
        FILE *file = fopen(path, "r");
        if (!file) return;
        while (fgets(line, sizeof line, file)) {
            line[strcspn(line, "\r\n")] = 0;
            char *eq = strchr(line, '=');
            if (!eq) continue;
            *eq = 0;
            const char *key = line, *value = eq + 1;
            if (!strcmp(key, "ready_ms")) ready_ms = atol(value);
            else if (!strcmp(key, "exit_ms")) exit_ms = atol(value);
            else if (!strcmp(key, "exit_code")) exit_code = atoi(value);
            else if (!strcmp(key, "kill_ms")) kill_ms = atol(value);
            else if (!strcmp(key, "kill_signal")) kill_signal = atoi(value);
            else if (!strcmp(key, "ignore_term")) ignore_term = atoi(value);
            else if (!strcmp(key, "relaunch_ms")) relaunch_ms = atol(value);
            else if (!strcmp(key, "spam_kb")) spam_kb = atol(value);
            else if (!strcmp(key, "output")) strlcpy(output, value, sizeof output);
            else if (!strcmp(key, "cdp")) strlcpy(cdp, value, sizeof cdp);
            else if (!strcmp(key, "targets")) strlcpy(targets, value, sizeof targets);
            else if (!strcmp(key, "touch")) strlcpy(touch, value, sizeof touch);
            else if (!strcmp(key, "touch_text")) strlcpy(touch_text, value, sizeof touch_text);
        }
        fclose(file);
    }

    static int read_full(int fd, void *buffer, size_t length) {
        size_t done = 0;
        while (done < length) {
            ssize_t got = read(fd, (char *)buffer + done, length - done);
            if (got <= 0) return 0;
            done += (size_t)got;
        }
        return 1;
    }

    static void send_frame(int fd, int opcode, const char *data, size_t length) {
        unsigned char header[10];
        size_t size = 2;
        header[0] = (unsigned char)(0x80 | opcode);
        if (length < 126) {
            header[1] = (unsigned char)length;
        } else if (length < 65536) {
            header[1] = 126; header[2] = (unsigned char)(length >> 8); header[3] = (unsigned char)length; size = 4;
        } else {
            header[1] = 127;
            for (int i = 0; i < 8; i++) header[2 + i] = (unsigned char)(length >> (56 - 8 * i));
            size = 10;
        }
        write(fd, header, size);
        if (length) write(fd, data, length);
    }

    static void base64(const unsigned char *in, size_t length, char *out) {
        static const char table[] = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
        size_t o = 0;
        for (size_t i = 0; i < length; i += 3) {
            unsigned value = (unsigned)in[i] << 16 | (i + 1 < length ? (unsigned)in[i + 1] << 8 : 0) | (i + 2 < length ? in[i + 2] : 0);
            out[o++] = table[(value >> 18) & 63];
            out[o++] = table[(value >> 12) & 63];
            out[o++] = i + 1 < length ? table[(value >> 6) & 63] : '=';
            out[o++] = i + 2 < length ? table[value & 63] : '=';
        }
        out[o] = 0;
    }

    static void reply(int fd, const char *message) {
        long id = 0;
        char method[128] = "", result[16500], out[16700];
        const char *found = strstr(message, "\"id\":");
        if (found) id = atol(found + 5);
        found = strstr(message, "\"method\":\"");
        if (found) {
            found += 10;
            size_t i = 0;
            while (found[i] && found[i] != '"' && i < sizeof method - 1) { method[i] = found[i]; i++; }
            method[i] = 0;
        }
        if (!strcmp(method, "Target.getTargets")) snprintf(result, sizeof result, "{\"targetInfos\":%s}", targets);
        else if (!strcmp(method, "Target.attachToTarget")) snprintf(result, sizeof result, "{\"sessionId\":\"fake-session\"}");
        else if (!strcmp(method, "Target.createTarget")) snprintf(result, sizeof result, "{\"targetId\":\"created-%ld\"}", id);
        else snprintf(result, sizeof result, "{}");
        int length = snprintf(out, sizeof out, "{\"id\":%ld,\"result\":%s}", id, result);
        send_frame(fd, 1, out, (size_t)length);
    }

    static void websocket(int fd, const char *request) {
        const char *key = strcasestr(request, "Sec-WebSocket-Key:");
        if (!key) return;
        key += 18;
        while (*key == ' ') key++;
        char combined[256], accept[64];
        size_t i = 0;
        while (key[i] && key[i] != '\r' && i < 100) { combined[i] = key[i]; i++; }
        combined[i] = 0;
        strlcat(combined, "258EAFA5-E914-47DA-95CA-C5AB0DC85B11", sizeof combined);
        unsigned char digest[CC_SHA1_DIGEST_LENGTH];
        CC_SHA1(combined, (CC_LONG)strlen(combined), digest);
        base64(digest, sizeof digest, accept);
        dprintf(fd, "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: %s\r\n\r\n", accept);
        for (;;) {
            unsigned char head[2], extended[8], mask[4] = {0};
            if (!read_full(fd, head, 2)) return;
            int opcode = head[0] & 0x0f;
            uint64_t length = head[1] & 0x7f;
            if (length == 126) {
                if (!read_full(fd, extended, 2)) return;
                length = (uint64_t)extended[0] << 8 | extended[1];
            } else if (length == 127) {
                if (!read_full(fd, extended, 8)) return;
                length = 0;
                for (int j = 0; j < 8; j++) length = length << 8 | extended[j];
            }
            if ((head[1] & 0x80) && !read_full(fd, mask, 4)) return;
            if (length > (1 << 20)) return;
            char *payload = malloc(length + 1);
            if (!payload || !read_full(fd, payload, length)) { free(payload); return; }
            for (uint64_t j = 0; j < length; j++) payload[j] ^= mask[j % 4];
            payload[length] = 0;
            if (opcode == 8) { send_frame(fd, 8, "", 0); free(payload); return; }
            if (opcode == 9) { send_frame(fd, 10, payload, length); free(payload); continue; }
            if (opcode == 1) {
                pthread_mutex_lock(&log_lock);
                int log = open(log_path, O_WRONLY | O_CREAT | O_APPEND, 0600);
                if (log >= 0) { write(log, payload, length); write(log, "\n", 1); close(log); }
                pthread_mutex_unlock(&log_lock);
                if (strcmp(cdp, "silent")) reply(fd, payload);
            }
            free(payload);
        }
    }

    static void *connection(void *argument) {
        int fd = (int)(intptr_t)argument;
        char request[8192];
        size_t length = 0;
        while (length < sizeof request - 1) {
            ssize_t got = read(fd, request + length, sizeof request - 1 - length);
            if (got <= 0) { close(fd); return NULL; }
            length += (size_t)got;
            request[length] = 0;
            if (strstr(request, "\r\n\r\n")) break;
        }
        if (!strncmp(request, "GET /json/version", 17)) {
            char body[512];
            snprintf(body, sizeof body, "{\"Browser\":\"FakeEngine/1.0\",\"webSocketDebuggerUrl\":\"ws://127.0.0.1:%d/devtools/browser/fake-browser\"}", port);
            dprintf(fd, "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: %zu\r\nConnection: close\r\n\r\n%s", strlen(body), body);
        } else if (!strncmp(request, "GET /devtools/browser/", 22) && strcasestr(request, "websocket") && strcmp(cdp, "none")) {
            websocket(fd, request);
        } else {
            dprintf(fd, "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n");
        }
        close(fd);
        return NULL;
    }

    static void *exiter(void *argument) {
        (void)argument;
        sleep_ms(exit_ms);
        fprintf(stderr, "fake-engine: exiting with %d\n", exit_code);
        fflush(stderr);
        _exit(exit_code);
    }

    static void *killer(void *argument) {
        (void)argument;
        sleep_ms(kill_ms);
        signal(kill_signal, SIG_DFL);
        kill(getpid(), kill_signal);
        return NULL;
    }

    // Closes, then starts again as a new process with the same arguments once this one is gone,
    // the way Chromium's relauncher does.
    static void *relauncher(void *argument) {
        (void)argument;
        sleep_ms(relaunch_ms);
        int count = 0;
        while (environ[count]) count++;
        char **environment = calloc((size_t)count + 2, sizeof(char *));
        for (int i = 0; i < count; i++) environment[i] = environ[i];
        environment[count] = "FAKE_ENGINE_RELAUNCHED=1";
        close(server);
        unlink(lock_path);
        pid_t parent = getpid();
        pid_t child = fork();
        if (child == 0) {
            struct timespec pause = { 0, 10000000L };
            while (getppid() == parent) nanosleep(&pause, NULL);
            execve(self_path, saved_argv, environment);
            _exit(127);
        }
        fprintf(stderr, "fake-engine: relaunching as %d\n", child);
        fflush(stderr);
        _exit(0);
    }

    static void start_thread(void *(*body)(void *)) {
        pthread_t thread;
        pthread_create(&thread, NULL, body, NULL);
        pthread_detach(thread);
    }

    int main(int argc, char **argv) {
        saved_argv = argv;
        for (int i = 1; i < argc; i++) {
            if (!strncmp(argv[i], "--user-data-dir=", 16)) strlcpy(udd, argv[i] + 16, sizeof udd);
            else if (!strncmp(argv[i], "--remote-debugging-port=", 24)) port = atoi(argv[i] + 24);
        }
        if (!udd[0] || !port) { fprintf(stderr, "fake-engine: no --user-data-dir or --remote-debugging-port\n"); return 2; }
        char raw[4096];
        uint32_t size = sizeof raw;
        if (_NSGetExecutablePath(raw, &size) != 0 || !realpath(raw, self_path)) return 2;
        load_config();
        signal(SIGPIPE, SIG_IGN);
        signal(SIGTERM, ignore_term ? SIG_IGN : on_term);
        snprintf(lock_path, sizeof lock_path, "%s/SingletonLock", udd);
        snprintf(log_path, sizeof log_path, "%s/cdp.log", udd);
        char holder[64];
        snprintf(holder, sizeof holder, "fakehost-%d", getpid());
        unlink(lock_path);
        symlink(holder, lock_path);
        if (touch[0]) {
            char path[5400];
            snprintf(path, sizeof path, "%s/%s", udd, touch);
            FILE *file = fopen(path, "w");
            if (file) { fputs(touch_text, file); fclose(file); }
        }
        if (output[0]) fprintf(stderr, "%s\n", output);
        for (long written = 0; written < spam_kb * 1024;) {
            written += fprintf(stderr, "fake-engine: line %08ld of noise to fill the pipe ...............................\n", written);
        }
        if (spam_kb) fprintf(stderr, "fake-engine: noise done\n");
        fflush(stderr);
        if (exit_ms >= 0) start_thread(exiter);
        if (kill_ms >= 0) start_thread(killer);
        sleep_ms(ready_ms);
        server = socket(AF_INET, SOCK_STREAM, 0);
        int on = 1;
        setsockopt(server, SOL_SOCKET, SO_REUSEADDR, &on, sizeof on);
        struct sockaddr_in address = { .sin_len = sizeof address, .sin_family = AF_INET, .sin_port = htons((uint16_t)port) };
        address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
        if (bind(server, (struct sockaddr *)&address, sizeof address) != 0 || listen(server, 16) != 0) {
            fprintf(stderr, "fake-engine: cannot listen on %d: %s\n", port, strerror(errno));
            return 3;
        }
        if (relaunch_ms >= 0 && !getenv("FAKE_ENGINE_RELAUNCHED")) start_thread(relauncher);
        for (;;) {
            int client = accept(server, NULL, NULL);
            if (client < 0) {
                if (errno == EINTR || errno == ECONNABORTED) continue;
                for (;;) pause();
            }
            pthread_t thread;
            pthread_create(&thread, NULL, connection, (void *)(intptr_t)client);
            pthread_detach(thread);
        }
    }
    """#
}

/// A runtime on the fake engine, with its storage inside a stand-in Application Support folder
/// so that its caches live under a stand-in Caches folder, and timeouts short enough for tests.
@MainActor
struct FakeEngineFixture {
    let root: URL
    let applicationSupport: URL
    let caches: URL
    let storage: URL
    let engine: BrowserEngine
    let runtime: BrowserRuntime

    init(_ label: String) throws {
        root = try scratchDirectory(label)
        applicationSupport = root.appendingPathComponent("Application Support", isDirectory: true)
        caches = root.appendingPathComponent("Caches", isDirectory: true)
        storage = applicationSupport.appendingPathComponent("AnyBrowser", isDirectory: true)
        let passkeyBox = root.appendingPathComponent("PasskeyBox", isDirectory: true)
        for directory in [applicationSupport, caches, storage, passkeyBox] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
        }
        try Data("{}".utf8).write(to: passkeyBox.appendingPathComponent("manifest.json"))
        engine = BrowserEngine(version: "test", executable: try FakeEngine.executable(), passkeyBoxDirectory: passkeyBox)
        runtime = BrowserRuntime(engine: engine, storage: storage, applicationSupport: applicationSupport, caches: caches)
        runtime.readinessTimeout = 5
        runtime.stopTimeout = 1
        runtime.terminationGrace = 0.5
        runtime.startPageBudget = 2
    }

    /// Another runtime on the same folders, as AnyBrowser has after a restart.
    func makeRuntime() -> BrowserRuntime {
        BrowserRuntime(engine: engine, storage: storage, applicationSupport: applicationSupport, caches: caches)
    }

    func profile(port: Int, name: String = "Fake") -> BrowserProfile {
        BrowserProfile(name: name, port: port, fingerprint: FingerprintSettings(seed: port), proxy: "")
    }

    /// Writes the fake engine's settings for `profile`, creating its data directory.
    func configure(_ profile: BrowserProfile, _ settings: [String: String]) throws {
        let directory = runtime.dataDirectory(for: profile.id)
        try PrivateDirectory.ensure(directory)
        let text = settings.map { "\($0.key)=\($0.value)\n" }.joined()
        try Data(text.utf8).write(to: directory.appendingPathComponent("fake-engine.conf"))
    }

    /// The DevTools commands the fake engine received for `profile`, in order.
    func commands(_ profile: BrowserProfile) -> [[String: Any]] {
        let log = runtime.dataDirectory(for: profile.id).appendingPathComponent("cdp.log")
        guard let text = try? String(contentsOf: log, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap {
            try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]
        }
    }

    /// Runs `body`, then ends whatever the fixture started, also when `body` throws.
    func run(_ profiles: [BrowserProfile], runtimes: [BrowserRuntime] = [], _ body: () async throws -> Void) async throws {
        try await runThenCleanUp(body) { await cleanUp(profiles, runtimes: runtimes) }
    }

    /// Ends every process still holding one of the fixture's directories, then deletes them.
    func cleanUp(_ profiles: [BrowserProfile], runtimes: [BrowserRuntime] = []) async {
        for profile in profiles {
            for runtime in [runtime] + runtimes { try? await runtime.stop(profile.id, force: true) }
            if let pid = lockHolder(profile), ProcessInspection.arguments(pid)?.contains(
                "--user-data-dir=\(runtime.dataDirectory(for: profile.id).path)") == true {
                kill(pid, SIGKILL)
            }
        }
        try? FileManager.default.removeItem(at: root)
    }

    func lockHolder(_ profile: BrowserProfile) -> Int32? {
        ProcessInspection.lockHolder(runtime.dataDirectory(for: profile.id))
    }

    /// Waits up to `seconds` for `condition`, refreshing nothing on its own.
    func eventually(_ seconds: TimeInterval = 5, _ condition: () async -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if await condition() { return true }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return await condition()
    }
}

func isAlive(_ pid: Int32) -> Bool { ProcessStamp.read(pid) != nil }

/// Runs `body`, then `cleanUp`, also when `body` throws.
@MainActor
func runThenCleanUp(_ body: () async throws -> Void, cleanUp: () async -> Void) async throws {
    do {
        try await body()
    } catch {
        await cleanUp()
        throw error
    }
    await cleanUp()
}
