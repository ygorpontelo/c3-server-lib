module asionet;
import std::net;


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
