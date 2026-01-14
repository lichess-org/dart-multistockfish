/// C++ engine state.
enum StockfishState {
  /// Engine is disposed (cannot be used anymore).
  disposed,

  /// An error occured, engine could not start (cannot be used anymore).
  error,

  /// Engine is running, ready to receive commands.
  ready,

  /// Engine is starting.
  starting,

  /// Engine is not yet started.
  initial,
}
