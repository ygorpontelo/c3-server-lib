module asionet;
import std::io;
import std::net;


fn void? read_sock(Socket *sock, DString *buffer)
{
    ulong chars;
    char[1024] in_buffer;
    while (chars = sock.read(&in_buffer)!) buffer.append_chars((String)in_buffer[:chars]);
    if (chars == 0) return io::EOF?;
}

fn void? write_sock(Socket *sock, DString *buffer)
{
    ulong chars;
    while (buffer.len() > 0 && (chars = sock.write(buffer.str_view())!)) buffer.delete_range(0, chars-1);
    if (chars == 0) return io::EOF?;
}
