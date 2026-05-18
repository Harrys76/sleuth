/// `sleuth_mcp` — MCP stdio sidecar for the sleuth Flutter performance
/// diagnostics package.
library;

export 'src/cli/config_writer.dart'
    show
        ConfigWriter,
        ConfigWriteOutcome,
        ConfigWriteResult,
        ConfigWriteException;
export 'src/cli/install_command.dart'
    show
        runInstallCommand,
        InstallCommandResult,
        defaultMcpServerName,
        defaultMcpEntry,
        defaultConfigFile;
export 'src/bridge/vm_bridge.dart'
    show
        VmBridge,
        RealVmBridge,
        FakeVmBridge,
        VmBridgeException,
        SessionChangedException,
        VersionSkewValidator;
export 'src/tools/tools.dart' show defaultVersionSkewValidator;
export 'src/flutter_daemon/app_status.dart'
    show AppStatusPayload, AppSessionState;
export 'src/flutter_daemon/daemon_events.dart';
export 'src/flutter_daemon/daemon_parser.dart'
    show DaemonParser, minDaemonProtocolVersion, isAtLeastVersion;
export 'src/flutter_daemon/daemon_rpc.dart'
    show DaemonRpc, DaemonRpcException, DaemonRpcTimeoutException;
export 'src/flutter_daemon/daemon_session.dart'
    show DaemonSession, DaemonSessionException;
export 'src/mcp/mcp_server.dart'
    show
        DaemonSessionLifecycle,
        McpServer,
        ToolHandler,
        mcpProtocolVersion,
        supportedMcpProtocolVersions,
        sleuthMcpVersion,
        sleuthPackageVersionPin;
export 'src/mcp/mcp_types.dart';
export 'src/mcp/mcp_protocol.dart' show McpProtocolCodec;
export 'src/tools/budgets.dart' show evaluateBudgets;
export 'src/util/version_lineage.dart' show versionLineage;
