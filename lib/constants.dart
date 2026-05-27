/// App-wide identifier constants.
///
/// Centralized here so a future domain change (e.g. swap `cc.merr.*` for a
/// project-specific domain) only touches this file.
library;

const String kReverseDomain = 'cc.merr.dufshub';
const String kMethodChannel = '$kReverseDomain/native';
