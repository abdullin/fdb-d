module fdb.future;

import
    core.sync.semaphore,
    core.thread,
    std.algorithm,
    std.array,
    std.conv,
    std.exception,
    std.parallelism,
    std.traits;

import
    fdb.error,
    fdb.fdb_c,
    fdb.range,
    fdb.rangeinfo,
    fdb.transaction;

alias CompletionCallback = void delegate(Exception ex);

shared class FutureBase(V)
{
    static if (!is(V == void))
    {
        protected V _value;
        @property auto value()
        {
            enforce(exception is null, cast(Exception)exception);
            return _value;
        }
    }

    protected Exception _exception;
    @property auto exception()
    {
        return _exception;
    }

    abstract shared FutureBase!V wait();
}

shared class FunctionFuture(alias fun, Args...) : FutureBase!(ReturnType!fun)
{
    alias V = ReturnType!fun;
    alias T = Task!(fun, ParameterTypeTuple!fun) *;
    private T t;

    private Semaphore futureSemaphore;

    this(Args args)
    {
        futureSemaphore = cast(shared)new Semaphore;

        t = cast(shared)task!fun(
            args,
            (Exception ex)
            {
                notify;
            });
        taskPool.put(cast(T)t);
    }

    void notify()
    {
        (cast(Semaphore)futureSemaphore).notify;
    }

    override shared FutureBase!V wait()
    {
        (cast(Semaphore)futureSemaphore).wait;

        try
        {
            static if (!is(V == void))
                _value = (cast(T)t).yieldForce;
            else
                (cast(T)t).yieldForce;
        }
        catch (Exception ex)
        {
            _exception = cast(shared)ex;
        }

        return cast(FutureBase!V) this;
    }
}

shared class BasicFuture(V) : FutureBase!V
{
    private Semaphore futureSemaphore;

    this()
    {
        futureSemaphore = cast(shared)new Semaphore;
    }

    static if (!is(V == void))
    {
        void notify(Exception ex, ref V value)
        {
            _exception  = cast(shared)ex;
            _value      = cast(shared)value;

            (cast(Semaphore)futureSemaphore).notify;
        }
    }
    else
    {
        void notify(Exception ex)
        {
            _exception  = cast(shared)ex;

            (cast(Semaphore)futureSemaphore).notify;
        }
    }

    override shared FutureBase!V wait()
    {
        (cast(Semaphore)futureSemaphore).wait;
        return cast(FutureBase!V)this;
    }
}

alias FutureCallback(V) = void delegate(Exception ex, V value);

shared class FDBFutureBase(C, V) : FutureBase!V
{
    private alias SF = shared FDBFutureBase!(C, V);
    private alias SH = shared FutureHandle;
    private alias SE = shared fdb_error_t;

    private FutureHandle        future;
    private const Transaction   tr;
    private C                   callbackFunc;

    this(FutureHandle future, const Transaction tr)
    {
        this.future = cast(shared)future;
        this.tr     = cast(shared)tr;
    }

    ~this()
    {
        destroy;
    }

    void destroy()
    {
        if (future)
        {
            // NB : Also releases the memory returned by get functions
            fdb_future_destroy(cast(FutureHandle)future);
            future = null;
        }
    }

    auto start(C callbackFunc)
    {
        this.callbackFunc = cast(shared)callbackFunc;
        const auto err = fdb_future_set_callback(
            cast(FutureHandle) future,
            cast(FDBCallback)  &futureReady,
            cast(void*)        this);
        enforceError(err);

        return this;
    }

    shared FutureBase!V wait(C callbackFunc)
    {
        if (callbackFunc)
            start(callbackFunc);

        shared err = fdb_future_block_until_ready(cast(FutureHandle)future);
        if (err != FDBError.NONE)
        {
            _exception = cast(shared)err.toException;
            return cast(FutureBase!V)this;
        }

        static if (!is(V == void))
            _value  = cast(shared)extractValue(future, err);

        _exception  = cast(shared)err.toException;

        return cast(FutureBase!V)this;
    }

    override shared FutureBase!V wait()
    {
        return wait(null);
    }

    extern(C) static void futureReady(SH f, SF thiz)
    {
        thread_attachThis;
        auto futureTask = task!worker(f, thiz);
        // or futureTask.executeInNewThread?
        taskPool.put(futureTask);
    }

    static void worker(SH f, SF thiz)
    {
        scope (exit) delete thiz;

        shared fdb_error_t err;
        with (thiz)
        {
            static if (is(V == void))
            {
                extractValue(cast(shared)f, err);
                if (callbackFunc)
                    (cast(C)callbackFunc)(err.toException);
            }
            else
            {
                auto value = extractValue(cast(shared)f, err);
                if (callbackFunc)
                    (cast(C)callbackFunc)(err.toException, value);
            }
        }
    }

    abstract V extractValue(SH future, out SE err);
}

private mixin template FutureCtor(C)
{
    this(FutureHandle future, const Transaction tr = null)
    {
        super(future, tr);
    }
}

alias ValueFutureCallback = FutureCallback!Value;

shared class ValueFuture : FDBFutureBase!(ValueFutureCallback, Value)
{
    mixin FutureCtor!ValueFutureCallback;

    private alias PValue = ubyte *;

    override Value extractValue(SH future, out SE err)
    {
        PValue value;
        int    valueLength,
               valuePresent;

        err = fdb_future_get_value(
            cast(FutureHandle)future,
            &valuePresent,
            &value,
            &valueLength);
        if (err != FDBError.NONE || !valuePresent)
            return null;
        return value[0..valueLength];
    }
}

alias KeyFutureCallback = FutureCallback!Key;

shared class KeyFuture : FDBFutureBase!(KeyFutureCallback, Key)
{
    mixin FutureCtor!KeyFutureCallback;

    private alias PKey = ubyte *;

    override Value extractValue(SH future, out SE err)
    {
        PKey key;
        int  keyLength;

        err = fdb_future_get_key(
            cast(FutureHandle)future,
            &key,
            &keyLength);
        if (err != FDBError.NONE)
            return typeof(return).init;
        return key[0..keyLength];
    }
}

alias VoidFutureCallback = void delegate(Exception ex);

shared class VoidFuture : FDBFutureBase!(VoidFutureCallback, void)
{
    mixin FutureCtor!VoidFutureCallback;

    override void extractValue(SH future, out SE err)
    {
        err = fdb_future_get_error(
            cast(FutureHandle)future);
    }
}

alias KeyValueFutureCallback    = FutureCallback!RecordRange;
alias ForEachCallback           = void delegate(
    Record record,
    out bool breakLoop);

shared class KeyValueFuture
    : FDBFutureBase!(KeyValueFutureCallback, RecordRange)
{
    const RangeInfo info;

    this(FutureHandle future, const Transaction tr, RangeInfo info)
    {
        super(future, tr);

        this.info = cast(shared)info;
    }

    override RecordRange extractValue(SH future, out SE err)
    {
        FDBKeyValue * kvs;
        int len;
        // Receives true if there are more result, or false if all results have
        // been transmited
        fdb_bool_t more;
        err = fdb_future_get_keyvalue_array(
            cast(FutureHandle)future,
            &kvs,
            &len,
            &more);
        if (err != FDBError.NONE)
            return typeof(return).init;

        Record[] records = kvs[0..len]
            .map!createRecord
            .array;

        return RecordRange(
            records,
            cast(bool)more,
            cast(RangeInfo)info,
            cast(Transaction)tr);
    }

    static Record createRecord(ref FDBKeyValue kv) pure
    {
        auto key   = (cast(Key)  kv.key  [0..kv.key_length  ]).dup;
        auto value = (cast(Value)kv.value[0..kv.value_length]).dup;
        return Record(key, value);
    }

    auto forEach(ForEachCallback fun, CompletionCallback cb)
    {
        auto f = createFuture!foreachTask(this, fun, cb);
        return f;
    }

    static void foreachTask(
        shared KeyValueFuture   future,
        ForEachCallback         fun,
        CompletionCallback      cb,
        CompletionCallback      futureCb)
    {
        try
        {
            // This will block until value is ready
            future.wait;
            auto range = cast(RecordRange)future.value;
            foreach (kv; range)
            {
                bool breakLoop;
                fun(kv, breakLoop);
                if (breakLoop) break;
            }
            cb(null);
            futureCb(null);
        }
        catch (Exception ex)
        {
            cb(ex);
            futureCb(ex);
        }
    }
}

alias VersionFutureCallback = FutureCallback!ulong;

shared class VersionFuture : FDBFutureBase!(VersionFutureCallback, ulong)
{
    mixin FutureCtor!VersionFutureCallback;

    override ulong extractValue(SH future, out SE err)
    {
        long ver;
        err = fdb_future_get_version(
            cast(FutureHandle)future,
            &ver);
        if (err != FDBError.NONE)
            return typeof(return).init;
        return ver;
    }
}

alias StringFutureCallback = FutureCallback!(string[]);

shared class StringFuture : FDBFutureBase!(StringFutureCallback, string[])
{
    mixin FutureCtor!StringFutureCallback;

    override string[] extractValue(SH future, out SE err)
    {
        char ** stringArr;
        int     count;
        err = fdb_future_get_string_array(
            cast(FutureHandle)future,
            &stringArr,
            &count);
        if (err != FDBError.NONE)
            return typeof(return).init;
        auto strings = stringArr[0..count].map!(to!string).array;
        return strings;
    }
}

shared class WatchFuture : VoidFuture
{
    mixin FutureCtor!VoidFutureCallback;

    ~this()
    {
        cancel;
    }

    void cancel()
    {
        if (future)
            fdb_future_cancel(cast(FutureHandle)future);
    }
}

auto createFuture(T)()
{
    auto future = new shared BasicFuture!T;
    return future;
}

auto createFuture(F, Args...)(Args args)
{
    auto future = new shared F(args);
    return future;
}

auto createFuture(alias fun, Args...)(Args args)
if (isSomeFunction!fun)
{
    auto future = new shared FunctionFuture!(fun, Args)(args);
    return future;
}

auto startOrCreateFuture(F, C, Args...)(
    Args args,
    C callback)
{
    auto future = createFuture!F(args);
    if (callback)
        future.start(callback);
    return future;
}

void wait(F...)(F futures)
{
    foreach (f; futures)
        f.wait;
}