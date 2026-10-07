/// MacLauncher SDK: public integration surface for standalone applications.
library;

export 'src/client.dart'
    show
        AppCallbacks,
        MacLauncherSdk,
        SdkConnectionState,
        SdkConnectionStatus,
        ServiceCallbacks;
export 'src/entry_report.dart' show SdkEntry, SdkEntryKind;
export 'src/protocol/codec.dart' show decodeMessages, writeMessage;
export 'src/protocol/messages.dart';
