/// Protocol messages between the MacLauncher listener (server) and an
/// SDK application (client).
///
/// Transport: Unix domain socket, UTF-8 single-line JSON, protocol version 1.
library;

const int kProtocolVersion = 1;

/// Methods a service may declare.
const String kMethodStart = 'start';
const String kMethodRecycle = 'recycle';
const String kMethodStatus = 'status';
const String kMethodLogs = 'logs';

/// App-level methods.
const String kMethodOpenWindow = 'openWindow';
const String kMethodSetEntryManaged = 'setEntryManaged';
const String kMethodVersionStatus = 'versionStatus';

/// Business state reported by the application. Reading errors and SDK
/// disconnects must never be mapped to [ServiceState.failed] or
/// [ServiceState.stopped] by anyone but the application itself.
enum ServiceState {
  stopped,
  starting,
  running,
  stopping,
  failed,
  unknown;

  static ServiceState fromJson(String value) =>
      ServiceState.values.asNameMap()[value] ?? ServiceState.unknown;

  String toJson() => name;
}

/// A snapshot of one service's business state, as observed by the
/// application at [observedAt].
class ServiceStatus {
  ServiceStatus({
    required this.state,
    this.instanceId,
    this.ready,
    this.observedAt,
    this.message,
  });

  final ServiceState state;

  /// Identity of this specific run, provided by the application. Null when
  /// the application cannot provide one. Must never be a PID, app session or
  /// container name masquerading as an instance identity.
  final String? instanceId;

  /// Readiness per the application's own availability criteria. Null means
  /// not provided / unknown; only meaningful while running.
  final bool? ready;

  /// Real observation time (UTC). Null when unknown. Never substitute the
  /// local receive time for a missing observation time.
  final DateTime? observedAt;

  /// Optional human-readable note. Never fabricated exit codes or signals.
  final String? message;

  Map<String, Object?> toJson() => {
    'state': state.toJson(),
    'instanceId': instanceId,
    'ready': ready,
    'observedAt': observedAt?.toUtc().toIso8601String(),
    'message': message,
  };

  static ServiceStatus fromJson(Map<String, Object?> json) => ServiceStatus(
    state: ServiceState.fromJson(json['state'] as String? ?? 'unknown'),
    instanceId: json['instanceId'] as String?,
    ready: json['ready'] as bool?,
    observedAt: switch (json['observedAt']) {
      final String s => DateTime.tryParse(s)?.toUtc(),
      _ => null,
    },
    message: json['message'] as String?,
  );
}

enum LogStream {
  stdout,
  stderr,
  app,
  unknown;

  static LogStream fromJson(String value) =>
      LogStream.values.asNameMap()[value] ?? LogStream.unknown;

  String toJson() => name;
}

class LogEntry {
  LogEntry({
    required this.text,
    this.timestamp,
    this.stream = LogStream.unknown,
  });

  /// Required content line.
  final String text;

  /// Real write time (UTC), or null when the source has none. Never invented.
  final DateTime? timestamp;

  /// Reliable stream classification; [LogStream.unknown] when not available.
  final LogStream stream;

  Map<String, Object?> toJson() => {
    'text': text,
    'timestamp': timestamp?.toUtc().toIso8601String(),
    'stream': stream.toJson(),
  };

  static LogEntry fromJson(Map<String, Object?> json) => LogEntry(
    text: json['text'] as String? ?? '',
    timestamp: switch (json['timestamp']) {
      final String s => DateTime.tryParse(s)?.toUtc(),
      _ => null,
    },
    stream: LogStream.fromJson(json['stream'] as String? ?? 'unknown'),
  );
}

/// Query for a batch of recent logs.
class LogQuery {
  LogQuery({this.limit = kDefaultLogLimit})
    : assert(limit >= 1 && limit <= kMaxLogLimit);

  static const int kDefaultLogLimit = 200;
  static const int kMaxLogLimit = 500;

  final int limit;

  static LogQuery fromJson(Map<String, Object?>? json) {
    final raw = json?['limit'];
    final limit = raw is int ? raw.clamp(1, kMaxLogLimit) : kDefaultLogLimit;
    return LogQuery(limit: limit);
  }
}

/// The most recent batch of log content, oldest first, at most
/// [LogQuery.limit] entries.
class LogBatch {
  LogBatch({
    required this.entries,
    this.instanceId,
    this.truncated,
    this.observedAt,
  });

  final List<LogEntry> entries;

  /// Run scope this batch describes; null when unknown (callers must label
  /// it as not provided, never imply it covers the current run).
  final String? instanceId;

  /// Truncation judgement for this readable range only; null when unknown.
  final bool? truncated;

  /// The read moment of this batch; not a substitute for entry write times.
  final DateTime? observedAt;

  Map<String, Object?> toJson() => {
    'entries': entries.map((e) => e.toJson()).toList(),
    'instanceId': instanceId,
    'truncated': truncated,
    'observedAt': observedAt?.toUtc().toIso8601String(),
  };

  static LogBatch fromJson(Map<String, Object?> json) => LogBatch(
    entries: [
      for (final e in (json['entries'] as List? ?? const []))
        LogEntry.fromJson((e as Map).cast<String, Object?>()),
    ],
    instanceId: json['instanceId'] as String?,
    truncated: json['truncated'] as bool?,
    observedAt: switch (json['observedAt']) {
      final String s => DateTime.tryParse(s)?.toUtc(),
      _ => null,
    },
  );
}

/// One service's declared capabilities in the hello handshake.
class ServiceDeclaration {
  ServiceDeclaration({
    required this.id,
    required this.name,
    required this.methods,
  });

  /// Stable service identity, unique within the project.
  final String id;

  /// Display name only; never part of identity.
  final String name;

  /// Subset of start/recycle/status/logs the application actually supports.
  final List<String> methods;

  bool supports(String method) => methods.contains(method);

  Map<String, Object?> toJson() => {'id': id, 'name': name, 'methods': methods};

  static ServiceDeclaration fromJson(Map<String, Object?> json) =>
      ServiceDeclaration(
        id: json['id'] as String? ?? '',
        name: json['name'] as String? ?? '',
        methods: [
          for (final m in (json['methods'] as List? ?? const [])) m as String,
        ],
      );
}

/// Full capability set an application declares in hello.
class CapabilitySet {
  CapabilitySet({required this.services, this.app = const []});

  final List<ServiceDeclaration> services;

  /// Subset of openWindow/setEntryManaged/versionStatus the application
  /// supports.
  final List<String> app;

  bool supportsApp(String method) => app.contains(method);

  ServiceDeclaration? serviceById(String id) {
    for (final s in services) {
      if (s.id == id) return s;
    }
    return null;
  }

  Map<String, Object?> toJson() => {
    'services': services.map((s) => s.toJson()).toList(),
    'app': app,
  };

  static CapabilitySet fromJson(Map<String, Object?> json) => CapabilitySet(
    services: [
      for (final s in (json['services'] as List? ?? const []))
        ServiceDeclaration.fromJson((s as Map).cast<String, Object?>()),
    ],
    app: [for (final m in (json['app'] as List? ?? const [])) m as String],
  );
}

/// How the application's own update query concluded. The application alone
/// decides how it queries its update source; the launcher never guesses.
enum VersionQueryState {
  /// The query ran; [VersionStatus] fields describe what was found.
  success,

  /// The query failed; [VersionStatus.failureReason] carries the cause.
  failure,

  /// The application has no update channel to query.
  unsupported;

  static VersionQueryState fromJson(String value) =>
      // An unrecognized state is read as failure: it must never be
      // presented as a successful query.
      VersionQueryState.values.asNameMap()[value] ?? VersionQueryState.failure;

  String toJson() => name;
}

/// The application's answer to a version status query (版本状况).
///
/// All fields except [state] are optional: an unsupported answer may carry
/// nothing but the state, and a failed answer carries [failureReason].
/// Values pass through verbatim — the launcher displays them as reported
/// and never fabricates missing pieces.
class VersionStatus {
  VersionStatus({
    required this.state,
    this.currentVersion,
    this.hasUpdate,
    this.latestVersion,
    this.downloadUrl,
    this.failureReason,
    this.sha256,
  });

  /// The 「不支持更新」answer: the application has no update channel. The SDK
  /// sends this automatically when no version-status callback is registered.
  VersionStatus.unsupported() : this(state: VersionQueryState.unsupported);

  /// How the update query concluded.
  final VersionQueryState state;

  /// The version the application is currently running. Expected on success;
  /// null when the answering party cannot know (e.g. the SDK's automatic
  /// unsupported answer).
  final String? currentVersion;

  /// Whether a newer version exists. Null means not provided / unknown;
  /// only meaningful on success.
  final bool? hasUpdate;

  /// The newest known version. Null when unknown or not applicable.
  final String? latestVersion;

  /// Where the update package can be downloaded. Null when not applicable.
  final String? downloadUrl;

  /// Why the query failed; only meaningful on [VersionQueryState.failure].
  final String? failureReason;

  /// Optional integrity digest of the update package, for a later download
  /// step to verify. Passed through untouched.
  final String? sha256;

  Map<String, Object?> toJson() => {
    'state': state.toJson(),
    'currentVersion': currentVersion,
    'hasUpdate': hasUpdate,
    'latestVersion': latestVersion,
    'downloadUrl': downloadUrl,
    'failureReason': failureReason,
    'sha256': sha256,
  };

  static VersionStatus fromJson(Map<String, Object?> json) {
    String? stringOrNull(Object? value) => value is String ? value : null;
    final rawState = json['state'];
    final state = rawState is String
        ? VersionQueryState.fromJson(rawState)
        : VersionQueryState.failure;
    final failureReason = stringOrNull(json['failureReason']);
    return VersionStatus(
      state: state,
      currentVersion: stringOrNull(json['currentVersion']),
      hasUpdate: switch (json['hasUpdate']) {
        final bool b => b,
        _ => null,
      },
      latestVersion: stringOrNull(json['latestVersion']),
      downloadUrl: stringOrNull(json['downloadUrl']),
      // A missing/invalid state is surfaced as a failure with an explicit
      // reason instead of being silently dropped.
      failureReason:
          failureReason ??
          (rawState is String &&
                  VersionQueryState.values.asNameMap().containsKey(rawState)
              ? null
              : 'missing or invalid query state: $rawState'),
      sha256: stringOrNull(json['sha256']),
    );
  }
}

/// Error codes for response messages.
class ProtocolError {
  ProtocolError(this.code, this.message);

  /// unsupported | failed | busy | invalid
  final String code;
  final String message;

  static const String unsupported = 'unsupported';
  static const String failed = 'failed';
  static const String busy = 'busy';
  static const String invalid = 'invalid';

  Map<String, Object?> toJson() => {'code': code, 'message': message};

  static ProtocolError fromJson(Map<String, Object?> json) => ProtocolError(
    json['code'] as String? ?? failed,
    json['message'] as String? ?? '',
  );
}
