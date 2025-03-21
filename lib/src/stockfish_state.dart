/// C++ engine state.
enum StockfishState {
  /// Engine has been stopped.
  disposed,

  /// An error occured (engine could not start).
  error,

  /// Engine is running, ready to receive commands.
  ready,

  /// Engine is starting.
  starting,

  /// Engine is initializing.
  initial,
}
