module asionet;
import std::net;
import std::time;
import std::collections;


interface Task
{
    fn String name();
    fn void process();
    fn bool is_done();
    fn Poll get_poll();
    fn void free();
}

def TaskLoop = List(<Task>);

fn void TaskLoop.poll_tasks(&self, Duration poll_duration)
{
    List(<Poll>) polling;
    polling.new_init(self.size);
    defer polling.free();
    foreach (&task : self) polling.push(task.get_poll());
    ulong check = 0;
    ulong evs = net::poll(polling.array_view(), poll_duration)!!;
    if (evs > 0)
    {
        foreach (idx, &poll : polling)
        {
            if (poll.socket != -1 && (ushort)poll.revents & (ushort)poll.events)
            {
                check++;
                @pool()
                {
                    self.get_ref(idx).process();
                };
            }
            if (check == evs) break;
        }
    }
}

fn void TaskLoop.clear_done(&self)
{
    ulong i = 0;
    while (i<self.size)
    {
        if (self.get_ref(i).is_done())
        {
            self.get_ref(i).free();
            mem::free(*self.get_ref(i));
            self.remove_at(i);
        }
        else
        {
            i++;
        }
    }
}

fn void TaskLoop.loop_forever(&self, Duration poll_duration)
{
    while (self.size > 0)
    {
        self.poll_tasks(poll_duration);
        self.clear_done();
    }
}
