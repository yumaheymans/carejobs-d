# carejobs-d

D client for the [CareJobs.Now](https://carejobs.now) healthcare jobs API. Search open US healthcare jobs, see the hourly pay employers post, and look up employers and states.

- Free, no API key.
- Uses only `std.json` and `std.net.curl` (so it needs libcurl, which most systems have). Works with DMD, LDC and GDC.
- A `Kind` enum, filter structs, one `CareJobsException` type with an `ErrorCode`.
- The same API is a remote MCP server at <https://carejobs.now/api/mcp>, so any MCP client can use it too.

## Where the data comes from

CareJobs.Now is a free US healthcare job board. Its jobs are read daily from the career sites of US hospitals, health systems, clinics and care employers, and the pay is what each posting states (hourly rates before shift differentials and bonuses). Every job links to its page on CareJobs.Now, where the user applies. Data and docs: <https://carejobs.now/data>.

Data from CareJobs.Now (https://carejobs.now), CC BY 4.0.

## Install

With [DUB](https://code.dlang.org/packages/carejobs), in `dub.json`:

```json
"dependencies": {
    "carejobs": "~>1.0.0"
}
```

or in `dub.sdl`:

```sdl
dependency "carejobs" version="~>1.0.0"
```

## Quick start

```d
import std.stdio;
import carejobs;

void main()
{
    auto client = new Client();

    SearchParams p = {query: "ICU", kind: Kind.nurses, state: "TX", limit: 5};
    auto jobs = client.searchJobs(p);

    writeln(jobs["total"].integer, " jobs match");
    foreach (job; jobs["jobs"].array)
        writeln(job["title"].str, " | ", job["employer"].str, " | ", job["url"].str);

    auto pay = client.payByKind(Kind.nurses);
    writeln("Median posted pay for nurses: $", pay["pay"]["median"], "/hr");

    // Every answer also carries the server's readable summary:
    writeln(pay.text);
}
```

A runnable version is in [`examples/search.d`](examples/search.d): `dub run --single examples/search.d -- OH`.

## Methods

Every method returns a `Result`: the tool's data as a `JSONValue` (`result.data`, or `result["jobs"]`) plus `result.text`, a readable summary written by the server. The keys are the ones the API sends (`typical_low`, `open_jobs`, and so on). Where the API sends `null`, the value has `JSONType.null_`, and `result.get("key")` gives such a null when the key is missing.

| Method | What it answers |
| --- | --- |
| `searchJobs(SearchParams)` | Open jobs. Fields: `query`, `kind`, `employer`, `state`, `remote`, `minHourlyUsd`, `sort`, `limit`. Data: `total`, `pay`, `jobs`, `more`. `limit` is 1 to 25. |
| `pay(kind, employer)` | Posted hourly pay: every kind, one kind with the employers posting the most, one employer, or both. |
| `payByKind(kind)` | `pay` for one kind of job. |
| `jobMarket()` | How many jobs are open, new in the last 7 days, and the open jobs by kind, state and employer. |
| `jobsByState(state, kind, limit)` | Every state, one state, or one kind of job in one state (a kind needs a state). |
| `states(state, kind, limit)` | Alias of `jobsByState`. |
| `employers(EmployerParams)` | The employers, AI-training programs and job boards the site reads. Fields: `query`, `type`, `care`, `state`, `kind`, `limit` (1 to 100). |
| `employer(slug)` | One employer by slug (`"kaiser-permanente"`) or name. |
| `kinds()` | The 17 kinds of job as slugs. Also the enum `Kind` and the array `carejobs.kinds`. |
| `tools()` | The server's tools with their input schemas. |
| `callTool(name, arguments)` | Any tool, for a tool this version does not know yet. |

In a filter struct an empty string, `false` or 0 leaves a filter off. A `Kind` converts to its slug, so `Kind.nurses` works wherever a kind string is expected.

```d
auto ohio = client.states("OH", Kind.nursingAssistants);
writeln(ohio["open_jobs"].integer, " CNA jobs in Ohio");

EmployerParams ep = {query: "Kaiser", limit: 3};
foreach (entry; client.employers(ep)["entries"].array)
    writeln(entry["name"].str, " (", entry["open_jobs"].integer, " open jobs)");
```

### Options

```d
auto client = new Client(
    "https://carejobs.now",  // base URL, the default
    60.seconds,              // timeout, the default
    "my-app/1.0",            // User-Agent, default "carejobs-d/<version>"
);
```

The server answers a query it has not seen before in up to about 25 seconds, then repeats of it in a fraction of one, which is why the default timeout is a minute.

### Errors

Every failure throws `CareJobsException`. Its `code` is an `ErrorCode`:

```d
try
    client.jobsByState(null, Kind.nurses); // a kind without a state
catch (CareJobsException e)
    writeln(e.code, ": ", e.msg);
// ErrorCode.tool     the server ran the tool and said no
// ErrorCode.rpc      a JSON-RPC error (e.rpcCode)
// ErrorCode.http     a non-2xx status (e.status)
// ErrorCode.network, ErrorCode.timeout   no answer
// ErrorCode.protocol the answer was not what MCP promises
```

### Kinds

`nurses`, `nurse-practitioners`, `physicians`, `nursing-assistants`, `caregivers`, `therapy-rehab`, `mental-health`, `pharmacy`, `imaging`, `lab`, `surgical-techs`, `emts-paramedics`, `medical-assistants`, `dental`, `admin`, `allied-health`, `ai-training`.

## Tests

```sh
dub test                              # offline, with a fake transport
dub run --single examples/live.d      # calls the live API
```

## Plain JSON

Without this library the same data is plain JSON: <https://carejobs.now/roles.json> (open jobs by kind of job and employer) and <https://carejobs.now/pay.json> (posted hourly pay by kind of job).

## License

Code: MIT, copyright O-mega Enterprise, Inc. Data: CC BY 4.0, credit CareJobs.Now.
