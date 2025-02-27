module asionet::server::h11;
import std::io;
import std::net;
import std::time;
import std::collections;


struct Http11Task (Task)
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

fn String Http11Task.name(&self) @dynamic => "h11_task";

fn void Http11Task.process(&self) @dynamic
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

            if (self.done && self.req_info.connection == "keep-alive")
            {
                ParseTask *t = mem::new(ParseTask);
                self.server.tasks.push((Task)t.new_init(self.sock, self.server));
            }
        default:
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
    return self.done || time::now().diff_sec(self.t_born) >= self.server.timeout;
}

fn Http11Task* Http11Task.new_init(&self, Socket* socket, ParsedReq *req, Server *server)
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

fn void Http11Task.free(&self) @dynamic
{
    if (self.req_info.connection != "keep-alive")
    {
        self.sock.destroy()!!;
        mem::free(self.sock);
    }
    self.buffer.free();
    self.req_info.free();
    mem::free(self.req_info);
}
