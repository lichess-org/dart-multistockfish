/// The flavor of Stockfish to use.
enum StockfishFlavor {
  /// Stockfish engine version 19 with a small embedded NNUE (~1MB).
  ///
  /// Ready to evaluate as soon as it starts, with no net to download, at the
  /// cost of some strength compared to [latestNoNNUE]'s full-size net.
  light,

  /// Latest Stockfish engine version without embedded NNUE.
  ///
  /// The net is not part of the binary, so it must be downloaded and its path
  /// passed to `Stockfish.create(nnuePath: ...)`.
  latestNoNNUE,

  /// Multi-Variant Stockfish using Handcrafted Evaluation for chess and chess variants
  variant,
}
