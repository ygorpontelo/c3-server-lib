module asionet;
import std::net;
import std::time;
import std::collections;


interface Task
{
    fn String name();
    fn void process(PollEvents);
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
            if ((ushort)poll.revents)
            {
                check++;
                @pool()
                {
                    self.tasks[idx].process(poll.revents);
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

fn usz TaskLoop.size(&self) @inline => self.tasks.size;

fn void TaskLoop.run_iteration(&self)
{
    if (self.size() == 0) return;
    self.poll_tasks();
    self.clear_done();
}

fn void TaskLoop.run_until_complete(&self)
{
    while (self.size() > 0) self.run_iteration();
}
