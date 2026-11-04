/// The same personal server is used by all Yomi clients. No credentials are built in.
const defaultServerUrl = String.fromEnvironment(
  'YOMI_SERVER',
  defaultValue: 'http://100.88.180.104:4533',
);
const defaultHomeServerUrl = String.fromEnvironment(
  'YOMI_HOME_SERVER',
  defaultValue: 'http://192.168.1.18:4533',
);
