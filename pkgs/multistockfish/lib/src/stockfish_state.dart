/// C++ engine state.
enum StockfishState {
  /// Engine is not running.
  initial,

  /// Engine is starting.
  starting,

  /// Engine is running, ready to receive commands.
  ready,

  /// An error occured, engine could not start.
  error,
}
