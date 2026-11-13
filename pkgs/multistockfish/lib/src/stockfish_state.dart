/// C++ engine state.
enum StockfishState {
  /// Engine is starting.
  ///
  /// Only seen before `Stockfish.create` completes, for instance from its
  /// `onStdout` callback.
  starting,

  /// Engine is running, ready to receive commands.
  ready,

  /// An error occurred: the engine could not start, or died on its own.
  error,

  /// The engine has been disposed and its flavor's slot freed.
  disposed,
}
