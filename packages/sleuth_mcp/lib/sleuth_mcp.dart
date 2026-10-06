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
export 'src/cli/attach_ios_command.dart'
    show
        runAttachIosCommand,
        AttachIosResult,
        BonjourAnnouncement,
        IosTransport,
        collectBonjourAnnouncements,
        detectIosTransport,
        parseReachedAtLine,
        parseAuthCodeLine,
        pidfileForSession,
        PidfileLockGuard,
        reclaimStaleIproxy,
        selectUsbAnnouncement,
        withPidfileLock;
export 'src/cli/ios_attach_pipeline.dart'
    show
        IosAttachErrorKind,
        IosAttachException,
        IosAttachOrigin,
        IosAttachPhase,
        IosAttachProgress,
        IosAttachResult,
        IosAttacher;
export 'src/cli/check_command.dart'
    show
        runCheckCommand,
        checkExitPass,
        checkExitViolation,
        checkExitNotRun,
        checkExitUsage;
export 'src/cli/serve_command.dart'
    show serveUntilExit, shutdownSignals, defaultStartupConnectWait;
export 'src/bridge/vm_bridge.dart'
    show
        VmBridge,
        RealVmBridge,
        FakeVmBridge,
        VmBridgeException,
        VmBridgeErrorKind,
        SessionChangedException,
        VersionSkewValidator,
        bridgeCallTimeoutWithin,
        normalizeVmServiceUri;
export 'src/tools/tools.dart'
    show defaultVersionSkewValidator, snapshotDiskHandoff;
export 'src/tools/snapshot_disk_handoff.dart' show SnapshotDiskHandoff;
export 'src/tools/snapshot_sections.dart'
    show
        snapshotSectionKeys,
        heavySnapshotSections,
        defaultSnapshotSections,
        snapshotMetadataKeys;
export 'src/flutter_daemon/app_status.dart'
    show AppStatusPayload, AppSessionState, ConnectedVia;
export 'src/flutter_daemon/daemon_events.dart';
export 'src/flutter_daemon/daemon_parser.dart'
    show DaemonParser, minDaemonProtocolVersion, isAtLeastVersion;
export 'src/flutter_daemon/daemon_rpc.dart'
    show DaemonRpc, DaemonRpcException, DaemonRpcTimeoutException;
export 'src/flutter_daemon/daemon_session.dart'
    show DaemonSession, DaemonSessionException, DetachBudget;
export 'src/mcp/mcp_server.dart'
    show
        DaemonSessionLifecycle,
        McpServer,
        ToolHandler,
        defaultExitDetachTimeout,
        mcpProtocolVersion,
        mcpServerInstructions,
        supportedMcpProtocolVersions,
        sleuthMcpVersion,
        sleuthPackageVersionPin;
export 'src/mcp/mcp_types.dart';
export 'src/mcp/mcp_protocol.dart' show McpProtocolCodec;
export 'src/tools/budgets.dart' show evaluateBudgets;
export 'src/util/version_lineage.dart' show versionLineage;
