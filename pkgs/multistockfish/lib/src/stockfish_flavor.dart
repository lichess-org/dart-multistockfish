/// The flavor of Stockfish to use.
enum StockfishFlavor {
  /// Regular NNUE Stockfish engine for chess and chess960
  chess,

  /// Multi-Variant Stockfish using Handcrafted Evaluation for chess and chess variants
  variant,
}
