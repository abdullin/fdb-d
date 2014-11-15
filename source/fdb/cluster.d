module fdb.cluster;

import
    std.conv,
    std.exception,
    std.string;

import
    fdb.database,
    fdb.error,
    fdb.fdb_c,
    fdb.future;

class Cluster
{
    private ClusterHandle ch;

    this(ClusterHandle ch)
    in
    {
        enforce(ch !is null, "ch must be set");
    }
    body
    {
        this.ch = ch;
    }

    ~this()
    {
        destroy;
    }

    void destroy()
    {
        if (ch)
        {
            fdb_cluster_destroy(ch);
            ch = null;
        }
    }

    auto openDatabase(const string dbName = "DB")
    out (result)
    {
        assert(result !is null);
    }
    body
    {
        auto fh = fdb_cluster_create_database(
            ch,
            dbName.toStringz(),
            cast(int)dbName.length);
        scope auto future = createFuture!VoidFuture(fh);
        future.await;

        DatabaseHandle dbh;
        fdb_future_get_database(fh, &dbh).enforceError;
        return new Database(this, dbh);
    }
}