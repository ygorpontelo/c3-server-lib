module asionet;
import std::net;
import std::time;
import std::collections;


interface Task
{
    fn String name();
    fn void process(any...);
    fn bool is_done();
    fn Poll get_poll();
    fn void free();
}

def TaskLoop = List(<Task>);

fn void TaskLoop.poll_tasks(&self, Duration poll_duration, any... proc_args)
{
    List(<Poll>) polling;
    defer polling.free();
    foreach (&task : self)
    {
        polling.push(task.get_poll());
    }
    ulong check = 0;
    ulong evs = net::poll(polling.array_view(), poll_duration)!!;
    if (evs > 0)
    {
        foreach (idx, &poll : polling)
        {
            if (poll.socket != -1 && (ushort)poll.revents & (ushort)poll.events)
            {
                check++;
                self.get_ref(idx).process(...proc_args);
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
            self.remove_at(i);
        }
        else
        {
            i++;
        }
    }
}

fn void TaskLoop.loop_forever(&self, Duration poll_duration, any... proc_args)
{
    while (self.size > 0)
    {
        self.poll_tasks(poll_duration, ...proc_args);
        self.clear_done();
    }
}
