/// The flavor of Stockfish to use.
enum StockfishFlavor {
  /// Stockfish engine version 16 with embedded NNUE
  sf16,

  /// Latest Stockfish engine version without embedded NNUE
  latestNoNNUE,

  /// Multi-Variant Stockfish using Handcrafted Evaluation for chess and chess variants
  variant,
}
