using Microsoft.Azure.Functions.Worker.Builder;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Hosting;
using Microsoft.Extensions.Logging;
using Orders.Tools;
using Orders.Tools.Core;

var builder = FunctionsApplication.CreateBuilder(args);

// ---------------------------------------------------------------------------
// Which state store, and why this is read three ways.
//
// A Functions app setting named AzureWebJobsStorage__accountName reaches IConfiguration as
// AzureWebJobsStorage:accountName, because the double underscore is the HIERARCHY SEPARATOR,
// not part of the key. Reading the literal double-underscore name returns null.
//
// That cost a long afternoon, because the failure was silent: the lookup returned null, the
// code fell back to the in-memory store, every endpoint answered 200, no table was ever
// created, and the smoke tests passed. An empty store and a working store look identical
// until you ask one for content it should have.
//
// So: an explicit setting first, then the colon form, then the literal, and it SAYS which
// store it picked. A fallback that does not announce itself is a fallback that will fool you.
// ---------------------------------------------------------------------------
var storageAccount =
    builder.Configuration["STATE_STORAGE_ACCOUNT"]
    ?? builder.Configuration["AzureWebJobsStorage:accountName"]
    ?? builder.Configuration["AzureWebJobsStorage__accountName"];

builder.Services.AddSingleton<IOrderStateStore>(sp =>
{
    var log = sp.GetRequiredService<ILoggerFactory>().CreateLogger("Orders.Tools.State");

    if (string.IsNullOrWhiteSpace(storageAccount))
    {
        log.LogWarning(
            "No storage account resolved from STATE_STORAGE_ACCOUNT, " +
            "AzureWebJobsStorage:accountName or AzureWebJobsStorage__accountName. " +
            "Falling back to the IN-MEMORY store. State will NOT persist and will NOT be " +
            "shared across instances. This is correct for local runs and wrong in Azure.");

        return new InMemoryOrderStateStore();
    }

    log.LogInformation("State store: Azure Table Storage on account {Account}.", storageAccount);
    return new TableOrderStateStore(storageAccount);
});

builder.Services.AddSingleton<OrderTools>();

builder.Build().Run();
