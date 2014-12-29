module fdb.tuple.packer;

import
    std.exception,
    std.range,
    std.string,
    std.traits;

import
    fdb.tuple.integral,
    fdb.tuple.part,
    fdb.tuple.segmented,
    fdb.tuple.tupletype;

private class Packer
{
    ubyte[] bytes;

    void write(T)(const T value)
    if (isIntegral!T)
    in
    {
        enforce(value >= long.min,
            "Value cannot exceed minumum 64-bit signed integer");
        enforce(value <= long.max,
            "Value cannot exceed maximum 64-bit signed integer");
    }
    body
    {
        auto size   = value.minsizeof;
        auto marker =
            cast(ubyte)(TupleType.IntBase + ((value > 0) ? size : -size));

        ulong compliment = (value > 0) ? value : ~(-value);
        auto segmented   = Segmented!(ulong, ubyte)(compliment);

        bytes ~= marker;
        bytes ~= segmented.segments[0..size].retro.array;
    }

    void write(const string value)
    {
        bytes ~= TupleType.Utf8;
        bytes ~= cast(ubyte[])(value.toStringz[0..value.length + 1]);
    }

    void write(R)(const R r)
    if(isInputRange!R && !is(R == string))
    {
        foreach (const e; r)
        {
            write(e);
        }
    }

    void write(const Part part)
    {
        if (auto v = part.peek!long)
            write(*v);
        else if (auto v = part.peek!string)
            write(*v);
        // there is no else part because Part can only be long or string
    }
}

auto pack(T...)(T parts)
{
    scope auto w = new Packer;
    foreach (const p; parts)
        w.write(p);
    return w.bytes.idup;
}
