/*
  Stockfish, a UCI chess playing engine derived from Glaurung 2.1
  Copyright (C) 2004-2026 The Stockfish developers (see AUTHORS file)

  Stockfish is free software: you can redistribute it and/or modify
  it under the terms of the GNU General Public License as published by
  the Free Software Foundation, either version 3 of the License, or
  (at your option) any later version.

  Stockfish is distributed in the hope that it will be useful,
  but WITHOUT ANY WARRANTY; without even the implied warranty of
  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
  GNU General Public License for more details.

  You should have received a copy of the GNU General Public License
  along with this program.  If not, see <http://www.gnu.org/licenses/>.
*/

// Definition of input features P_hm of NNUE evaluation function

#ifndef NNUE_FEATURES_P_HM_H_INCLUDED
#define NNUE_FEATURES_P_HM_H_INCLUDED

#include "../../misc.h"
#include "../../types.h"
#include "../nnue_common.h"

namespace StockfishLight::Eval::NNUE::Features {

// Feature P_hm: The color-relative piece and its square. The position is
// mirrored horizontally such that the friendly king is always on e..h files.
class P_hm {

    enum {
        PS_NONE     = 0,
        PS_W_PAWN   = 0,
        PS_W_KNIGHT = 1 * SQUARE_NB,
        PS_W_BISHOP = 2 * SQUARE_NB,
        PS_W_ROOK   = 3 * SQUARE_NB,
        PS_W_QUEEN  = 4 * SQUARE_NB,
        PS_W_KING   = 5 * SQUARE_NB,
        PS_B_PAWN   = 6 * SQUARE_NB,
        PS_B_KNIGHT = 7 * SQUARE_NB,
        PS_B_BISHOP = 8 * SQUARE_NB,
        PS_B_ROOK   = 9 * SQUARE_NB,
        PS_B_QUEEN  = 10 * SQUARE_NB,
        PS_B_KING   = 11 * SQUARE_NB,
        PS_NB       = 12 * SQUARE_NB
    };

    alignas(64) static constexpr u16 PieceSquareIndex[COLOR_NB][PIECE_NB] = {
      // Convention: W - us, B - them. Viewed from the other side, W and B are reversed.
      {PS_NONE, PS_W_PAWN, PS_W_KNIGHT, PS_W_BISHOP, PS_W_ROOK, PS_W_QUEEN, PS_W_KING, PS_NONE,
       PS_NONE, PS_B_PAWN, PS_B_KNIGHT, PS_B_BISHOP, PS_B_ROOK, PS_B_QUEEN, PS_B_KING, PS_NONE},
      {PS_NONE, PS_B_PAWN, PS_B_KNIGHT, PS_B_BISHOP, PS_B_ROOK, PS_B_QUEEN, PS_B_KING, PS_NONE,
       PS_NONE, PS_W_PAWN, PS_W_KNIGHT, PS_W_BISHOP, PS_W_ROOK, PS_W_QUEEN, PS_W_KING, PS_NONE}};

   public:
    // Hash value embedded in the evaluation file
    static constexpr u32 HashValue = 0x6f234cb8u;

    // One feature for each of 12 color-relative piece types on each square.
    static constexpr IndexType Dimensions = PS_NB;

    // Horizontal orientation according to the friendly king square.
    // Perspective rotation is applied separately.
    static constexpr IndexType OrientTBL[SQUARE_NB] = {
      SQ_H1, SQ_H1, SQ_H1, SQ_H1, SQ_A1, SQ_A1, SQ_A1, SQ_A1, SQ_H1, SQ_H1, SQ_H1, SQ_H1, SQ_A1,
      SQ_A1, SQ_A1, SQ_A1, SQ_H1, SQ_H1, SQ_H1, SQ_H1, SQ_A1, SQ_A1, SQ_A1, SQ_A1, SQ_H1, SQ_H1,
      SQ_H1, SQ_H1, SQ_A1, SQ_A1, SQ_A1, SQ_A1, SQ_H1, SQ_H1, SQ_H1, SQ_H1, SQ_A1, SQ_A1, SQ_A1,
      SQ_A1, SQ_H1, SQ_H1, SQ_H1, SQ_H1, SQ_A1, SQ_A1, SQ_A1, SQ_A1, SQ_H1, SQ_H1, SQ_H1, SQ_H1,
      SQ_A1, SQ_A1, SQ_A1, SQ_A1, SQ_H1, SQ_H1, SQ_H1, SQ_H1, SQ_A1, SQ_A1, SQ_A1, SQ_A1};

    static constexpr IndexType MaxActiveDimensions = 32;
    using IndexList                                = ValueList<u16, MaxActiveDimensions>;
    using DiffType                                 = DirtyPiece;

#if defined(USE_AVX512ICL)
    static void write_indices(const std::array<Piece, SQUARE_NB>& oldPieces,
                              const std::array<Piece, SQUARE_NB>& newPieces,
                              Bitboard                            removedBB,
                              Bitboard                            addedBB,
                              Color                               perspective,
                              Square                              ksq,
                              IndexList&                          removed,
                              IndexList&                          added);
#endif

    static IndexType make_index(Color perspective, Square s, Piece pc, Square ksq);

    static void append_changed_indices(
      Color perspective, Square ksq, const DiffType& diff, IndexList& removed, IndexList& added);

    static bool requires_refresh(const DiffType& diff, Color perspective);

    static constexpr IndexType refresh_bucket(Square ksq) { return OrientTBL[ksq] == SQ_H1; }
};

static_assert(P_hm::Dimensions == 12 * SQUARE_NB);

}  // namespace StockfishLight::Eval::NNUE::Features

#endif  // #ifndef NNUE_FEATURES_P_HM_H_INCLUDED
