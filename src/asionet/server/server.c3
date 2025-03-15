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

fn void TcpAcceptTask.process(&self, PollEvents revents) @dynamic
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

fn void TcpAcceptTask.free(&self) @dynamic {}


// ------ Server itself

def UserFnMap = HashMap(<String, AssociatedFunc>);
def AssociatedFunc = fn void (Task);

enum Method : char (inline String s)
{
    GET = "GET",
    POST = "POST",
    PUT = "PUT",
    PATCH = "PATCH",
    DELETE = "DELETE",
    WEBSOCKET = "WEBSOCKET"
}

struct Server
{
    TcpServerSocket *sock;
    TaskLoop tasks;
    UserFnMap user_funcs;
    List(<String>) ordered_paths;
    uint timeout;
}

fn Server* Server.init(&self, usz initial_task_capacity=1024, uint timeout=5)
{
    self.sock=null;
    self.timeout=timeout;
    self.tasks.new_init(initial_task_capacity, time::SEC);
    self.user_funcs.init(mem);
    return self;
}

fn void Server.free(&self)
{
    self.sock.destroy()!!;
    mem::free(self.sock);
    self.tasks.free();
    self.user_funcs.free();
    foreach (&s : self.ordered_paths) s.free();
    self.ordered_paths.free();
}

fn void Server.listen_to(&self, TcpServerSocket *server_sock)
{
    self.sock = server_sock;
    TcpAcceptTask *at = mem::new(TcpAcceptTask);
    at.server = self;
    self.tasks.push((Task)at);
}

fn bool Server.add_endpoint(&self, Method met, String endpoint, AssociatedFunc func)
{
    String key = string::new_format("%s %s", met, endpoint);
    self.ordered_paths.push(key);
    return self.user_funcs[key] = func;
}

fn void Server.run_forever(&self)
{
    bool run = true;
    while (run)
    {
        // watch for signals in future
        // make graceful shutdown
        run = self.tasks.run_iteration();
    }
    // possible cleanups
}
