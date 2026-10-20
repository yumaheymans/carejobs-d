#!/usr/bin/env dub
/+ dub.sdl:
    name "search"
    dependency "carejobs" path=".."
+/
// dub run --single examples/search.d -- OH
import std.stdio : writefln, writeln;
import carejobs;

void main(string[] args)
{
    const state = args.length > 1 ? args[1] : "TX";
    auto client = new Client();

    SearchParams p = {kind: Kind.nurses, state: state, limit: 5};
    auto res = client.searchJobs(p);

    writefln("%s nursing jobs in %s", res["total"].integer, state);
    foreach (job; res["jobs"].array)
        writeln(job["title"].str, " | ", job["employer"].str, " | ",
                job["location"].type == JSONType.string ? job["location"].str : "", " | ", job["url"].str);

    auto pay = client.payByKind(Kind.nurses);
    writeln("Median posted pay for nurses: $", pay["pay"]["median"], "/hr");
}
