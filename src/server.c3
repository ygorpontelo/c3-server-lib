module async_server::aserv;
import std::io;
import std::net;
import std::time;
import std::collections;


fn void! read_sock(Socket *sock, char[] *buffer)
{
    ulong! chars;
    char[4096] in_buffer;
    bool keep_reading = true;
    DString out_str;
    // out_str.new_init();
    out_str.new_init((*buffer).len*2);
    defer {
        if (out_str.len() > 0) *buffer = out_str.str_view();
        out_str.free();
    }

    while (keep_reading)
    {
        chars = sock.read(&in_buffer)!;
        if (try chars)
        {
            if (chars > 0)
            {
                // io::printn(buffer.len);
                if (out_str.len() == 0 && buffer.len > 0) out_str.append_chars((String)*buffer);
                out_str.append_chars((String)in_buffer[..chars]);
            }
            else
            {
                keep_reading = false;
            }
        }
    }
}

fn void! write_sock(Socket *sock, char[] *buffer)
{
    ulong! chars;
    bool keep_writing = true;

    while (keep_writing)
    {
        chars = sock.write(*buffer)!;
        if (try chars)
        {
            if (chars > 0) *buffer = (*buffer)[chars..];
            keep_writing = buffer.len > 0 && chars > 0;
        }
    }
}

enum TaskType
{
    ACCEPT,
    READ,
    PROCESS,
    WRITE
}

def AssociatedFunc = fn void (Task*);
def UserFnMap = HashMap(<String, AssociatedFunc>);

struct Task
{
    Socket *sock;  // tcp connection
    TaskType tt;
    bool done;
    uint stage;
    char[] buffer;
    void *data;
    Time t_born;

    struct process
    {
        Socket *sock;  // possible other socket to watch for
        PollSubscribes event;
        AssociatedFunc func;
    }
}

fn void Task.handle_accept(&self, Server *server)
{
    TcpSocket *socket = mem::new(TcpSocket);
    socket.ai_addrlen = socket.ai_addr_storage.len;
    socket.sock = os::accept(self.sock.sock, (SockAddrPtr)&socket.ai_addr_storage, &socket.ai_addrlen);
    if (socket.sock.is_valid())
    {
        // io::printn("socket is valid!");
        socket.sock.set_non_blocking(true)!!;
        // socket.set_reuseaddr(true)!!;
        server.tasks.push(
            {
                .sock=socket,
                .tt=TaskType.READ,
                .done=false,
                .stage=0,
                .buffer="",
                .data=null,
                .t_born=time::now(),
                .process.sock=null,
                .process.func=null,
            }
        );
    }
}

fn void Task.handle_read(&self, UserFnMap *user_funcs)
{   
    if (catch excuse = read_sock(self.sock, &self.buffer))
    {
        if (excuse != IoError.WOULD_BLOCK)
        {
            self.done = true;
            // log error
            io::printfn("Socket error: %s", excuse);
            return;
        }
    }

    String[] parts = ((String)self.buffer).split("\r\n\r\n");
    defer mem::free(parts);
    String[] parts2 = parts[0].split("\r\n");
    defer mem::free(parts2);

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
    self.tt = TaskType.PROCESS;
    // select path function
    self.process.func = (*user_funcs)["/ping"]!!;
    // free parsed data
}

fn void Task.handle_write(&self)
{
    if (catch excuse = write_sock(self.sock, &self.buffer))
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

struct Server
{
    List(<Task>) tasks;
    UserFnMap user_funcs;
    
}

fn void Server.listen_to(&self, TcpServerSocket *server_sock)
{
    self.tasks.new_init();
    self.user_funcs.new_init();
    self.tasks.push({.sock=server_sock, .tt=TaskType.ACCEPT});
}

fn void Server.poll_tasks(&self)
{
    List(<Poll>) polling;
    defer polling.free();
    foreach (&task : self.tasks)
    {
        // not io bound yet
        if (task.tt == TaskType.PROCESS && task.process.sock==null) task.process.func(task);

        if (task.tt == TaskType.PROCESS)
        {
            if (task.process.sock == null)
            {
                // ignore task for now
                polling.push({.socket=-1});
            }
            else
            {
                polling.push({.socket=task.process.sock.sock, .events=task.process.event});
            }
        }
        else
        {
            polling.push(
                {
                    .socket=task.sock.sock,
                    .events=task.tt == TaskType.WRITE ? net::SUBSCRIBE_ANY_WRITE : net::SUBSCRIBE_ANY_READ,
                }
            );
        }
    }
    ulong check = 0;
    ulong evs = net::poll(polling.array_view(), time::SEC)!!;
    if (evs > 0)
    {
        foreach (idx, &poll : polling)
        {
            if (poll.socket != -1 && (ushort)poll.revents & (ushort)poll.events)
            {
                check++;
                Task *t = &self.tasks[idx];
                switch (t.tt)
                {
                    case TaskType.ACCEPT:
                        t.handle_accept(self);
                    case TaskType.READ:
                        t.handle_read(&self.user_funcs);
                    case TaskType.PROCESS:
                        t.process.func(t);
                    case TaskType.WRITE:
                        t.handle_write();
                }
            }
            if (check == evs) break;
        }
    }
}

fn void Server.clear_done(&self)
{
    ulong i = 1;  // skip accept task
    while (i<self.tasks.size)
    {
        // timeout of 5s
        if (self.tasks[i].done || time::now().diff_sec(self.tasks[i].t_born) >= 5)
        {
            // io::printn("IS DONE");
            self.tasks[i].sock.destroy()!!;
            mem::free(self.tasks[i].sock);
            self.tasks.remove_at(i);
        }
        else
        {
            i++;
        }
    }
}

fn void Server.run_forever(&self)
{
    while (self.tasks.size > 0)
    {
        self.poll_tasks();
        self.clear_done();
    }
}
