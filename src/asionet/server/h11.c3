module asionet::server;
import std::io;
import std::net;
import std::time;
import std::collections;


struct Http11Task (Task)
{
    Socket *sock;  // tcp connection
    bool done;
    bool timeout;
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
        PollEvents revents;
        AssociatedFunc func;
        AssociatedFunc closure;
    }
}

fn String Http11Task.name(&self) @dynamic => "h11_task";

fn void Http11Task.process(&self, PollEvents revents) @dynamic
{
    if (self.stage == 0)
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
    self.done=false;
    self.timeout=false;
    self.stage=1;
    self.buffer.new_init(256);
    self.data=null;
    self.t_born=time::now();
    self.req_info=req;
    self.server=server;
    self.proc.sock=null;
    // select user function based on parsed req
    self.proc.func=self.server.user_funcs["/ping"]!!;
    self.proc.closure=null;
    return self;
}

fn void Http11Task.free(&self) @dynamic
{
    if (self.proc.closure) @pool(){ self.proc.closure((Task)self); };
    if (self.timeout || self.req_info.connection != "keep-alive")
    {
        self.sock.destroy()!!;
        mem::free(self.sock);
    }
    self.buffer.free();
    self.req_info.free();
    mem::free(self.req_info);
}
