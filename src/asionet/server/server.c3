module asionet::server;
import std::io;
import std::net;
import std::time;
import std::collections;


struct TcpAcceptTask (Task)
{
    Server *server;
}

fn String TcpAcceptTask.name(&self) @dynamic => "tcp_accept_task";

fn void TcpAcceptTask.process(&self) @dynamic
{
    TcpSocket *socket = mem::new(TcpSocket);
    socket.ai_addrlen = socket.ai_addr_storage.len;
    socket.sock = os::accept(self.server.sock.sock, (SockAddrPtr)&socket.ai_addr_storage, &socket.ai_addrlen);
    if (socket.sock.is_valid())
    {
        // io::printn("socket is valid!");
        socket.sock.set_non_blocking(true)!!;
        socket.set_reuseaddr(true)!!;
        ParseTask *t = mem::new(ParseTask);
        self.server.tasks.push((Task)t.new_init(socket, self.server));
    }
    else
    {
        mem::free(socket);
    }
}

fn Poll TcpAcceptTask.get_poll(&self) @dynamic
{
    Poll poll;
    poll.socket = self.server.sock.sock;
    poll.events = net::SUBSCRIBE_ANY_READ;
    return poll;
}

fn bool TcpAcceptTask.is_done(&self) @dynamic
{
    return false;
}

fn void TcpAcceptTask.free(&self) @dynamic
{
    return;
}

// post /ping http/1.1
// host: localhost:8000
// accept: */*
// accept-encoding: gzip, deflate, br
// connection: keep-alive
// user-agent: python-httpx/0.27.0

struct ParsedReq
{
    String method;
    String path;
    String data;
    String host;
    String accept;
    String accept_encoding;
    String connection;
    String user_agent;
    String content_type;
    ulong content_length;
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
    self.host.free();
    self.accept.free();
    self.accept_encoding.free();
    self.connection.free();
    self.user_agent.free();
    self.content_type.free();
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

                case header.contains("host"):
                    req.host = header.tsplit(":")[1].trim().copy();

                case header.contains("connection"):
                    req.connection = header.tsplit(":")[1].trim().copy();

                case header.contains("user-agent"):
                    req.user_agent = header.tsplit(":")[1].trim().copy();

                default:
                    io::printfn("Unknown header %s", header);
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


def UserFnMap = HashMap(<String, AssociatedFunc>);
def AssociatedFunc = fn void (Task);

struct Server
{
    TcpServerSocket *sock;
    TaskLoop tasks;
    UserFnMap user_funcs;
    uint timeout;
}

fn Server* Server.init(&self, usz initial_task_capacity=1024, uint timeout=10)
{
    self.sock=null;
    self.timeout=timeout;
    self.tasks.new_init(initial_task_capacity, time::SEC);
    self.user_funcs.new_init();
    return self;
}

fn void Server.listen_to(&self, TcpServerSocket *server_sock)
{
    self.sock = server_sock;
    TcpAcceptTask *at = mem::new(TcpAcceptTask);
    at.server = self;
    self.tasks.push((Task)at);
}

fn void Server.run_forever(&self)
{
    // watch for signals in future
    self.tasks.run_until_complete();
}
