module c3_server;
import std::io;
import std::net;
import async_server;


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
    server.user_funcs["/ping"] = &test_process;

    server.run_forever();
}
