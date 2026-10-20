/++
Client for the CareJobs.Now healthcare jobs API.

Search open US healthcare jobs, see the hourly pay employers post, and look up
employers and states. The API is a remote MCP server (JSON-RPC over HTTP) that
needs no key: https://carejobs.now/api/mcp

Every method returns a `Result`: the tool's data as a `JSONValue` (`result.data`,
or `result["jobs"]`) plus `result.text`, the readable summary the server writes.
Every failure throws a `CareJobsException`.

Data from CareJobs.Now (https://carejobs.now), CC BY 4.0.

License: MIT, copyright O-mega Enterprise, Inc.
+/
module carejobs;

import core.time : Duration, dur, seconds;
import std.algorithm : min, startsWith;
import std.array : appender, join, replace;
import std.conv : to;
import std.exception : collectException;
import std.json;
public import std.json : JSONType, JSONValue; // so users can read a Result without importing std.json
import std.net.curl : CurlException, CurlTimeoutException, HTTP;
import std.string : indexOf, split, strip, toLower;

/// The version of this package, sent in the default User-Agent.
enum string carejobsVersion = "1.0.0";

/// The CareJobs.Now site; the MCP endpoint is this plus "/api/mcp".
enum string defaultBaseUrl = "https://carejobs.now";

/// How long a request may take. The server answers a query it has not seen
/// before in up to about 25 seconds (its database may be waking up), then
/// repeats of it in a fraction of one.
enum Duration defaultTimeout = 60.seconds;

// The largest real answer (the whole job market) is about 135 KB.
private enum size_t maxResponseBytes = 16 * 1024 * 1024;

/// A kind of healthcare job, the `kind` filter of the API. A `Kind` converts to
/// its slug, so it can be passed wherever a kind string is expected.
enum Kind : string
{
    nurses = "nurses",                          /// Registered nurses and LPNs
    nursePractitioners = "nurse-practitioners", /// NPs and PAs
    physicians = "physicians",                  /// Doctors
    nursingAssistants = "nursing-assistants",   /// CNAs and patient care techs
    caregivers = "caregivers",                  /// Caregivers and home health aides
    therapyRehab = "therapy-rehab",             /// Physical, occupational, speech and respiratory therapy
    mentalHealth = "mental-health",             /// Mental health and social work
    pharmacy = "pharmacy",                      /// Pharmacists and pharmacy techs
    imaging = "imaging",                        /// Radiology and imaging techs
    lab = "lab",                                /// Lab
    surgicalTechs = "surgical-techs",           /// Surgical techs
    emtsParamedics = "emts-paramedics",         /// EMS
    medicalAssistants = "medical-assistants",   /// Medical assistants
    dental = "dental",                          /// Dental
    admin = "admin",                            /// Front desk and admin
    alliedHealth = "allied-health",             /// Allied health
    aiTraining = "ai-training",                 /// AI training for health professionals
}

/// Every kind slug, in the order the API documents them.
immutable string[] kinds = [
    "nurses", "nurse-practitioners", "physicians", "nursing-assistants",
    "caregivers", "therapy-rehab", "mental-health", "pharmacy", "imaging", "lab",
    "surgical-techs", "emts-paramedics", "medical-assistants", "dental", "admin",
    "allied-health", "ai-training",
];

/// What kind of failure a `CareJobsException` is.
enum ErrorCode
{
    tool,     /// the server ran the tool and said no (the message is its text)
    rpc,      /// a JSON-RPC error (see `rpcCode`)
    http,     /// a non-2xx status (see `status`)
    network,  /// the server could not be reached
    timeout,  /// no answer in time
    protocol, /// the answer was not what MCP promises
}

/// Every failure of the client.
class CareJobsException : Exception
{
    /// What kind of failure this is.
    ErrorCode code;
    /// The tool that was called, when there was one.
    string tool;
    /// The HTTP status, for `ErrorCode.http`.
    int status;
    /// The JSON-RPC error code, for `ErrorCode.rpc`.
    int rpcCode;

    this(ErrorCode code, string message, string tool = null, int status = 0, int rpcCode = 0,
         Throwable next = null, string file = __FILE__, size_t line = __LINE__) @safe pure nothrow
    {
        super(message, file, line, next);
        this.code = code;
        this.tool = tool;
        this.status = status;
        this.rpcCode = rpcCode;
    }
}

/// The answer of one tool.
struct Result
{
    /// The tool's data, with the keys the API sends. A JSON null is `JSONType.null_`.
    JSONValue data;
    /// The plain-text summary the server writes, handy to show a person or to hand to a language model.
    string text;

    /// `result["jobs"]` is `result.data["jobs"]`.
    ref inout(JSONValue) opIndex(string key) inout
    {
        return data[key];
    }

    /// The value of `key`, or a JSON null when the answer has no such key.
    JSONValue get(string key) const
    {
        if (auto p = key in data)
            return *p;
        return JSONValue(null);
    }
}

/// Filters of `Client.searchJobs`. Every field is optional; an empty string, `false` or 0 leaves a filter off.
struct SearchParams
{
    /// Words every job must carry in its title, place, department or schedule ("ICU", "night", "Houston").
    string query;
    /// A kind of job, see `Kind` and `kinds`.
    string kind;
    /// An employer slug ("kaiser-permanente") or name.
    string employer;
    /// A US state: "TX" or "Texas".
    string state;
    /// True keeps only remote jobs.
    bool remote;
    /// Only jobs whose posted hourly ceiling reaches this many US dollars (1 to 1000).
    int minHourlyUsd;
    /// "mixed" (the default), "newest" or "highest_pay".
    string sort;
    /// How many jobs to return (1 to 25, server default 10).
    int limit;
}

/// Filters of `Client.employers`. Every field is optional.
struct EmployerParams
{
    /// Part of the name ("Kaiser", "children", "dialysis").
    string query;
    /// "employer" (the default), "ai-program" or "job-board".
    string type;
    /// A kind of care, for example "home-care" or "health-system".
    string care;
    /// Keep employers with open jobs in this US state.
    string state;
    /// Keep employers with open jobs of this kind.
    string kind;
    /// How many to return (1 to 100, server default 20).
    int limit;
}

/// What a transport returns for one request.
struct HttpResponse
{
    /// The HTTP status code.
    int status;
    /// The Content-Type header, or an empty string.
    string contentType;
    /// The response body.
    string body_;
}

/// Replaces the HTTP call (for tests): receives the URL, the JSON payload, the
/// request headers and the timeout, and returns the response.
alias Transport = HttpResponse delegate(string url, string payload, string[string] headers, Duration timeout);

/// Calls the CareJobs.Now healthcare jobs API. A `Client` keeps no state
/// between calls apart from a request counter, so use one per thread.
final class Client
{
    private string endpoint_;
    private string baseUrl_;
    private Duration timeout_;
    private string userAgent_;
    private Transport transport_;
    private long nextId_;

    /++
    Params:
        baseUrl = the host; the endpoint is `baseUrl ~ "/api/mcp"`
        timeout = how long a request may take
        userAgent = sent as the User-Agent header (default "carejobs-d/<version>")
        transport = replaces the HTTP call (for tests)
    +/
    this(string baseUrl = defaultBaseUrl, Duration timeout = defaultTimeout,
         string userAgent = null, Transport transport = null)
    {
        while (baseUrl.length && baseUrl[$ - 1] == '/')
            baseUrl = baseUrl[0 .. $ - 1];
        if (!(baseUrl.startsWith("http://") || baseUrl.startsWith("https://")) || baseUrl.length < 9)
            throw new CareJobsException(ErrorCode.protocol,
                "baseUrl must be an http:// or https:// address, not " ~ baseUrl);
        if (timeout <= Duration.zero)
            throw new CareJobsException(ErrorCode.protocol, "timeout must be above zero");
        baseUrl_ = baseUrl;
        endpoint_ = baseUrl ~ "/api/mcp";
        timeout_ = timeout;
        userAgent_ = userAgent.length ? userAgent : "carejobs-d/" ~ carejobsVersion;
        transport_ = transport;
    }

    /// The host this client calls.
    string baseUrl() const @safe pure nothrow { return baseUrl_; }

    // -- the six tools -----------------------------------------------------------------

    /// Search the open healthcare jobs. The data has `total` (every match), `pay`, `jobs` (the ones returned) and `more`.
    Result searchJobs(SearchParams p = SearchParams.init)
    {
        auto args = JSONValue.emptyObject;
        setString(args, "query", p.query);
        setString(args, "kind", p.kind);
        setString(args, "employer", p.employer);
        setString(args, "state", p.state);
        if (p.remote)
            args["remote"] = true;
        setInt(args, "min_hourly_usd", p.minHourlyUsd);
        setString(args, "sort", p.sort);
        setInt(args, "limit", p.limit);
        return callTool("search_healthcare_jobs", args);
    }

    /++
    What healthcare jobs post as hourly pay, measured from open jobs (before
    shift differentials and bonuses). With no arguments: every kind of job. With
    a kind: that job's pay and the employers posting the most for it. With an
    employer: its pay overall and by kind. With both: that employer's pay for
    that kind.
    +/
    Result pay(string kind = null, string employer = null)
    {
        auto args = JSONValue.emptyObject;
        setString(args, "kind", kind);
        setString(args, "employer", employer);
        return callTool("get_healthcare_pay", args);
    }

    /// The pay of one kind of job and the employers posting the most for it.
    Result payByKind(string kind)
    {
        return pay(kind);
    }

    /// How many healthcare jobs are open, how many were first listed in the last 7
    /// days, and the open jobs by kind of job, by state and by employer.
    Result jobMarket()
    {
        return callTool("get_healthcare_job_market", JSONValue.emptyObject);
    }

    /++
    Open jobs by US state. With no state: every state. With a state: its jobs by
    kind, pay, towns, employers and newest jobs. With a state and a kind: the
    same for that kind (a kind needs a state). `limit` (1 to 25) is how many of
    the newest jobs to return.
    +/
    Result jobsByState(string state = null, string kind = null, int limit = 0)
    {
        auto args = JSONValue.emptyObject;
        setString(args, "state", state);
        setString(args, "kind", kind);
        setInt(args, "limit", limit);
        return callTool("get_healthcare_jobs_by_state", args);
    }

    /// Alias of `jobsByState`: the states and their open jobs.
    Result states(string state = null, string kind = null, int limit = 0)
    {
        return jobsByState(state, kind, limit);
    }

    /// The employers (and AI-training programs and job boards) the site reads, most open jobs first.
    Result employers(EmployerParams p = EmployerParams.init)
    {
        auto args = JSONValue.emptyObject;
        setString(args, "query", p.query);
        setString(args, "type", p.type);
        setString(args, "care", p.care);
        setString(args, "state", p.state);
        setString(args, "kind", p.kind);
        setInt(args, "limit", p.limit);
        return callTool("list_healthcare_employers", args);
    }

    /// One employer, AI-training program or job board, by slug ("kaiser-permanente")
    /// or name: what it is, where it hires, its open jobs by kind, the pay it posts,
    /// its newest and best-paid jobs, and links to its pages.
    Result employer(string slug)
    {
        auto args = JSONValue.emptyObject;
        args["employer"] = slug;
        return callTool("get_healthcare_employer", args);
    }

    /// The kinds of job the API knows, as slugs.
    immutable(string)[] kinds() const @safe pure nothrow
    {
        return .kinds;
    }

    // -- low level ---------------------------------------------------------------------

    /// The tools the server offers, with their input schemas (a JSON array).
    JSONValue tools()
    {
        auto result = rpc("tools/list", JSONValue.emptyObject, null);
        if (result.type != JSONType.object || "tools" !in result || result["tools"].type != JSONType.array)
            throw new CareJobsException(ErrorCode.protocol, "tools/list answered without a tools list");
        return result["tools"];
    }

    /// Call any tool by name, for a tool added after this version. `arguments` is a
    /// JSON object with the API's names. The methods above use this.
    Result callTool(string name, JSONValue arguments)
    {
        JSONValue params = JSONValue.emptyObject;
        params["name"] = name;
        params["arguments"] = arguments;
        auto raw = rpc("tools/call", params, name);

        string[] texts;
        if (auto content = "content" in raw)
        {
            if (content.type == JSONType.array)
                foreach (part; content.array)
                    if (part.type == JSONType.object)
                    {
                        auto type = "type" in part;
                        auto text = "text" in part;
                        if (type && type.type == JSONType.string && type.str == "text"
                                && text && text.type == JSONType.string)
                            texts ~= text.str;
                    }
        }
        const text = texts.join("\n");

        if (auto isError = "isError" in raw)
            if (isError.type == JSONType.true_)
                throw new CareJobsException(ErrorCode.tool, text.length ? text : name ~ " failed", name);

        auto data = "structuredContent" in raw;
        if (data is null || data.type != JSONType.object)
            throw new CareJobsException(ErrorCode.protocol, name ~ " answered without structured content", name);
        return Result(*data, text);
    }

    // -- internals ---------------------------------------------------------------------

    private static void setString(ref JSONValue args, string key, string value)
    {
        if (value.length)
            args[key] = value;
    }

    private static void setInt(ref JSONValue args, string key, int value)
    {
        if (value != 0)
            args[key] = value;
    }

    /// Sends one JSON-RPC request and returns the result of its answer.
    private JSONValue rpc(string method, JSONValue params, string tool)
    {
        const id = ++nextId_;
        auto request = JSONValue.emptyObject;
        request["jsonrpc"] = "2.0";
        request["id"] = id;
        request["method"] = method;
        request["params"] = params;
        const payload = request.toString(JSONOptions.doNotEscapeSlashes);

        string[string] headers = [
            "Content-Type": "application/json",
            "Accept": "application/json, text/event-stream",
            "User-Agent": userAgent_,
        ];
        auto response = transport_ !is null
            ? transport_(endpoint_, payload, headers, timeout_)
            : curlTransport(endpoint_, payload, headers, timeout_, tool);

        if (response.status < 200 || response.status > 299)
            throw new CareJobsException(ErrorCode.http,
                httpErrorDetail(response.status, response.body_, response.contentType, id),
                tool, response.status);

        auto message = parseMessage(response.body_, response.contentType, id, tool);
        if (auto error = "error" in message)
        {
            if (error.type != JSONType.null_)
            {
                if (error.type != JSONType.object)
                    throw new CareJobsException(ErrorCode.protocol, "Malformed JSON-RPC error", tool);
                string text = "JSON-RPC error";
                if (auto m = "message" in *error)
                    if (m.type == JSONType.string && m.str.length)
                        text = m.str;
                int code = 0;
                if (auto c = "code" in *error)
                    if (c.type == JSONType.integer)
                        code = cast(int) c.integer;
                throw new CareJobsException(ErrorCode.rpc, text, tool, 0, code);
            }
        }
        auto result = "result" in message;
        if (result is null || result.type != JSONType.object)
            throw new CareJobsException(ErrorCode.protocol, "The answer held no result", tool);
        return *result;
    }
}

private string httpErrorDetail(int status, string body_, string contentType, long id)
{
    const detail = "HTTP " ~ status.to!string;
    try
    {
        auto message = parseMessage(body_, contentType, id, null);
        if (auto error = "error" in message)
            if (error.type == JSONType.object)
                if (auto m = "message" in *error)
                    if (m.type == JSONType.string && m.str.length)
                        return detail ~ ": " ~ m.str;
    }
    catch (CareJobsException)
    {
        // not a JSON-RPC body: fall through to the raw text
    }
    const text = body_.strip;
    if (text.length == 0)
        return detail;
    return detail ~ ": " ~ text[0 .. min(200, text.length)];
}

private JSONValue decodeObject(string text, string tool)
{
    JSONValue value;
    try
        value = parseJSON(text);
    catch (JSONException e)
        throw new CareJobsException(ErrorCode.protocol, "The server did not answer with JSON", tool, 0, 0, e);
    if (value.type != JSONType.object)
        throw new CareJobsException(ErrorCode.protocol, "The server did not answer with a JSON-RPC object", tool);
    return value;
}

/// Reads the JSON-RPC message out of a plain JSON body or a text/event-stream body.
private JSONValue parseMessage(string body_, string contentType, long id, string tool)
{
    if (contentType.toLower.indexOf("text/event-stream") < 0)
        return decodeObject(body_, tool);

    JSONValue fallback;
    bool haveFallback;
    foreach (event; body_.replace("\r\n", "\n").split("\n\n"))
    {
        string[] data;
        foreach (line; event.split("\n"))
            if (line.startsWith("data:"))
            {
                auto rest = line[5 .. $];
                data ~= rest.length && rest[0] == ' ' ? rest[1 .. $] : rest;
            }
        if (data.length == 0)
            continue;
        JSONValue message;
        try
            message = decodeObject(data.join("\n"), tool);
        catch (CareJobsException)
            continue;
        if (auto messageId = "id" in message)
            if (messageId.type == JSONType.integer && messageId.integer == id)
                return message;
        if (!haveFallback && ("result" in message || "error" in message))
        {
            fallback = message;
            haveFallback = true;
        }
    }
    if (haveFallback)
        return fallback;
    throw new CareJobsException(ErrorCode.protocol, "The event stream held no JSON-RPC answer", tool);
}

/// Sends the request with libcurl through std.net.curl.
private HttpResponse curlTransport(string url, string payload, string[string] headers, Duration timeout, string tool)
{
    auto http = HTTP(url);
    http.method = HTTP.Method.post;
    http.postData = payload;
    foreach (name, value; headers)
        http.addRequestHeader(name, value);
    http.operationTimeout = timeout;
    http.connectTimeout = min(timeout, 30.seconds);

    auto buffer = appender!(ubyte[])();
    bool tooLarge;
    http.onReceive = (ubyte[] data) {
        if (buffer.data.length + data.length > maxResponseBytes)
        {
            tooLarge = true;
            return 0; // aborts the transfer
        }
        buffer.put(data);
        return data.length;
    };
    string contentType;
    http.onReceiveHeader = (in char[] key, in char[] value) {
        if (key.toLower == "content-type")
            contentType = value.idup;
    };

    try
        http.perform();
    catch (CurlTimeoutException e)
        throw new CareJobsException(ErrorCode.timeout,
            "No answer from " ~ url ~ " within " ~ timeout.toString, tool, 0, 0, e);
    catch (CurlException e)
    {
        if (tooLarge)
            throw new CareJobsException(ErrorCode.protocol, "The answer is larger than 16 MB", tool, 0, 0, e);
        throw new CareJobsException(ErrorCode.network, "Could not reach " ~ url ~ ": " ~ e.msg, tool, 0, 0, e);
    }
    return HttpResponse(http.statusLine.code, contentType, cast(string) buffer.data.idup);
}

private string toString(Duration d)
{
    return d.total!"msecs".to!string ~ " ms";
}

// -- tests: no network, the transport is a fake ------------------------------------

version (unittest)
{
    import std.exception : assertThrown;

    private string answer(JSONValue structured, string text = "summary")
    {
        auto part = JSONValue.emptyObject;
        part["type"] = "text";
        part["text"] = text;
        auto result = JSONValue.emptyObject;
        result["content"] = JSONValue([part]);
        result["structuredContent"] = structured;
        auto message = JSONValue.emptyObject;
        message["jsonrpc"] = "2.0";
        message["id"] = 1;
        message["result"] = result;
        return message.toString;
    }

    private struct Recorder
    {
        string url, raw;
        JSONValue payload;
        string reply;
        int status = 200;
        string contentType = "application/json";

        Transport transport()
        {
            return (string u, string p, string[string] h, Duration t) {
                url = u;
                raw = p;
                payload = parseJSON(p);
                return HttpResponse(status, contentType, reply);
            };
        }
    }

    private ErrorCode codeOf(Client c, scope void delegate(Client) call)
    {
        try
            call(c);
        catch (CareJobsException e)
            return e.code;
        assert(false, "no exception");
    }

    unittest // searchJobs sends the filters and reads the data and the text
    {
        auto data = JSONValue.emptyObject;
        data["total"] = 3;
        auto job = JSONValue.emptyObject;
        job["title"] = "RN";
        data["jobs"] = JSONValue([job]);
        Recorder rec;
        rec.reply = answer(data, "three jobs");
        auto client = new Client(defaultBaseUrl, defaultTimeout, null, rec.transport);

        SearchParams p = {query: "ICU", kind: Kind.nurses, state: "TX", limit: 5};
        auto res = client.searchJobs(p);

        assert(rec.url == "https://carejobs.now/api/mcp");
        assert(rec.payload["method"].str == "tools/call");
        assert(rec.payload["params"]["name"].str == "search_healthcare_jobs");
        auto args = rec.payload["params"]["arguments"];
        assert(args["query"].str == "ICU" && args["kind"].str == "nurses" && args["state"].str == "TX");
        assert(args["limit"].integer == 5);
        assert("remote" !in args && "employer" !in args);
        assert(res["total"].integer == 3);
        assert(res.data["jobs"][0]["title"].str == "RN");
        assert(res.text == "three jobs");
        assert(res.get("missing").type == JSONType.null_);
    }

    unittest // the other tools
    {
        Recorder rec;
        rec.reply = answer(JSONValue(["ok": true]));
        auto client = new Client(defaultBaseUrl, defaultTimeout, null, rec.transport);

        client.jobMarket();
        assert(rec.raw.indexOf(`"arguments":{}`) >= 0); // an empty object, not a list

        client.payByKind("physicians");
        assert(rec.payload["params"]["name"].str == "get_healthcare_pay");
        assert(rec.payload["params"]["arguments"]["kind"].str == "physicians");

        client.states("OH", Kind.nursingAssistants);
        assert(rec.payload["params"]["name"].str == "get_healthcare_jobs_by_state");
        assert(rec.payload["params"]["arguments"]["state"].str == "OH");
        assert(rec.payload["params"]["arguments"]["kind"].str == "nursing-assistants");

        EmployerParams ep = {query: "Kaiser", limit: 3};
        client.employers(ep);
        assert(rec.payload["params"]["name"].str == "list_healthcare_employers");
        assert(rec.payload["params"]["arguments"]["limit"].integer == 3);

        client.employer("cvs-health");
        assert(rec.payload["params"]["arguments"]["employer"].str == "cvs-health");

        assert(client.kinds.length == 17 && client.kinds[$ - 1] == "ai-training");
    }

    unittest // a text/event-stream answer
    {
        Recorder rec;
        rec.contentType = "text/event-stream";
        rec.reply = "event: message\ndata: " ~ answer(JSONValue(["open_jobs": 9])) ~ "\n\n";
        auto client = new Client(defaultBaseUrl, defaultTimeout, null, rec.transport);
        assert(client.jobMarket()["open_jobs"].integer == 9);
    }

    unittest // failures
    {
        Recorder rec;
        auto client = new Client(defaultBaseUrl, defaultTimeout, null, rec.transport);

        rec.reply = `{"jsonrpc":"2.0","id":1,"result":{"isError":true,"content":[{"type":"text","text":"bad state"}]}}`;
        assert(codeOf(client, (c) { c.jobsByState("ZZ"); }) == ErrorCode.tool);

        rec.reply = `{"jsonrpc":"2.0","id":1,"error":{"code":-32601,"message":"no such method"}}`;
        assert(codeOf(client, (c) { c.jobMarket(); }) == ErrorCode.rpc);

        rec.status = 503;
        rec.contentType = "text/plain";
        rec.reply = "down";
        assert(codeOf(client, (c) { c.jobMarket(); }) == ErrorCode.http);
        try
            client.jobMarket();
        catch (CareJobsException e)
            assert(e.msg == "HTTP 503: down" && e.status == 503);

        rec.status = 200;
        rec.reply = "<html>";
        assert(codeOf(client, (c) { c.jobMarket(); }) == ErrorCode.protocol);

        rec.contentType = "application/json";
        rec.reply = `{"jsonrpc":"2.0","id":1,"result":{"content":[]}}`;
        assert(codeOf(client, (c) { c.jobMarket(); }) == ErrorCode.protocol);

        assertThrown!CareJobsException(new Client("not a url"));
    }
}
