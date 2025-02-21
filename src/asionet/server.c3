module asionet::server;
import std::io;
import std::net;
import std::time;
import std::collections;


struct HttpTask (Task)
{
    Socket *sock;  // tcp connection
    bool done;
    uint stage;
    char[] buffer;
    void *data;
    Time t_born;

    struct proc
    {
        Socket *sock;  // possible other socket to watch for
        PollSubscribes event;
        AssociatedFunc func;
    }
}

fn void HttpTask.process(&self, any... proc_args) @dynamic
{
    Server *server = anycast(proc_args[0], Server)!!;
    switch (self.stage)
    {
        case 0:
            if (catch excuse = asionet::read_sock(self.sock, &self.buffer))
            {
                if (excuse != IoError.WOULD_BLOCK)
                {
                    self.done = true;
                    // log error
                    io::printfn("Socket error: %s", excuse);
                    return;
                }
            }

            String[] parts = ((String)self.buffer).tsplit("\r\n\r\n");
            String[] parts2 = parts[0].tsplit("\r\n");

            // io::printn(parts2);
            foreach (s : parts2)
            {
                // parse and check how much data needs reading
                // save parsing in data
                if (s.contains("Content-Length: "))
                {
                    usz i = s.index_of("Content-Length: ")!! + 16;
                    long size = s[i..].to_long()!!;
                    if (parts[1].len < size) return;
                }
            }

            // if all expected data is read then set to process
            // io::printfn("READ BUFFER: %s", (String)self.buffer);

            // io::printn((String)self.buffer);
            self.stage = 1;
            // select path function
            self.proc.func = server.user_funcs["/ping"]!!;
            // free parsed data
        case 1:
            self.proc.func((Task)self);
        case 2:
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
            self.done = self.buffer.len == 0;
    }
}

fn Poll HttpTask.get_poll(&self) @dynamic
{
    Poll poll;

    // not io bound yet
    if (self.stage == 1 && self.proc.sock==null) @pool(){ self.proc.func((Task)self); };

    if (self.stage == 1)
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
        poll.events = self.stage == 2 ? net::SUBSCRIBE_ANY_WRITE : net::SUBSCRIBE_ANY_READ;
    }
    return poll;
}

fn bool HttpTask.is_done(&self) @dynamic
{
    return self.done || time::now().diff_sec(self.t_born) >= 5;
}

fn void HttpTask.free(&self) @dynamic
{
    self.sock.destroy()!!;
    mem::free(self.sock);
    mem::free(self);
}

fn String HttpTask.name(&self) @dynamic
{
    return "httptask";
}

struct AcceptTask (Task)
{
    TcpServerSocket *sock;
}

fn void AcceptTask.process(&self, any... proc_args) @dynamic
{
    Server *server = anycast(proc_args[0], Server)!!;
    TcpSocket *socket = mem::new(TcpSocket);
    socket.ai_addrlen = socket.ai_addr_storage.len;
    socket.sock = os::accept(self.sock.sock, (SockAddrPtr)&socket.ai_addr_storage, &socket.ai_addrlen);
    if (socket.sock.is_valid())
    {
        // io::printn("socket is valid!");
        socket.sock.set_non_blocking(true)!!;
        // socket.set_reuseaddr(true)!!;
        HttpTask *t = mem::new(HttpTask);
        t.sock=socket;
        t.done=false;
        t.stage=0;
        t.buffer="";
        t.data=null;
        t.t_born=time::now();
        t.proc.sock=null;
        t.proc.func=null;
        server.tasks.push((Task)t);
    }
}

fn Poll AcceptTask.get_poll(&self) @dynamic
{
    Poll poll;
    poll.socket = self.sock.sock;
    poll.events = net::SUBSCRIBE_ANY_READ;
    return poll;
}

fn bool AcceptTask.is_done(&self) @dynamic
{
    return false;
}

fn void AcceptTask.free(&self) @dynamic
{
    mem::free(self);
}

fn String AcceptTask.name(&self) @dynamic
{
    return "accepttask";
}

def UserFnMap = HashMap(<String, AssociatedFunc>);
def AssociatedFunc = fn void (Task);

struct Server
{
    TaskLoop tasks;
    UserFnMap user_funcs;
}

fn Server* Server.init(&self)
{
    self.tasks.new_init();
    self.user_funcs.new_init();
    return self;
}

fn void Server.listen_to(&self, TcpServerSocket *server_sock)
{
    AcceptTask *at = mem::new(AcceptTask);
    // AcceptTask at;
    at.sock = server_sock;
    self.tasks.push((Task)at);
}

fn void Server.run_forever(&self)
{
    // watch for signals in future
    self.tasks.loop_forever(time::SEC, self);
}
