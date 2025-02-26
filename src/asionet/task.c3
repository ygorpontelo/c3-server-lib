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

struct TaskLoop
{
    List(<Task>) tasks;
    Duration poll_duration;
}

fn void TaskLoop.new_init(&self, usz initial_task_capacity, Duration poll_duration)
{
    self.poll_duration = poll_duration;
    self.tasks.new_init(initial_task_capacity);
}

fn void TaskLoop.push(&self, Task t) => self.tasks.push(t);

fn void TaskLoop.poll_tasks(&self)
{
    List(<Poll>) polling;
    polling.new_init(self.tasks.size);
    defer polling.free();
    foreach (&task : self.tasks) polling.push(task.get_poll());
    ulong check = 0;
    ulong evs = net::poll(polling.array_view(), self.poll_duration)!!;
    if (evs > 0)
    {
        foreach (idx, &poll : polling)
        {
            if (poll.socket != -1 && (ushort)poll.revents & (ushort)poll.events)
            {
                check++;
                @pool()
                {
                    self.tasks[idx].process();
                };
            }
            if (check == evs) break;
        }
    }
}

fn void TaskLoop.clear_done(&self)
{
    ulong i = 0;
    while (i<self.tasks.size)
    {
        if (self.tasks[i].is_done())
        {
            self.tasks[i].free();
            mem::free(self.tasks[i]);
            self.tasks.remove_at(i);
        }
        else
        {
            i++;
        }
    }
}

fn void TaskLoop.run_until_complete(&self)
{
    while (self.tasks.size > 0)
    {
        self.poll_tasks();
        self.clear_done();
    }
}
