module c3_server;
import std::io;
import std::collections;
import std::net;


fn void read_sock(Socket *sock, char[] *buffer)
{
    ulong! chars;
    char[4096] in_buffer;
    bool keep_reading = true;
    bool init_data = false;
    DString out_str;
    defer if (init_data) out_str.free();

    while (keep_reading)
    {
        chars = sock.read(&in_buffer);

        if (catch chars)
        {
            case IoError.WOULD_BLOCK:
                keep_reading = false;
            default:
                chars!!;
        }

        if (try chars)
        {
            if (chars > 0)
            {
                if (!init_data)
                {
                    out_str = dstring::new((String)*buffer);
                    init_data = true;
                }
                out_str.append_chars((String)in_buffer[..chars]);
            }
            else
            {
                keep_reading = false;
            }
        }
    }
    if (init_data) *buffer = out_str.str_view();
}

fn void write_sock(Socket *sock, char[] *buffer)
{
    ulong! chars;
    bool keep_writing = true;

    while (keep_writing)
    {
        chars = sock.write(*buffer);

        if (catch chars)
        {
            case IoError.WOULD_BLOCK:
                keep_writing = false;
            default:
                chars!!;
        }

        if (try chars)
        {
            *buffer = (*buffer)[chars..];
            keep_writing = chars > 0 && (*buffer).len > 0;
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

struct Task
{
    Socket *sock;  // tcp connection
    TaskType tt;
    bool done;
    uint stage;
    char[] buffer;
    void *data;

    struct process{
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
                .process.sock=null,
                .process.func=null
            }
        );
    }
}

fn void Task.handle_read(&self)
{   
    read_sock(self.sock, &self.buffer);

    // io::printfn("READ BUFFER: %s", (String)self.buffer);
    // parse and check how much data needs reading
    // save in struct in data

    // if all expected data is read then set to process
    if (((String)self.buffer).contains("Ping!"))
    {
        // io::printn((String)self.buffer);
        self.tt = TaskType.PROCESS;
        // select path function
        self.process.func = &test_process;
        // free parsed data
    }
}

fn void Task.handle_write(&self)
{
    write_sock(self.sock, &self.buffer);

    // if all data was written then set done
    self.done = self.buffer.len == 0;
}

struct Server
{
    List(<Task>) tasks;
}

fn void Server.listen_to(&self, TcpServerSocket *server_sock)
{
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
                    .events=task.tt == TaskType.WRITE ? net::SUBSCRIBE_ANY_WRITE : net::SUBSCRIBE_ANY_READ
                }
            );
        }
    }
    ulong check = 0;
    ulong evs = net::poll(polling.array_view(), net::POLL_FOREVER)!!;
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
                    t.handle_read();
                case TaskType.PROCESS:
                    t.process.func(t);
                case TaskType.WRITE:
                    t.handle_write();
            }
        }
        if (check == evs) break;
    }
}

fn void Server.clear_done(&self)
{
    ulong i = 0;
    while (i<self.tasks.size)
    {
        if (self.tasks[i].done)
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

fn void test_process(Task *t)
{
    // switch (t.stage)
    // {
    //     case 0:
    //         t.buffer = "HTTP/1.1 200 OK\nContent-Type: text/html\nContent-Length: 5\nAccept-Ranges: bytes\nConnection: close\n\nPong!";
    //         t.tt = TaskType.WRITE;
    // }
    t.buffer = "HTTP/1.1 200 OK\nContent-Type: text/html\nContent-Length: 5\nAccept-Ranges: bytes\nConnection: close\n\nPong!";
    t.tt = TaskType.WRITE;
}

fn void main(String[] args)
{
    TcpServerSocket server_sock = tcp::listen("localhost", 8000, 100)!!;

    // Maybe use a threadpool to distribute more work?

    Server server;
    server.listen_to(&server_sock);

    server.run_forever();
}
