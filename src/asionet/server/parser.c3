module asionet::server;
import std::io;
import std::net;
import std::time;
import std::collections;


// post /ping http/1.1
// host: localhost:8000
// accept: */*
// accept-encoding: gzip, deflate, br
// connection: keep-alive
// user-agent: python-httpx/0.27.0

struct HeaderMap
{
    HashMap(<String, String>) headers;
}

fn String! HeaderMap.get(&self, String key) @operator([])
{
    String keylower = key.new_ascii_to_lower();
    defer keylower.free();
    return self.headers[keylower]!;
}

fn bool HeaderMap.set(&self, String key, String value) @operator([]=)
{
    String keylower = key.new_ascii_to_lower();
    defer keylower.free();
    return self.headers[keylower] = value;
}

fn bool HeaderMap.has_key(&self, String key)
{
    String keylower = key.new_ascii_to_lower();
    defer keylower.free();
    return self.headers.has_key(keylower);
}

fn void HeaderMap.free(&self)
{
    self.headers.@each(; String key, String value){ value.free(); };
    self.headers.free();
}

struct ParsedReq
{
    String method;
    String path;
    String data;
    String accept;
    String accept_encoding;
    String connection;
    String content_type;
    ulong content_length;
    HeaderMap additional_headers;
}

fn void ParsedReq.set_defaults(&self)
{
    if (!self.connection) self.connection = string::new_format("keep-alive");
    if (!self.content_type) self.content_type = string::new_format("text/plain; charset=utf-8");
}

fn void ParsedReq.free(&self)
{
    self.method.free();
    self.path.free();
    self.data.free();
    self.accept.free();
    self.accept_encoding.free();
    self.connection.free();
    self.content_type.free();
    self.additional_headers.free();
}

struct ParseTask (Task)
{
    Socket *sock;  // tcp connection
    bool done;
    bool timeout;
    bool check_start_line;
    DString buffer;
    Time t_born;
    ParsedReq *req_info;
    Server *server;
}

fn String ParseTask.name(&self) @dynamic => "parse_task";

fn ParseTask* ParseTask.new_init(&self, Socket* sock, Server *server)
{
    self.sock = sock;
    self.done = false;
    self.timeout = false;
    self.check_start_line = true;
    self.buffer.new_init(256);
    self.t_born=time::now();
    self.req_info = null;
    self.server = server;
    return self;
}

fn void ParseTask.parse_error(&self, String err_msg)
{
    self.timeout=true;
    io::printn(err_msg);
}

fn void ParseTask.process(&self) @dynamic
{
    if (catch excuse = asionet::read_sock(self.sock, &self.buffer))
    {
        if (excuse != IoError.WOULD_BLOCK)
        {
            self.timeout=true;
            // log error
            if (excuse != ASock.EOF) io::printfn("Socket error: %s", excuse);
            return;
        }
    }

    // update time if there is data
    self.t_born = time::now();

    // parse req first
    if (self.req_info == null)
    {
        // try to check first header is correct
        if (self.check_start_line)
        {
            String start_line = self.buffer.str_view().tsplit("\r\n")[0];
            if (start_line.contains("http/1.1")) self.parse_error("Start line is wrong");
            self.check_start_line=false;
        }

        // not received all headers yet
        if (!self.buffer.str_view().contains("\r\n\r\n")) return;

        ParsedReq *req = mem::new(ParsedReq);
        // parse and save info
        String[] parts = self.buffer.tcopy_str().tsplit("\r\n\r\n");
        String[] headers = parts[0].tsplit("\r\n");
        self.buffer.clear();
        if (parts.len > 1) self.buffer.append_chars(parts[1]); // buffer should contain only the data

        foreach (header : headers)
        {
            header.convert_ascii_to_lower();
            switch
            {
                case header.contains("http/1.1"):
                    String[] header_parts = header.tsplit(" ");
                    req.method = header_parts[0].copy();
                    req.path = header_parts[1].copy();
                case header.contains("content-length"):
                    req.content_length = header.tsplit(":")[1].trim().to_ulong()!!;
                case header.contains("content-type"):
                    req.content_type = header.tsplit(":")[1].trim().copy();
                case header.contains("accept-encoding"):
                    req.accept_encoding = header.tsplit(":")[1].trim().copy();
                case header.contains("accept"):
                    req.accept = header.tsplit(":")[1].trim().copy();
                case header.contains("connection"):
                    req.connection = header.tsplit(":")[1].trim().copy();
                default:
                    // io::printfn("Unknown header %s", header);
                    String[] header_parts = header.tsplit(":");
                    req.additional_headers[header_parts[0].trim()] = header_parts[1].trim().copy();
            }
        }
        req.set_defaults();
        self.req_info = req;
    }

    // check how much data needs reading
    if (self.buffer.len() < self.req_info.content_length) return;

    // if all expected data is read then format data if any
    self.req_info.data = self.buffer.copy_str();

    // given parsed req, select task (only http 1.1 for now)
    Http11Task *task = mem::new(Http11Task);
    task.new_init(self.sock, self.req_info, self.server);
    self.server.tasks.push((Task)task);

    self.done = true;
}

fn bool ParseTask.is_done(&self) @dynamic
{
    self.timeout = self.timeout || (!self.done && time::now().diff_sec(self.t_born) >= self.server.timeout);
    return self.done || self.timeout;
}

fn Poll ParseTask.get_poll(&self) @dynamic
{
    Poll poll;
    poll.socket = self.sock.sock;
    poll.events = net::SUBSCRIBE_ANY_READ;
    return poll;
}

fn void ParseTask.free(&self) @dynamic
{
    if (self.timeout)
    {
        self.sock.destroy()!!;
        mem::free(self.sock);
        if (self.req_info != null)
        {
            self.req_info.free();
            mem::free(self.req_info);
        }
    }
    self.buffer.free();
}
