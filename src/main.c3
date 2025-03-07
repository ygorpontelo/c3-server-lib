module c3_server;
import std::io;
import std::net;
import asionet;


fn void test_process(Task t)
{
    Http11Task *h11 = (Http11Task*)t;
    // io::printfn("Req data: %s", h11.req_info.data);
    // io::printfn("Req path: %s", h11.req_info.path);
    // io::printfn("Req data: %s", h11.req_info.content_type);
    // io::printfn("Req test header: %s", h11.req_info.additional_headers["Test"]!!);

    h11.proc.cleanfn = fn (t) {
        io::printfn("Server req data: %s", t.req_info.data);
        io::printfn("Server req header: %s", t.req_info.additional_headers["Test"]!!);
    };

    h11.make_response(200, data:"Pong!", headers:{"content-type: text/plain", "test-header: testing"});
}

fn void main(String[] args)
{
    TcpServerSocket server_sock = tcp::listen("localhost", 8000, 100)!!;
    server_sock.set_reuseaddr(true)!!;

    // Maybe use a threadpool to distribute more work?

    Server server;
    server.init();
    server.listen_to(&server_sock);

    server.add_endpoint(Method.POST, "/ping", &test_process);

    server.run_forever();
}
