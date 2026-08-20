/// C++ engine state.
enum StockfishState {
  /// Engine is not running.
  ///
  /// Only reachable through the deprecated `Stockfish.instance`, which can be
  /// started again. An engine from `Stockfish.create` is already running.
  initial,

  /// Engine is starting.
  starting,

  /// Engine is running, ready to receive commands.
  ready,

  /// An error occurred: the engine could not start, or died on its own.
  error,

  /// The engine has been disposed and its flavor's slot freed.
  disposed,
}
