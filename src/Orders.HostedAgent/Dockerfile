FROM mcr.microsoft.com/dotnet/sdk:8.0 AS build
WORKDIR /src
COPY Directory.Build.props ./
COPY src/Orders.Tools.Core/ src/Orders.Tools.Core/
COPY src/Orders.HostedAgent/ src/Orders.HostedAgent/
RUN dotnet publish src/Orders.HostedAgent/Orders.HostedAgent.csproj -c Release -o /app

FROM mcr.microsoft.com/dotnet/aspnet:8.0
WORKDIR /app
COPY --from=build /app .

# 8088, not 8080. Foundry probes GET /readiness on port 8088 before routing anything to the
# container. On any other port the probe never succeeds, the session never becomes ready, and
# every invoke fails with HTTP 424 session_not_ready while the container logs look perfectly
# healthy. The first image shipped on 8080 and did exactly that.
ENV ASPNETCORE_URLS=http://+:8088
EXPOSE 8088
ENTRYPOINT ["dotnet", "Orders.HostedAgent.dll"]
