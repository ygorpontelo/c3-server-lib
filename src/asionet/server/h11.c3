module asionet::server;
import std::io;
import std::net;
import std::time;
import std::collections;


def CleanFunc = fn void (Http11Task*);

struct Http11Task (Task)
{
    Socket *sock;               // tcp connection
    bool done;
    bool timeout;
    uint stage;                 // allows for 
    DString buffer;
    void *data;                 // possible user data to store
    Time t_born;
    ParsedReq *req_info;
    Server *server;

    struct proc
    {
        Socket *sock;           // possible other socket to watch for
        PollSubscribes event;   // event to watch
        PollEvents revents;     // events that occurred, either tcp conn or proc.sock
        AssociatedFunc func;    // user fn to handle req
        CleanFunc cleanfn;      // lambda to run when freed, useful for correct cleanups, accounts timeouts
    }
}

fn String Http11Task.name(&self) @dynamic => "h11_task";

fn void Http11Task.process(&self, PollEvents revents) @dynamic
{
    if (self.stage == 0)  // zero reserved for response
    {
        if (catch excuse = asionet::write_sock(self.sock, &self.buffer))
        {
            if (excuse != IoError.WOULD_BLOCK)
            {
                self.timeout=true;
                // log error
                io::printfn("Write Socket error: %s", excuse);
                return;
            }
        }
        // if all data was written then set done
        self.done = self.buffer.len() == 0;

        if (self.done && self.req_info.connection == "keep-alive")
        {
            ParseTask *t = mem::new(ParseTask);
            self.server.tasks.push((Task)t.new_init(self.sock, self.server));
        }
    }
    else
    {
        self.proc.revents = revents;
        self.proc.func((Task)self);
    }
}

fn Poll Http11Task.get_poll(&self) @dynamic
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

fn bool Http11Task.is_done(&self) @dynamic
{
    self.timeout = self.timeout || (!self.done && time::now().diff_sec(self.t_born) >= self.server.timeout);
    return self.done || self.timeout;
}

fn Http11Task* Http11Task.new_init(&self, Socket* socket, ParsedReq *req, Server *server)
{
    self.sock=socket;
    self.stage=1;
    self.buffer.init(mem, capacity:256);
    self.t_born=time::now();
    self.req_info=req;
    self.server=server;
    return self;
}

fn void Http11Task.free(&self) @dynamic
{
    if (self.proc.cleanfn) @pool(){ self.proc.cleanfn(self); };
    if (self.timeout || self.req_info.connection != "keep-alive")
    {
        self.sock.destroy()!!;
        mem::free(self.sock);
    }
    self.buffer.free();
    self.req_info.free();
    mem::free(self.req_info);
}

macro Http11Task.watch_socket(&self, Socket *sock, PollSubscribes event)
{
    self.proc.sock = sock;
    self.proc.event = event;
}

fn void Http11Task.make_response(
    &self,
    uint status_code,
    String reason="OK",
    String conn="keep-alive",
    String data="",
    String[] headers={}
)
{
    self.stage = 0;
    self.buffer.clear();
    if (headers.len)
    {
        String joined_headers = string::join_new(headers, "\r\n");
        defer joined_headers.free();
        self.buffer.append_chars(
            string::tformat(
                "HTTP/1.1 %d %s\r\ncontent-length: %d\r\nconnection: %s\r\n%s\r\n\r\n%s",
                status_code,
                reason,
                data.len,
                conn,
                joined_headers,
                data
            )
        );
    }
    else
    {
        self.buffer.append_chars(
            string::tformat(
                "HTTP/1.1 %d %s\r\ncontent-length: %d\r\nconnection: %s\r\n\r\n%s",
                status_code,
                reason,
                data.len,
                conn,
                data
            )
        );
    }
}
