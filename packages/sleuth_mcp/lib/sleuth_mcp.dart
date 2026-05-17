/// `sleuth_mcp` — MCP stdio sidecar for the sleuth Flutter performance
/// diagnostics package.
library;

export 'src/bridge/vm_bridge.dart'
    show
        VmBridge,
        RealVmBridge,
        FakeVmBridge,
        VmBridgeException,
        SessionChangedException;
export 'src/mcp/mcp_server.dart'
    show
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
