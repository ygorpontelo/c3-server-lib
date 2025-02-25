module asionet::server;
import std::io;
import std::net;
import std::time;
import std::collections;


struct TcpAcceptTask (Task)
{
    Server *server;
}

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

fn String TcpAcceptTask.name(&self) @dynamic
{
    return "tcpaccepttask";
}

// post /ping http/1.1
// host: localhost:8000
// accept: */*
// accept-encoding: gzip, deflate, br
// connection: keep-alive
// user-agent: python-httpx/0.27.0

struct ParsedReq
{
    DString method;
    DString path;
    DString data;
    DString host;
    DString accept;
    DString accept_encoding;
    DString connection;
    DString user_agent;
    DString content_type;
    ulong content_length;
}

fn void ParsedReq.init(&self)
{
    self.accept.append_chars("*/*");
    self.accept_encoding.append_chars("gzip, deflate, br");
    self.connection.append_chars("keep-alive");
    self.content_type.append_chars("text/plain; charset=utf-8");
    self.content_length = 0;
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
    DString buffer;
    Time t_born;
    ParsedReq *req_info;
    Server *server;
}

fn ParseTask* ParseTask.new_init(&self, Socket* sock, Server *server)
{
    self.sock = sock;
    self.done = false;
    self.timeout = false;
    self.buffer.new_init(256);
    self.t_born=time::now();
    self.req_info = null;
    self.server = server;
    return self;
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
        ParsedReq *req = mem::new(ParsedReq);
        req.init();
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
                case header.contains("content-length"):
                    req.content_length = header.tsplit(":")[1].trim().to_ulong()!!;
                // case header.contains("http/1.1"):
                //     ...
                // case header.contains("host"):
                //     ...
                // case header.contains("accept-encoding"):
                //     ...
                // case header.contains("accept"):
                //     ...
                // case header.contains("connection"):
                //     ...
                // case header.contains("user-agent"):
                //     ...
                default:
                    io::printfn("Unknown header %s", header);
            }
        }
        self.req_info = req;
    }

    // check how much data needs reading
    if (self.buffer.len() < self.req_info.content_length) return;

    // if all expected data is read then format data if any
    self.req_info.data.append_string(self.buffer);

    // given parsed req, select task (only http for now)
    HttpTask *task = mem::new(HttpTask);
    task.new_init(self.sock, self.req_info, self.server);
    self.server.tasks.push((Task)task);

    self.done = self.req_info.connection.str_view() != "keep-alive";
    self.req_info = null;
    self.buffer.clear();
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

fn String ParseTask.name(&self) @dynamic
{
    return "parsetask";
}

struct HttpTask (Task)
{
    Socket *sock;  // tcp connection
    bool done;
    uint stage;
    DString buffer;
    void *data;  // possible user data to store
    Time t_born;
    ParsedReq *req_info;
    Server *server;

    struct proc
    {
        Socket *sock;  // possible other socket to watch for
        PollSubscribes event;
        AssociatedFunc func;
    }
}

fn void HttpTask.process(&self) @dynamic
{
    switch (self.stage)
    {
        case 0:
            if (catch excuse = asionet::write_sock(self.sock, &self.buffer))
            {
                if (excuse != IoError.WOULD_BLOCK)
                {
                    self.done = true;
                    // log error
                    io::printfn("Socket error: %s", excuse);
                    return;
                }
            }
            // if all data was written then set done
            self.done = self.buffer.len() == 0;
        default:
            self.proc.func((Task)self);
    }
}

fn Poll HttpTask.get_poll(&self) @dynamic
{
    Poll poll;

    // not io bound yet
    if (self.stage > 0 && self.proc.sock==null) @pool(){ self.proc.func((Task)self); };

    if (self.stage > 0)
    {
        if (self.proc.sock==null)
        {
            // ignore task for now
            poll.socket = -1;
        }
        else
        {
            poll.socket = self.proc.sock.sock;
            poll.events = self.proc.event;
        }
    }
    else
    {
        poll.socket = self.sock.sock;
        poll.events = net::SUBSCRIBE_ANY_WRITE;
    }
    return poll;
}

fn bool HttpTask.is_done(&self) @dynamic
{
    return self.done || time::now().diff_sec(self.t_born) >= self.server.timeout;
}

fn HttpTask* HttpTask.new_init(&self, Socket* socket, ParsedReq *req, Server *server)
{
    self.sock=socket;
    self.done=false;
    self.stage=1;
    self.buffer.new_init(256);
    self.data=null;
    self.t_born=time::now();
    self.req_info=req;
    self.server=server;
    self.proc.sock=null;
    // select user function based on parsed req
    self.proc.func=self.server.user_funcs["/ping"]!!;
    return self;
}

fn void HttpTask.free(&self) @dynamic
{
    if (self.req_info.connection.str_view() != "keep-alive")
    {
        self.sock.destroy()!!;
        mem::free(self.sock);
    }
    self.buffer.free();
    self.req_info.free();
    mem::free(self.req_info);
}

fn String HttpTask.name(&self) @dynamic
{
    return "httptask";
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

fn Server* Server.init(&self, usz initial_task_capacity=1024, uint timeout=5)
{
    self.sock=null;
    self.timeout=timeout;
    self.tasks.new_init(initial_task_capacity);
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
    self.tasks.loop_forever(time::SEC);
}
