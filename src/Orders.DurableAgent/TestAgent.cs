using System.Net;
using System.Diagnostics;
using Microsoft.Agents.AI;
using Microsoft.Azure.Functions.Worker;
using Microsoft.Azure.Functions.Worker.Http;
using Microsoft.Extensions.Logging;

namespace Orders.DurableAgent;

/// <summary>
/// Diagnostic only. Calls the agent directly, with no orchestration, no entity and no
/// checkpointing, and reports how long it took.
///
/// This exists because "the orchestration is stuck" has two very different causes: the model
/// call is failing or hanging, or the durable plumbing is not delivering. One request here
/// separates them. If this returns text, the model path is fine and the problem is durable.
/// If this hangs or throws, the orchestration was never going to finish.
/// </summary>
public class TestAgent
{
    private readonly AIAgent _agent;
    private readonly ILogger<TestAgent> _log;

    public TestAgent(AIAgent agent, ILogger<TestAgent> log)
    {
        _agent = agent;
        _log = log;
    }

    [Function(nameof(RunAgentDirect))]
    public async Task<HttpResponseData> RunAgentDirect(
        [HttpTrigger(AuthorizationLevel.Function, "get", "post", Route = "test/agent")]
            HttpRequestData req)
    {
        var message = req.Query["message"] ?? "Use lookup_order to look up ORD-1001 and tell me the SKU and quantity.";
        var sw = Stopwatch.StartNew();

        try
        {
            using var cts = new CancellationTokenSource(TimeSpan.FromSeconds(90));
            var response = await _agent.RunAsync(message, cancellationToken: cts.Token);

            sw.Stop();
            _log.LogInformation("TestAgent succeeded in {Ms}ms", sw.ElapsedMilliseconds);

            var ok = req.CreateResponse(HttpStatusCode.OK);
            await ok.WriteAsJsonAsync(new
            {
                elapsedMs = sw.ElapsedMilliseconds,
                text = response.Text
            });
            return ok;
        }
        catch (OperationCanceledException)
        {
            sw.Stop();
            _log.LogError("TestAgent timed out after {Ms}ms", sw.ElapsedMilliseconds);

            var timeout = req.CreateResponse(HttpStatusCode.GatewayTimeout);
            await timeout.WriteAsJsonAsync(new
            {
                elapsedMs = sw.ElapsedMilliseconds,
                error = "The agent did not respond within 90 seconds. The model call is the problem, not durable."
            });
            return timeout;
        }
        catch (Exception ex)
        {
            sw.Stop();
            _log.LogError(ex, "TestAgent failed after {Ms}ms", sw.ElapsedMilliseconds);

            var fail = req.CreateResponse(HttpStatusCode.InternalServerError);
            await fail.WriteAsJsonAsync(new
            {
                elapsedMs = sw.ElapsedMilliseconds,
                error = ex.GetType().Name,
                message = ex.Message,
                inner = ex.InnerException?.Message
            });
            return fail;
        }
    }

    /// <summary>Checks the action layer alone, with no model in the path.</summary>
    [Function(nameof(TestToolLayer))]
    public async Task<HttpResponseData> TestToolLayer(
        [HttpTrigger(AuthorizationLevel.Function, "get", Route = "test/tools")]
            HttpRequestData req,
        FunctionContext ctx)
    {
        var tools = ctx.InstanceServices.GetService(typeof(Orders.Tools.Core.ToolLayerClient))
            as Orders.Tools.Core.ToolLayerClient;

        var sw = Stopwatch.StartNew();
        try
        {
            var order = await tools!.LookupOrderAsync("ORD-1001");
            sw.Stop();

            var ok = req.CreateResponse(HttpStatusCode.OK);
            await ok.WriteAsJsonAsync(new { elapsedMs = sw.ElapsedMilliseconds, order });
            return ok;
        }
        catch (Exception ex)
        {
            sw.Stop();
            var fail = req.CreateResponse(HttpStatusCode.InternalServerError);
            await fail.WriteAsJsonAsync(new
            {
                elapsedMs = sw.ElapsedMilliseconds,
                error = ex.GetType().Name,
                message = ex.Message
            });
            return fail;
        }
    }
}
