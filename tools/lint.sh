#!/usr/bin/env bash
# tools/lint.sh — static checks that catch common porting bugs
#
# Run before every commit:  bash tools/lint.sh
# Exit code 0 = clean, 1 = violations found

ERRORS=0

echo "=== MORK lint checks ==="

# ── Check 1: oz.loc += outside Expr.jl ──────────────────────────────────────
# Write functions (ez_write_*!) own oz.loc advancement internally.
# Any oz.loc += in calling code is a double-advance → garbage output bytes.
VIOLATIONS=$(grep -rn "oz\.loc +=" src/ | grep -v "src/expr/Expr.jl")
if [ -n "$VIOLATIONS" ]; then
    echo ""
    echo "FAIL: oz.loc += found outside src/expr/Expr.jl (double-advance bug):"
    echo "$VIOLATIONS"
    ERRORS=$((ERRORS + 1))
else
    echo "PASS: no oz.loc double-advances"
fi

# ── Check 2: ez.loc never advanced for a tag branch ─────────────────────────
# Every branch in expr_apply's while loop must advance ez.loc.
# This is hard to check statically, but we can check for the known patterns:
# any if/elseif branch in ExprAlg.jl that handles a tag must contain ez.loc +=
EXPRFILE="src/expr/ExprAlg.jl"
if grep -q "if tag isa ExprNewVar" "$EXPRFILE"; then
    # Check that ez.loc += 1 appears after each ExprNewVar / ExprVarRef block
    NV_ADVANCES=$(awk '/if tag isa ExprNewVar/,/elseif tag isa ExprVarRef/' "$EXPRFILE" | grep -c "ez\.loc += 1")
    VR_ADVANCES=$(awk '/elseif tag isa ExprVarRef/,/elseif tag isa ExprSymbol/' "$EXPRFILE" | grep -c "ez\.loc += 1")
    if [ "$NV_ADVANCES" -ge 1 ] && [ "$VR_ADVANCES" -ge 1 ]; then
        echo "PASS: ez.loc advances present for NewVar and VarRef branches"
    else
        echo "FAIL: ez.loc not advanced in NewVar ($NV_ADVANCES) or VarRef ($VR_ADVANCES) branch"
        ERRORS=$((ERRORS + 1))
    fi
fi

# ── Check 3: sub_ez uses expr_span (not raw full buffer) ────────────────────
# sub_ez must be bounded to the sub-expression. Using full bound.base.buf
# causes expr_apply to process bytes past the expression end.
RAW_SUBEZ=$(grep -n "ExprZipper(MORK.Expr(bound.base.buf)" src/expr/ExprAlg.jl)
if [ -n "$RAW_SUBEZ" ]; then
    echo ""
    echo "FAIL: sub_ez created from raw full buffer (must use expr_span):"
    echo "$RAW_SUBEZ"
    ERRORS=$((ERRORS + 1))
else
    echo "PASS: sub_ez uses expr_span (bounded sub-expression)"
fi

# ── Check 4: integration tests have step-cap assertions ─────────────────────
if grep -q "steps < cap\|steps < STEP_CAP\|steps < max_steps" test/runtests.jl; then
    echo "PASS: integration tests assert steps < cap (infinite loop guard)"
else
    echo "FAIL: integration tests missing step-cap assertion"
    ERRORS=$((ERRORS + 1))
fi

# ── Check 5: no step cap > 100k in integration tests ────────────────────────
BIG_CAPS=$(grep -rn "metta_calculus.*[0-9_]\{8,\}" test/integration/*.jl 2>/dev/null | grep -v "#")
if [ -n "$BIG_CAPS" ]; then
    echo ""
    echo "FAIL: integration tests with step cap > 100k (will hang):"
    echo "$BIG_CAPS"
    ERRORS=$((ERRORS + 1))
else
    echo "PASS: all integration test step caps safe (<=100k)"
fi

# ── Check 6: halting assertion bound must match the cap actually passed ─────
# A `space_metta_calculus!(s, CAP)` followed by `@test steps < BOUND` with BOUND > CAP is
# VACUOUS — the call can never return more than CAP, so the halting check can never fail.
# Two of these existed (roman_disjoin_final, process_calculus_reverse): both were introduced
# by lowering caps to <=100k in 92124ea WITHOUT lowering the assertion bound left behind.
VACUOUS=$(awk '
    match($0, /space_metta_calculus!\([^,]+, *([0-9_]+)\)/, m) { cap = m[1]; gsub(/_/, "", cap); f = FILENAME; l = FNR; next }
    cap != "" && match($0, /@test +steps *< *([0-9_]+)/, b) {
        bound = b[1]; gsub(/_/, "", bound)
        if (bound + 0 > cap + 0) printf "%s:%d: asserts steps < %s but cap is %s\n", f, l, b[1], cap
        cap = ""
    }
    /@test/ && cap != "" && !/steps *</ { next }
' test/integration/*.jl test/runtests.jl 2>/dev/null)
if [ -n "$VACUOUS" ]; then
    echo ""
    echo "FAIL: vacuous halting assertion (bound exceeds the cap passed — can never fail):"
    echo "$VACUOUS"
    ERRORS=$((ERRORS + 1))
else
    echo "PASS: all halting assertions bounded by their actual step cap"
fi

# ── Summary ─────────────────────────────────────────────────────────────────
echo ""
if [ $ERRORS -eq 0 ]; then
    echo "All lint checks passed."
    exit 0
else
    echo "$ERRORS lint check(s) failed."
    exit 1
fi
