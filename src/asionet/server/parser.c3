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

struct ArgMap
{
    HashMap(<String, String>) args;
}

fn String! ArgMap.get(&self, String key) @operator([])
{
    String keylower = key.new_ascii_to_lower();
    defer keylower.free();
    return self.args[keylower]!;
}

fn bool ArgMap.set(&self, String key, String value) @operator([]=)
{
    String keylower = key.new_ascii_to_lower();
    defer keylower.free();
    return self.args[keylower] = value;
}

fn bool ArgMap.has_key(&self, String key)
{
    String keylower = key.new_ascii_to_lower();
    defer keylower.free();
    return self.args.has_key(keylower);
}

fn void ArgMap.free(&self)
{
    self.args.@each(; String key, String value){ value.free(); };
    self.args.free();
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
    ArgMap additional_headers;
    ArgMap params;
}

macro ParsedReq.set_defaults(&self)
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
    self.params.free();
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
    self.buffer.init(mem, capacity:256);
    self.t_born=time::now();
    self.req_info = null;
    self.server = server;
    return self;
}

macro ParseTask.parse_error(&self, String err_msg="")
{
    self.timeout=true;
    if(err_msg) io::printn(err_msg);
}

def ParamTuples = List(<Tuple(<String, String>)>);

fn void ParseTask.process(&self, PollEvents revents) @dynamic
{
    if (catch excuse = asionet::read_sock(self.sock, &self.buffer))
    {
        if (excuse != IoError.WOULD_BLOCK)
        {
            String err = excuse != ASock.EOF ? string::tformat("Read Socket err: %s", excuse) : "";
            self.parse_error(err);
            return;
        }
    }

    // parse req first
    if (self.req_info == null)
    {
        // try to check first line is correct
        // this assumes http 1.1, need to address later
        if (self.check_start_line)
        {
            if (!self.buffer.str_view().contains("\r\n")) return;
            String start_line = self.buffer.str_view().tsplit("\r\n")[0];
            String[] sl_parts = start_line.tsplit(" ");
            if (sl_parts.len != 3 || !sl_parts[2].temp_ascii_to_lower().contains("http/1.1"))
            {
                self.parse_error("Start line is wrong");
                return;
            }
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
            String header_l = header.temp_ascii_to_lower();
            switch
            {
                case header_l.contains("http/1.1"):
                    String[] header_parts = header.tsplit(" ");
                    req.method = header_parts[0].temp_ascii_to_upper().copy();
                    // parse query params
                    // need to handle decoding errs
                    if (header_parts[1].contains("?"))
                    {
                        String[] pp = header_parts[1].tsplit("?");
                        req.path = url::temp_decode(pp[0], PATH)!!.new_ascii_to_lower();
                        String[] params = url::temp_decode(pp[1], QUERY)!!.tsplit("&");
                        io::printn(params);
                        foreach (&p : params)
                        {
                            String[] param_parts = p.tsplit("=");
                            req.params[param_parts[0]] = param_parts[1].copy();
                        }
                    }
                    else
                    {
                        req.path = url::temp_decode(header_parts[1], PATH)!!.new_ascii_to_lower();
                    }
                case header_l.contains("content-length"):
                    req.content_length = header.tsplit(":")[1].trim().to_ulong()!!;
                case header_l.contains("content-type"):
                    req.content_type = header.tsplit(":")[1].trim().copy();
                case header_l.contains("accept-encoding"):
                    req.accept_encoding = header.tsplit(":")[1].trim().copy();
                case header_l.contains("accept"):
                    req.accept = header.tsplit(":")[1].trim().copy();
                case header_l.contains("connection"):
                    req.connection = header.tsplit(":")[1].trim().copy();
                default:
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

    if (try func = self.server.user_funcs[string::tformat("%s %s", self.req_info.method, self.req_info.path)])
    {
        task.proc.func = func;
    }
    else
    {
        List(<String>) allowed_methods;
        defer allowed_methods.free();
        foreach (key : self.server.user_funcs.tcopy_keys())
        {
            String[] parts = key.tsplit(" ");
            String[] path = parts[1].tsplit("/");
            String[] req_path = self.req_info.path.tsplit("/");
            if (path.len != req_path.len) continue;
            bool match = true;
            ParamTuples pairs;
            defer pairs.free();
            foreach (idx, part : path)
            {
                if (part == req_path[idx]) continue;
                if (part[0] == '{' && part[^1] == '}')
                {
                    pairs.push({.first=part[1..^2].tcopy(), .second=req_path[idx]});
                    continue;
                }
                match = false;
                break;
            }
            if (match)
            {
                if (parts[0] == self.req_info.method)
                {
                    // add params
                    foreach (&p : pairs) self.req_info.params[p.first.temp_ascii_to_lower()] = p.second.copy();
                    // set func
                    task.proc.func = self.server.user_funcs[key]!!;
                    break;
                }
                else
                {
                    allowed_methods.push(parts[0]);
                    pairs.clear();
                }
            }
        }

        if (task.proc.func == null)
        {
            if (allowed_methods.size)
            {
                // check supported methods and send in response as Allow header
                String allow = string::tformat("Allow: %s", string::join_new(allowed_methods.array_view(), ",", allocator::temp()));
                task.make_response(405, reason:"Method not Allowed", headers: {allow});
            }
            else
            {
                task.make_response(400, reason:"Not Found");
            }
        }
    }

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
