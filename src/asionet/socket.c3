module asionet;
import std::net;

fn void! read_sock(Socket *sock, DString *buffer)
{
    ulong chars;
    char[4096] in_buffer;
    while (chars = sock.read(&in_buffer)!) buffer.append_chars((String)in_buffer[:chars]);
}

fn void! write_sock(Socket *sock, DString *buffer)
{
    ulong chars;
    while (buffer.len() > 0 && (chars = sock.write(buffer.str_view())!)) buffer.delete_range(0, chars-1);
}
