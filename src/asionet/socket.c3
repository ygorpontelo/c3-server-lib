module asionet;
import std::net;


fn void! read_sock(Socket *sock, DString *buffer)
{
    ulong! chars;
    char[4096] in_buffer;
    bool keep_reading = true;

    while (keep_reading)
    {
        chars = sock.read(&in_buffer)!;
        if (try chars)
        {
            if (chars > 0)
            {
                buffer.append_chars((String)in_buffer[..chars]);
            }
            else
            {
                keep_reading = false;
            }
        }
    }
}

fn void! write_sock(Socket *sock, DString *buffer)
{
    ulong! chars;
    bool keep_writing = true;

    while (keep_writing)
    {
        chars = sock.write(buffer.str_view())!;
        if (try chars)
        {
            if (chars > 0) buffer.delete_range(0, chars-1);
            keep_writing = buffer.len() > 0 && chars > 0;
        }
    }
}
