module c3_server;
import std::io;
import std::net;
import asionet;


fn void test_process(Task t)
{
    HttpTask *ht = (HttpTask*) t;

    // io::printfn("Req data: %s", ht.req_info.data.str_view());

    ht.buffer.clear();
    ht.buffer.append_chars("HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Length: 5\r\nAccept-Ranges: bytes\r\nConnection: keep-alive\r\n\r\nPong!");
    ht.stage = 0;
}

fn void main(String[] args)
{
    TcpServerSocket server_sock = tcp::listen("localhost", 8000, 100)!!;
    server_sock.set_reuseaddr(true)!!;

    // Maybe use a threadpool to distribute more work?

    Server server;
    server.init();
    server.listen_to(&server_sock);
    server.user_funcs["/ping"] = &test_process;

    server.run_forever();
}
