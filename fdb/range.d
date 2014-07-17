module fdb.range;

import
    fdb.fdb_c,
    fdb.fdb_c_options,
    fdb.rangeinfo,
    fdb.transaction;

class Record
{
    immutable Key   key;
    immutable Value value;

    this(immutable Key key, immutable Value value) pure
    {
        this.key   = key;
        this.value = value;
    }
}

class RecordRange
{
    private Record[]    records;
    private RangeInfo   info;
    private bool        _more;
    private Record      last;

    @property auto more()
    {
        return _more;
    }

    @property auto length()
    {
        return records.length;
    }

    const Transaction   tr;

    this(
        Record[]            records,
        const bool          more,
        RangeInfo           info,
        const Transaction   tr)
    {
        this.records    = records;
        this.last       = records[$];

        this._more      = more;
        this.info       = info;
        this.tr         = tr;
    }

    @property bool empty() const
    {
        return records.length == 0;
    }

    auto front() const
    {
        return records[0];
    }

    auto popFront()
    {
        records = records[1 .. $];
        if (empty && more)
            fetchNextBatch;
    }

    private void fetchNextBatch()
    {
        info.iteration++;
        if (info.limit > 0)
            info.limit -= records.length;

        if (info.reverse)
            info.end    = firstGreaterOrEqual(last.key);
        else
            info.start  = firstGreaterThan(last.key);

        auto future     = tr.getRange(info);
        auto batch      = future.getValue;
        records        ~= batch.records;
        last            = records[$];
        _more           = batch.more;
    }
}