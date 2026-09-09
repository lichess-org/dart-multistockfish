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

#include "nnue_accumulator.h"

#include <algorithm>
#include <cassert>
#include <new>

#include "../bitboard.h"
#include "../misc.h"
#include "../position.h"
#include "../types.h"
#include "nnue_architecture.h"
#include "nnue_common.h"
#include "nnue_feature_transformer.h"  // IWYU pragma: keep
#include "simd.h"

namespace StockfishLight::Eval::NNUE {

using namespace SIMD;

namespace {

template<bool Forward>
void update_accumulator_incremental(Color                     perspective,
                                    const FeatureTransformer& featureTransformer,
                                    const Square              ksq,
                                    AccumulatorState&         target_state,
                                    const AccumulatorState&   computed);

void update_accumulator_incremental_both(const FeatureTransformer& featureTransformer,
                                         Square                    white_ksq,
                                         Square                    black_ksq,
                                         AccumulatorState&         target_state,
                                         const AccumulatorState&   computed);

void update_accumulator_refresh_cache(Color                     perspective,
                                      const FeatureTransformer& featureTransformer,
                                      const Position&           pos,
                                      AccumulatorState&         accumulatorState,
                                      AccumulatorCaches&        cache);
}

const AccumulatorState& AccumulatorStack::latest() const noexcept { return accumulators[size - 1]; }

AccumulatorState& AccumulatorStack::mut_latest() noexcept { return accumulators[size - 1]; }

void AccumulatorStack::reset() noexcept {
    accumulators[0].dirtyPiece = {};
    accumulators[0].computed.fill(false);
    size = 1;
}

DirtyPiece& AccumulatorStack::push() noexcept {
    assert(size < MaxSize);
    auto& st = accumulators[size];
    st.computed.fill(false);
    size++;
    return st.dirtyPiece;
}

void AccumulatorStack::pop() noexcept {
    assert(size > 1);
    size--;
}

void AccumulatorStack::evaluate(const Position&           pos,
                                const FeatureTransformer& featureTransformer,
                                // Silence spurious warning on GCC 10
                                [[maybe_unused]] AccumulatorCaches& cache) noexcept {
    const usize last_white = find_last_usable_accumulator(WHITE);
    const usize last_black = find_last_usable_accumulator(BLACK);

    if (accumulators[last_white].computed[WHITE] && accumulators[last_black].computed[BLACK])
        forward_update_incremental_both(pos, featureTransformer, last_white, last_black);
    else
    {
        evaluate_side(WHITE, pos, featureTransformer, cache, last_white);
        evaluate_side(BLACK, pos, featureTransformer, cache, last_black);
    }
}

void AccumulatorStack::evaluate_side(Color                     perspective,
                                     const Position&           pos,
                                     const FeatureTransformer& featureTransformer,
                                     AccumulatorCaches&        cache,
                                     usize                     last_usable_accum) noexcept {

    if (accumulators[last_usable_accum].computed[perspective])
        forward_update_incremental(perspective, pos, featureTransformer, last_usable_accum);

    else
    {
        update_accumulator_refresh_cache(perspective, featureTransformer, pos, mut_latest(), cache);
        backward_update_incremental(perspective, pos, featureTransformer, last_usable_accum);
    }
}

// Find the earliest usable accumulator, this can either be a computed accumulator or the accumulator
// state just before a change that requires full refresh.
usize AccumulatorStack::find_last_usable_accumulator(Color perspective) const noexcept {

    for (usize curr_idx = size - 1; curr_idx > 0; curr_idx--)
    {
        if (accumulators[curr_idx].computed[perspective])
            return curr_idx;

        if (FeatureSet::requires_refresh(accumulators[curr_idx].dirtyPiece, perspective))
            return curr_idx;
    }

    return 0;
}

void AccumulatorStack::forward_update_incremental(Color                     perspective,
                                                  const Position&           pos,
                                                  const FeatureTransformer& featureTransformer,
                                                  const usize               begin) noexcept {

    assert(begin < accumulators.size());
    assert(accumulators[begin].computed[perspective]);

    const Square ksq = pos.square<KING>(perspective);

    for (usize next = begin + 1; next < size; next++)
        update_accumulator_incremental<true>(perspective, featureTransformer, ksq,
                                             accumulators[next], accumulators[next - 1]);

    assert(latest().computed[perspective]);
}

void AccumulatorStack::backward_update_incremental(Color                     perspective,
                                                   const Position&           pos,
                                                   const FeatureTransformer& featureTransformer,
                                                   const usize               end) noexcept {

    assert(end < accumulators.size());
    assert(end < size);
    assert(latest().computed[perspective]);

    const Square ksq = pos.square<KING>(perspective);

    for (i64 next = i64(size) - 2; next >= i64(end); next--)
        update_accumulator_incremental<false>(perspective, featureTransformer, ksq,
                                              accumulators[next], accumulators[next + 1]);

    assert(accumulators[end].computed[perspective]);
}

void AccumulatorStack::forward_update_incremental_both(const Position&           pos,
                                                       const FeatureTransformer& featureTransformer,
                                                       usize                     white_begin,
                                                       usize black_begin) noexcept {

    assert(white_begin < size);
    assert(black_begin < size);
    assert(accumulators[white_begin].computed[WHITE]);
    assert(accumulators[black_begin].computed[BLACK]);

    const Square white_ksq    = pos.square<KING>(WHITE);
    const Square black_ksq    = pos.square<KING>(BLACK);
    const usize  shared_begin = std::max(white_begin, black_begin);

    // Catch up the lagging perspective, then traverse the common suffix once.
    for (usize next = white_begin + 1; next <= shared_begin; ++next)
        update_accumulator_incremental<true>(WHITE, featureTransformer, white_ksq,
                                             accumulators[next], accumulators[next - 1]);
    for (usize next = black_begin + 1; next <= shared_begin; ++next)
        update_accumulator_incremental<true>(BLACK, featureTransformer, black_ksq,
                                             accumulators[next], accumulators[next - 1]);

    for (usize next = shared_begin + 1; next < size; ++next)
        update_accumulator_incremental_both(featureTransformer, white_ksq, black_ksq,
                                            accumulators[next], accumulators[next - 1]);

    assert(latest().computed[WHITE]);
    assert(latest().computed[BLACK]);
}

namespace {

constexpr IndexType Dimensions = FeatureTransformer::OutputDimensions;

#ifdef USE_RVV

struct Tiling {
    static constexpr int NumRegs     = 1;
    static constexpr int NumPsqtRegs = 1;
};

using Tile     = vint16m8_t;
using PsqtTile = vint32m1_t;

sf_always_inline Tile load_tile(IndexType j, const i16* data) {
    usize vl = __riscv_vsetvl_e16m8(Dimensions - j);
    return __riscv_vle16_v_i16m8(data + j, vl);
}

sf_always_inline void store_tile(IndexType j, i16* dest, Tile acc) {
    usize vl = __riscv_vsetvl_e16m8(Dimensions - j);
    __riscv_vse16_v_i16m8(dest + j, acc, vl);
}

sf_always_inline PsqtTile load_psqt(IndexType j, const i32* data) {
    usize vl = __riscv_vsetvl_e32m1(PSQTBuckets - j);
    return __riscv_vle32_v_i32m1(data + j, vl);
}

sf_always_inline void store_psqt(IndexType j, i32* dest, PsqtTile psqt) {
    usize vl = __riscv_vsetvl_e32m1(PSQTBuckets - j);
    __riscv_vse32_v_i32m1(dest + j, psqt, vl);
}

sf_always_inline void increment_index(IndexType& j) { j += __riscv_vsetvl_e16m8(Dimensions - j); }

sf_always_inline void increment_psqt_index(IndexType& j) {
    j += __riscv_vsetvl_e32m1(PSQTBuckets - j);
}

template<int sign>
sf_always_inline Tile apply(IndexType j, Tile acc, const i16* data) {
    static_assert(sign == 1 || sign == -1);
    usize      vl       = __riscv_vsetvl_e16m8(Dimensions - j);
    vint16m8_t data_vec = __riscv_vle16_v_i16m8(data + j, vl);
    if constexpr (sign == +1)
        acc = __riscv_vadd_vv_i16m8(acc, data_vec, vl);
    else
        acc = __riscv_vsub_vv_i16m8(acc, data_vec, vl);
    return acc;
}

template<int sign>
sf_always_inline PsqtTile apply(IndexType j, PsqtTile acc, const i32* data) {
    static_assert(sign == 1 || sign == -1);
    usize      vl       = __riscv_vsetvl_e32m1(PSQTBuckets - j);
    vint32m1_t data_vec = __riscv_vle32_v_i32m1(data + j, vl);
    if constexpr (sign == +1)
        acc = __riscv_vadd_vv_i32m1(acc, data_vec, vl);
    else
        acc = __riscv_vsub_vv_i32m1(acc, data_vec, vl);
    return acc;
}

#else  // VECTOR or non VECTOR

    #ifdef VECTOR

using Tiling = SIMDTiling<Dimensions, Dimensions, PSQTBuckets>;

    #else

// Treat scalar impl as degenerate size-1 vector
struct Tiling {
    static constexpr int NumRegs        = 1;
    static constexpr int NumPsqtRegs    = 1;
    static constexpr int TileHeight     = 1;
    static constexpr int PsqtTileHeight = 1;
};

using vec_t      = i16;
using vec_i8_t   = i8;
using psqt_vec_t = i32;

        #define vec_add_16(a, b) ((a) + (b))
        #define vec_sub_16(a, b) ((a) - (b))
        #define vec_add_psqt_32(a, b) ((a) + (b))
        #define vec_sub_psqt_32(a, b) ((a) - (b))
        #define vec_convert_8_16(a) (i16(a))

    #endif

struct PsqtTile {
    psqt_vec_t inner[Tiling::NumPsqtRegs];
    auto&      operator[](int i) { return inner[i]; }
};

struct Tile {
    vec_t inner[Tiling::NumRegs];
    auto& operator[](int i) { return inner[i]; }
};

sf_always_inline Tile load_tile(IndexType j, const i16* data) {
    Tile  acc;
    auto* column = reinterpret_cast<const vec_t*>(&data[j]);
    for (IndexType k = 0; k < Tiling::NumRegs; ++k)
        acc[k] = column[k];
    return acc;
}

sf_always_inline void store_tile(IndexType j, i16* dest, Tile acc) {
    auto* column = reinterpret_cast<vec_t*>(&dest[j]);
    for (IndexType k = 0; k < Tiling::NumRegs; ++k)
        column[k] = acc[k];
}

sf_always_inline PsqtTile load_psqt(IndexType j, const i32* data) {
    PsqtTile psqt;
    auto*    column = reinterpret_cast<const psqt_vec_t*>(&data[j]);
    for (IndexType k = 0; k < Tiling::NumPsqtRegs; ++k)
        psqt[k] = column[k];
    return psqt;
}

sf_always_inline void store_psqt(IndexType j, i32* dest, PsqtTile psqt) {
    auto* column = reinterpret_cast<psqt_vec_t*>(&dest[j]);
    for (IndexType k = 0; k < Tiling::NumPsqtRegs; ++k)
        column[k] = psqt[k];
}

sf_always_inline void increment_index(IndexType& j) { j += Tiling::TileHeight; }

sf_always_inline void increment_psqt_index(IndexType& j) { j += Tiling::PsqtTileHeight; }

template<int sign>
sf_always_inline Tile apply(IndexType j, Tile acc, const i16* data) {
    const auto* column = reinterpret_cast<const vec_t*>(data + j);
    for (IndexType k = 0; k < Tiling::NumRegs; ++k)
        if constexpr (sign == +1)
            acc[k] = vec_add_16(acc[k], column[k]);
        else
            acc[k] = vec_sub_16(acc[k], column[k]);
    return acc;
}

template<int sign>
sf_always_inline PsqtTile apply(IndexType j, PsqtTile acc, const i32* data) {
    const auto* column = reinterpret_cast<const psqt_vec_t*>(data + j);
    for (IndexType k = 0; k < Tiling::NumPsqtRegs; ++k)
        if constexpr (sign == +1)
            acc[k] = vec_add_psqt_32(acc[k], column[k]);
        else
            acc[k] = vec_sub_psqt_32(acc[k], column[k]);
    return acc;
}

#endif

template<int sign, bool Incremental = false>
sf_always_inline Tile apply_psq_features(IndexType                    j,
                                         Tile                         acc,
                                         const FeatureSet::IndexList& list,
                                         const FeatureTransformer&    ft) {
    static_assert(sign == 1 || sign == -1);
    if constexpr (Incremental)
    {
        assert(list.size() == 1 || list.size() == 2);
        acc = apply<sign>(j, acc, &ft.weights[list[0] * Dimensions]);
        if (list.size() > 1)
            acc = apply<sign>(j, acc, &ft.weights[list[1] * Dimensions]);
        return acc;
    }
    for (int i = 0; i < list.ssize(); ++i)
        acc = apply<sign>(j, acc, &ft.weights[list[i] * Dimensions]);
    return acc;
}

template<int sign, typename IdxType, usize MaxLen>
sf_always_inline PsqtTile apply_psqt(IndexType                         j,
                                     PsqtTile                          acc,
                                     const ValueList<IdxType, MaxLen>& list,
                                     const PSQTWeightType*             weights) {
    static_assert(sign == 1 || sign == -1);
    for (int i = 0; i < list.ssize(); ++i)
        acc = apply<sign>(j, acc, &weights[list[i] * PSQTBuckets]);
    return acc;
}

void apply_features(Color                        perspective,
                    const FeatureTransformer&    featureTransformer,
                    const AccumulatorState&      from,
                    AccumulatorState&            to,
                    const FeatureSet::IndexList& added,
                    const FeatureSet::IndexList& removed) {

    const auto& fromAcc = from.accumulation[perspective];
    auto&       toAcc   = to.accumulation[perspective];

    const auto& fromPsqtAcc = from.psqtAccumulation[perspective];
    auto&       toPsqtAcc   = to.psqtAccumulation[perspective];

    Tile     acc;
    PsqtTile psqt;

    for (IndexType j = 0; j < Dimensions; increment_index(j))
    {
        acc = load_tile(j, fromAcc.data());

        acc = apply_psq_features<-1, true>(j, acc, removed, featureTransformer);
        acc = apply_psq_features<+1, true>(j, acc, added, featureTransformer);

        store_tile(j, toAcc.data(), acc);
    }

    for (IndexType j = 0; j < PSQTBuckets; increment_psqt_index(j))
    {
        psqt = load_psqt(j, fromPsqtAcc.data());

        psqt = apply_psqt<-1>(j, psqt, removed, featureTransformer.psqtWeights.data());
        psqt = apply_psqt<+1>(j, psqt, added, featureTransformer.psqtWeights.data());

        store_psqt(j, toPsqtAcc.data(), psqt);
    }
}

template<bool Forward>
void update_accumulator_incremental(Color                     perspective,
                                    const FeatureTransformer& featureTransformer,
                                    const Square              ksq,
                                    AccumulatorState&         target_state,
                                    const AccumulatorState&   computed) {

    assert(computed.computed[perspective]);
    assert(!target_state.computed[perspective]);

    // The size must be enough to contain the largest possible update.
    // That might depend on the feature set and generally relies on the
    // feature set's update cost calculation to be correct and never allow
    // updates with more added/removed features than MaxActiveDimensions.
    FeatureSet::IndexList removed, added;

    const auto& dirtyPiece = Forward ? target_state.dirtyPiece : computed.dirtyPiece;

    if constexpr (Forward)
        FeatureSet::append_changed_indices(perspective, ksq, dirtyPiece, removed, added);
    else
        FeatureSet::append_changed_indices(perspective, ksq, dirtyPiece, added, removed);

    apply_features(perspective, featureTransformer, computed, target_state, added, removed);

    target_state.computed[perspective] = true;
}

void update_accumulator_incremental_both(const FeatureTransformer& featureTransformer,
                                         Square                    white_ksq,
                                         Square                    black_ksq,
                                         AccumulatorState&         target_state,
                                         const AccumulatorState&   computed) {

    assert(computed.computed[WHITE]);
    assert(computed.computed[BLACK]);
    assert(!target_state.computed[WHITE]);
    assert(!target_state.computed[BLACK]);

    FeatureSet::IndexList removed[COLOR_NB], added[COLOR_NB];

    FeatureSet::append_changed_indices(WHITE, white_ksq, target_state.dirtyPiece, removed[WHITE],
                                       added[WHITE]);
    FeatureSet::append_changed_indices(BLACK, black_ksq, target_state.dirtyPiece, removed[BLACK],
                                       added[BLACK]);

    apply_features(WHITE, featureTransformer, computed, target_state, added[WHITE],
                   removed[WHITE]);
    apply_features(BLACK, featureTransformer, computed, target_state, added[BLACK],
                   removed[BLACK]);

    target_state.computed[WHITE] = true;
    target_state.computed[BLACK] = true;
}

Bitboard get_changed_pieces(const std::array<Piece, SQUARE_NB>& oldPieces,
                            const std::array<Piece, SQUARE_NB>& newPieces) {
#if defined(USE_AVX2)
    static_assert(sizeof(Piece) == 1);
    Bitboard sameBB = 0;

    for (int i = 0; i < 64; i += 32)
    {
        const __m256i old_v = _mm256_loadu_si256(reinterpret_cast<const __m256i*>(&oldPieces[i]));
        const __m256i new_v = _mm256_loadu_si256(reinterpret_cast<const __m256i*>(&newPieces[i]));
        const __m256i cmpEqual  = _mm256_cmpeq_epi8(old_v, new_v);
        const u32     equalMask = _mm256_movemask_epi8(cmpEqual);
        sameBB |= static_cast<Bitboard>(equalMask) << i;
    }
    return ~sameBB;
#elif defined(USE_LASX)
    static_assert(sizeof(Piece) == 1);

    Bitboard changed = 0;

    for (int i = 0; i < 64; i += 32)
    {
        const __m256i old_v = __lasx_xvld(reinterpret_cast<const void*>(&oldPieces[i]), 0);
        const __m256i new_v = __lasx_xvld(reinterpret_cast<const void*>(&newPieces[i]), 0);
        const __m256i diff  = __lasx_xvxor_v(old_v, new_v);
        const __m256i mask  = __lasx_xvmsknz_b(diff);
        const auto    lo    = __lasx_xvpickve2gr_d(mask, 0);
        const auto    hi    = __lasx_xvpickve2gr_d(mask, 2);

        changed |= (static_cast<Bitboard>(lo) | (static_cast<Bitboard>(hi) << 16)) << i;
    }

    return changed;
#elif defined(USE_LSX)
    static_assert(sizeof(Piece) == 1);

    Bitboard changed = 0;

    for (int i = 0; i < 64; i += 16)
    {
        const __m128i old_v = __lsx_vld(reinterpret_cast<const void*>(&oldPieces[i]), 0);
        const __m128i new_v = __lsx_vld(reinterpret_cast<const void*>(&newPieces[i]), 0);
        const __m128i diff  = __lsx_vxor_v(old_v, new_v);
        const __m128i mask  = __lsx_vmsknz_b(diff);

        changed |= static_cast<Bitboard>(__lsx_vpickve2gr_d(mask, 0)) << i;
    }

    return changed;
#elif defined(USE_NEON)
    uint8x16x4_t old_v = vld4q_u8(reinterpret_cast<const u8*>(oldPieces.data()));
    uint8x16x4_t new_v = vld4q_u8(reinterpret_cast<const u8*>(newPieces.data()));
    auto         cmp   = [=](const int i) { return vceqq_u8(old_v.val[i], new_v.val[i]); };

    uint8x16_t cmp0_1 = vsriq_n_u8(cmp(1), cmp(0), 1);
    uint8x16_t cmp2_3 = vsriq_n_u8(cmp(3), cmp(2), 1);
    uint8x16_t merged = vsriq_n_u8(cmp2_3, cmp0_1, 2);
    merged            = vsriq_n_u8(merged, merged, 4);
    uint8x8_t sameBB  = vshrn_n_u16(vreinterpretq_u16_u8(merged), 4);

    return ~vget_lane_u64(vreinterpret_u64_u8(sameBB), 0);
#elif defined(USE_SSE2)
    Bitboard sameBB = 0;

    for (int i = 0; i < 64; i += 16)
    {
        const __m128i old_v = _mm_loadu_si128(reinterpret_cast<const __m128i*>(&oldPieces[i]));
        const __m128i new_v = _mm_loadu_si128(reinterpret_cast<const __m128i*>(&newPieces[i]));
        const __m128i same  = _mm_cmpeq_epi8(old_v, new_v);

        sameBB |= static_cast<Bitboard>(_mm_movemask_epi8(same)) << i;
    }

    return ~sameBB;
#elif defined(USE_RVV)

    #define IMPL(mx, bx) \
        return __riscv_vmv_x_s_u64m1_u64(__riscv_vreinterpret_v_u8m1_u64m1( \
          __riscv_vreinterpret_v_b##bx##_u8m1(__riscv_vmsne_vv_i8m##mx##_b##bx( \
            __riscv_vle8_v_i8m##mx(reinterpret_cast<const i8*>(oldPieces.data()), 64), \
            __riscv_vle8_v_i8m##mx(reinterpret_cast<const i8*>(newPieces.data()), 64), 64))))


    usize vl = __riscv_vsetvlmax_e8m1();
    if (vl >= 64)
        IMPL(1, 8);
    else if (vl == 32)
        IMPL(2, 4);
    else
        IMPL(4, 2);

    #undef IMPL

#else
    Bitboard changed = 0;

    for (Square sq = SQUARE_ZERO; sq < SQUARE_NB; ++sq)
        changed |= static_cast<Bitboard>(oldPieces[sq] != newPieces[sq]) << sq;

    return changed;
#endif
}

void update_accumulator_refresh_cache(Color                     perspective,
                                      const FeatureTransformer& featureTransformer,
                                      const Position&           pos,
                                      AccumulatorState&         accumulator,
                                      AccumulatorCaches&        cache) {

    const Square          ksq   = pos.square<KING>(perspective);
    auto&                 entry = cache[FeatureSet::refresh_bucket(ksq)][perspective];
    FeatureSet::IndexList removed, added;

    const Bitboard changedBB = get_changed_pieces(entry.pieces, pos.piece_array());
    Bitboard       removedBB = changedBB & entry.pieceBB;
    Bitboard       addedBB   = changedBB & pos.pieces();

#if defined(USE_AVX512ICL)
    FeatureSet::write_indices(entry.pieces, pos.piece_array(), removedBB, addedBB, perspective, ksq,
                              removed, added);
#else
    while (removedBB)
    {
        Square sq = pop_lsb(removedBB);
        removed.push_back(FeatureSet::make_index(perspective, sq, entry.pieces[sq], ksq));
    }
    while (addedBB)
    {
        Square sq = pop_lsb(addedBB);
        added.push_back(FeatureSet::make_index(perspective, sq, pos.piece_on(sq), ksq));
    }
#endif

    entry.pieceBB = pos.pieces();
    entry.pieces  = pos.piece_array();

    accumulator.computed[perspective] = true;

    Tile     acc;
    PsqtTile psqt;

    for (IndexType j = 0; j < Dimensions; increment_index(j))
    {
        acc = load_tile(j, entry.accumulation.data());

        acc = apply_psq_features<-1>(j, acc, removed, featureTransformer);
        acc = apply_psq_features<+1>(j, acc, added, featureTransformer);

        store_tile(j, &entry.accumulation[0], acc);
        store_tile(j, accumulator.accumulation[perspective].data(), acc);
    }

    for (IndexType j = 0; j < PSQTBuckets; increment_psqt_index(j))
    {
        psqt = load_psqt(j, entry.psqtAccumulation.data());

        psqt = apply_psqt<-1>(j, psqt, removed, featureTransformer.psqtWeights.data());
        psqt = apply_psqt<+1>(j, psqt, added, featureTransformer.psqtWeights.data());

        store_psqt(j, entry.psqtAccumulation.data(), psqt);
        store_psqt(j, accumulator.psqtAccumulation[perspective].data(), psqt);
    }
}

}

}
