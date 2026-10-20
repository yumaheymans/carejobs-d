#!/usr/bin/env dub
/+ dub.sdl:
    name "live"
    dependency "carejobs" path=".."
+/
// Calls the live API (network needed): dub run --single examples/live.d
import std.algorithm : map;
import std.array : array, join;
import std.stdio : writeln;
import carejobs;

void main()
{
    auto client = new Client();

    writeln("tools: ", client.tools.array.map!(t => t["name"].str).join(", "));

    SearchParams p = {query: "ICU", kind: Kind.nurses, state: "TX", limit: 3};
    auto jobs = client.searchJobs(p);
    writeln(jobs["total"].integer, " jobs match");
    foreach (job; jobs["jobs"].array)
        writeln(" - ", job["title"].str, " | ", job["employer"].str, " | ", job["url"].str);

    writeln("nurse median $", client.payByKind(Kind.nurses)["pay"]["median"], "/hr");
    writeln("Ohio: ", client.states("OH")["open_jobs"].integer, " open jobs");

    EmployerParams ep = {limit: 2};
    auto employers = client.employers(ep);
    writeln(employers["total"].integer, " employers, first: ", employers["entries"][0]["name"].str);

    try
        client.jobsByState(null, Kind.nurses); // a kind without a state
    catch (CareJobsException e)
        writeln(e.code, ": ", e.msg);
}
