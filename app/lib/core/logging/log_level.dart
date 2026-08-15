enum LogLevel {
  info,
  warn,
  error,
  fatal;

  String get label => switch (this) {
    LogLevel.info => 'INFO',
    LogLevel.warn => 'WARN',
    LogLevel.error => 'ERROR',
    LogLevel.fatal => 'FATAL',
  };
}
