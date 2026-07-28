## Initial impressions before running 
- A deeply nested exec, I hope this is not spawning execs frequently
- Loading from ACT to memory is good for performance, but why was it needed in the first place? Probably trashing memory
- The join order looks relatively well-optimized, but there are some unneeded outer products, I wonder if those are the bottleneck
- I see very few symbols, this is concerning, the trie doesn't do much if its tiny and doesn't branch on symbols
- The files are named fromNumber and lte, which leads me to believe there's a lot of decoding/encoding happening, hopefully not in Peano numbers 

## Initial run
As instructed, ran the three scripts in order.
I left the default case annotated as:
`;; jarr (size=13, time=40.435s)`
`(target 13 (c: (→ (→ (→ 𝜑 𝜓) 𝜒) (→ 𝜓 𝜒)) $x))`
I ran it with timing and producing the space to a file.
`> /usr/bin/time -v  ./target/release/mork run kernel/resources/bfc-xp.mm2 bfc_13.mm2`
```
loaded 6 expressions
executing 84 steps took 25434 ms (unifications 10517, writes 9908, transitions 220380293)
dumping 9611 expressions

User time (seconds): 25.22
System time (seconds): 0.01
Elapsed (wall clock) time (h:mm:ss or m:ss): 0:25.34
Maximum resident set size (kbytes): 11944
Minor (reclaiming a frame) page faults: 2087
Voluntary context switches: 1
Involuntary context switches: 504
File system outputs: 4224
```
Wow, 220M transitions and only 10k unifications, definitely some kind of outer product being calculated and traversed here. 
The timing of 25 seconds is significantly faster, but within machine differences.
Only 84 steps of execution means it's at least a wide computation, though only 12MB max memory is very concerning.
Let's look at the output.

```
(lte 0 0)
...
(lte 26 26)
...
fromNumberFn 23 (S (S (S (S (S (S (S (S (S (S (S (S (S (S (S (S (S (S (S (S (S (S (S Z))))))))))))))))))))))))
...
(sol 1 1 (c: (-> (→ (¬ 𝜒) (¬ 𝜓)) (→ (→ (→ 𝜑 𝜓) 𝜒) (→ 𝜓 𝜒))) ((((mpⁱ (mpⁱ (((mpⁱ (mpⁱ (mpⁱ ((mpⁱ I) ax₁)))) ax₁) ax₃))) ax₂) ax₁) ax₃)))
(sol 1 1 (c: (-> (→ (¬ 𝜒) (¬ 𝜓)) (→ (→ (→ 𝜑 𝜓) 𝜒) (→ 𝜓 𝜒))) ((((mpⁱ (mpⁱ ((mpⁱ (mpⁱ ((mpⁱ ((mpⁱ I) ax₁)) ax₃))) ax₃))) ax₂) ax₁) ax₁)))
(sol 1 1 (c: (-> (→ (¬ 𝜒) (¬ 𝜓)) (→ (→ (→ 𝜑 𝜓) 𝜒) (→ 𝜓 𝜒))) ((((mpⁱ (mpⁱ (mpⁱ ((((mpⁱ (mpⁱ (mpⁱ I))) ax₁) ax₁) ax₁)))) ax₁) ax₃) ax₁)))
(sol 1 1 (c: (-> (→ (¬ 𝜒) (¬ 𝜓)) (→ (→ (→ 𝜑 𝜓) 𝜒) (→ 𝜓 𝜒))) ((((mpⁱ (mpⁱ (mpⁱ ((((mpⁱ (mpⁱ (mpⁱ I))) ax₁) ax₁) ax₁)))) ax₁) ax₃) ax₂)))
....
(sol 13 1 (c: (-> (→ (→ (→ 𝜑 𝜓) 𝜒) (→ 𝜓 𝜒)) (→ (→ (→ 𝜑 𝜓) 𝜒) (→ 𝜓 𝜒))) I))
(final 0 0 (c: (→ (→ (→ 𝜑 𝜓) 𝜒) (→ 𝜓 𝜒)) ((((mpⁱ (((mpⁱ (mpⁱ ((mpⁱ ((mpⁱ (mpⁱ I)) ax₂)) ax₁))) ax₂) ax₂)) ax₁) ax₁) ax₁)))
(final 0 0 (c: (→ (→ (→ 𝜑 𝜓) 𝜒) (→ 𝜓 𝜒)) (((mpⁱ ((((mpⁱ ((mpⁱ (mpⁱ ((mpⁱ (mpⁱ I)) ax₂))) ax₂)) ax₁) ax₂) ax₁)) ax₁) ax₁)))
```
This confirms a few thoughts:
- The <= relation is instantiated, not the worst thing, depending on how it's used
- The <= uses decimal, not the worst thing, but only makes 10/256 use of the trie
- The fromNumber on Peano is concerning, let's see if it's used anywhere
- Prefix compression seems to be used well, though the branching factor seems extremely low (3 at most)

## First look at the code

```
  (, (target $mps (c: $ta $tx))
     (fromNumberFn $mps $mps_n))
```
This seems to convert *to* Peano numbers, luckily the statement itself is not in a tight loop.

```
      (exec (2 (S $k)) $ptrn $tplt)
      ;; Grab corresponding integers
      (toNumberFn (S $k) $ski)
      (toNumberFn $k $ki))
```
One loop deeper in, we are doing peano-number conversions.

```
          (exec (3 0)
                (, (sol $ski $shi (c: (-> (→ $𝜑 (→ $𝜓 $𝜑)) $b) $f))
                   (decFn $shi $hi)
                   (lte $hi $ki))
                (, (sol $ki $hi (c: $b ($f ax₁)))))
          ;; Apply current proof to axiom-2
          (exec (4 0)
                (, (sol $ski $shi (c: (-> (→ (→ $𝜑 (→ $𝜓 $𝜒)) (→ (→ $𝜑 $𝜓) (→ $𝜑 $𝜒))) $b) $f))
                   (decFn $shi $hi)
                   (lte $hi $ki))
                (, (sol $ki $hi (c: $b ($f ax₂)))))
          ;; Apply current proof to axiom-3
          (exec (5 0)
                (, (sol $ski $shi (c: (-> (→ (→ (¬ $𝜑) (¬ $𝜓)) (→ $𝜓 $𝜑)) $b) $f))
                   (decFn $shi $hi)
                   (lte $hi $ki))
                (, (sol $ki $hi (c: $b ($f ax₃)))))
          ;; Apply mpⁱ to current proof
          (exec (6 0)
                (, (sol $ski $hi (c: (-> $b $c) $f))
                   (lte $hi $ki)
                   (incFn $hi $shi))
                (, (sol $ki $shi (c: (-> (→ $a $b) (-> $a $c)) (mpⁱ $f)))))
```
There seem to four inner loops, all doing some unification (e.g. repeated `$𝜓`) and a ton of searching (e.g. `(sol $ski $shi ...` with both parameters unbounded).
The code comments do mention that moving `$ski $shi` to the back didn't work in their experience, something to investigate.

```
        ;; Respawn inner self
        (exec (7 0) (,)
        (, (exec (2 $k) $ptrn $tplt)))))
```
Unconditional re-scheduling seems weird, if that's possible, why not schedule everything? Oh well, unlikely to be important for performance

## Run in debug
I switched to a smaller problem and added a count of the `(sol 1 1` pattern.
```
- (target 13 (c: (→ (→ (→ 𝜑 𝜓) 𝜒) (→ 𝜓 𝜒)) $x))
+ (target 7 (c: (→ (→ 𝜑 (→ 𝜑 𝜓)) (→ 𝜑 𝜓)) $x))
+ (exec (3 0 1)
+   (, (sol $x $y $s))
+   (O (count (kh-cnt $x $y $c) $c (sol $x $y $s))))
```

Let's run on a restricted subset and run some basic diagnostics (exec's, trie traversal steps, written atoms, average path length, and the counts):
```
> RUST_LOG=trace ./target/release/mork run kernel/resources/bfc-xp.mm2 bfc_7.mm2 2> bfc_7_trace.log`
> cat bfc_7_trace.log | grep "DEBUG interpret" | wc -l
49
>  cat bfc_7_trace.log | grep "TRACE coref trans] loc" | wc -l
85408
> cat bfc_7_trace.log | grep "TRACE transform] U" | wc -l
696
> sed -n 's/.*[[:space:]]len[[:space:]]\([0-9][0-9]*\)[[:space:]]*$/\1/p' bfc_7_trace.log | awk '{ sum += $1; count++ } END { print sum / count }'
183.729
> ./target/release/mork convert metta metta '[4] kh-cnt $ $ $' '[4] kh-cnt $ $ $' bfc_7.mm2 /dev/stdout
(kh-cnt 0 0 1)
(kh-cnt 1 1 24)
(kh-cnt 2 2 30)
(kh-cnt 3 1 7)
(kh-cnt 3 3 9)
(kh-cnt 4 2 6)
(kh-cnt 4 4 1)
(kh-cnt 5 1 3)
(kh-cnt 5 3 1)
(kh-cnt 6 2 1)
(kh-cnt 7 1 1)
```

As suspected, almost all the time is spent in the trie search, which is weird given there are so few entries. Also, our average path length is long at `183.729`.
Also surprising is that the rounds are very unequal: almost all atoms are in `(sol 1 1` and `(sol 2 2`.

The `bfc_7_trace.log` file is quite unreadable because of the expanded unicode representation, let's replace that for a moment (e.g. `𝜑` becomes `p`).
This change accidentally dropped our runtime from 25434 ms to 16078 ms, because of the shorter (in byte representation) symbols.

This made me curious if our runtime would be lower with PathMap's `all_dense_nodes`, and it is (by 2 seconds) at the cost of a 10x increase in memory usage -- we have no long symbols in our trie, but this doesn't mean our branching factor is high.

Let's look at where the traversal is spending its time by sampling ~20 `loc`'s
```
> grep "TRACE coref trans] loc" bfc_7_trace.log | grep -oP '\bloc\s+\K.*(?=\s+len\s+\d+\s*$)' | awk 'BEGIN { srand() } rand() < (20/85408)'
[3] ACT lte [3] lte [2] S [2] S [2] S [2] S [2] S [2] S Z [2] S [2] S [2] S [2] S [2] S [2] S [2] S [2] S [2] S [2] S [2] S [2] S [2] S [2] S [2] S [2] S [2] S [2] S [2] S [2] S [2] S [2] S [2] S Z [2] BTM [3] toNumberFn [2] S [2] S [2] S [2] S [2] S [2] S Z 6 [2] BTM   
[3] ACT lte [3] lte [2] S [2] S [2] S [2] S [2] S [2] S [2] S Z [2] S [2] S [2] S [2] S [2] S [2] S [2] S [2] S [2] S [2] S [2] S [2] S [2] S [2] S [2] S [2] S [2] S [2] S [2] S [2] S [2] S [2] S [2] S [2] S [2] S Z [2] BTM [3] toNumberFn [2] S [2] S [2] S [2] S [2] S [2] S [2] S Z 7 [2] BTM [3] toNumberFn [2] S [2] S [2] S [2] S [2] S [2] S   
[3] ACT lte [3] lte [2] S [2] S [2] S [2] S [2] S [2] S [2] S [2] S Z [2] S [2] S [2] S [2] S [2] S [2] S [2] S [2] S [2] S [2] S [2] S [2] S [2] S [2] S [2] S [2] S [2] S [2] S [2] S [2] S [2] S [2] S [2] S [2] S [2] S Z [2] BTM [3] toNumberFn [2] S [2] S [2] S [2] S [2] S [2] S   
[3] ACT lte [3] lte [2] S [2] S [2] S [2] S [2] S [2] S [2] S [2] S [2] S [2] S [2] S [2] S [2] S [2] S [2] S Z [2] S [2] S [2] S [2] S [2] S [2] S [2] S [2] S [2] S [2] S [2] S [2] S [2] S [2] S [2] S [2] S [2] S [2] S [2] S Z [2] BTM [3] toNumberFn [2] S [2] S [2] S [2] S [2] S [2] S [2] S [2] S [2] S [2] S [2] S [2] S [2] S [2] S [2] S Z 15 [2] BTM [3] toNumberFn [2] S [2] S [2] S [2] S [2] S [2] S [2] S [2] S [2] S [2] S [2] S [2] S [2] S [2] S [2] S [2] S [2] S [2] S [2]   
[3] ACT lte [3] lte [2] S [2] S [2] S [2] S [2] S [2] S [2] S [2] S [2] S [2] S [2] S [2] S [2] S [2] S [2] S [2] S [2] S Z [2] S [2] S [2] S [2] S [2] S [2] S [2] S [2] S [2] S [2] S [2] S [2] S [2] S [2] S [2] S [2] S [2] S [2] S Z [2] BTM [3] toNumberFn [2] S [2] S [2] S [2] S [2] S [2] S [2] S [2] S [2] S [2] S [2] S [2] S [2] S [2] S [2] S [2] S [2] S Z 17 [2] BTM [3] toNumberFn [2] S [2] S [2] S [2] S [2] S [2] S [2]   
[3] ACT lte [3] lte [2] S [2] S [2] S [2] S [2] S [2] S [2] S [2] S [2] S [2] S [2] S [2] S [2] S [2] S [2] S [2] S [2] S Z [2] S [2] S [2] S [2] S [2] S [2] S [2] S [2] S [2] S [2] S [2] S [2] S [2] S [2] S [2] S [2] S [2] S [2] S [2] S [2] S [2] S [2] S [2] S [2] S [2] S [2] S Z [2] BTM [3] toNumberFn [2] S [2] S [2] S [2] S [2] S [2] S [2] S [2] S [2] S [2] S [2] S [2] S [2] S [2] S [2] S [2] S [2] S Z 17 [2] BTM [3] toNumberFn [2] S [2] S [2] S [2] S [2] S [2] S [2] S [2] S [2] S [2] S [2] S [2] S [2] S [2] S [2] S [2] S [2] S [2] S [2]   
[3] ACT lte [3] lte [2] S [2] S [2] S [2] S [2] S [2] S [2] S [2] S [2] S [2] S [2] S [2] S [2] S [2] S [2] S [2] S [2] S [2] S [2] S [2] S [2] S Z [2] S [2]   
[3] ACT lte [3] lte [2] S [2] S [2] S [2] S [2] S [2] S [2] S [2] S [2] S [2] S [2] S [2] S [2] S [2] S [2] S [2] S [2] S [2] S [2] S [2] S [2] S Z [2] S [2] S [2] S [2] S [2] S [2] S [2] S [2] S [2] S [2] S [2] S [2] S [2] S [2] S [2] S [2] S [2] S [2] S [2] S [2] S [2] S [2] S [2] S Z [2] BTM [3] toNumberFn [2] S [2] S [2] S [2] S [2] S [2] S [2] S [2] S [2] S [2]   
[4] exec [2] 2 [2] S [2] S [2] S [2] S [2] S [2] S Z [4] , [4] exec [2] 2 [2] S $ $ $ [3] toNumberFn [2] S _1 $ [3] toNumberFn _1 $ [6] , [4] exec [2] 3 0 [4] , [4] sol _4 $ [3] C [3] / [3] > $ [3] > $ _7 $ $ [3] decFn _6 $ [3] lte _11 _5 [2] , [4] sol _5 _11 [3] C _9 [2] _10 1 [4] exec [2] 4 0 [4] , [4] sol _4 _6 [3] C [3] / [3] > [3] > _7 [3] > _8 $ [3] > [3] > _7 _8 [3] > _7 _12 _9 _10 [3] decFn _6 _11 [3] lte _11 _5 [2] , [4] sol _5 _11 [3] C _9 [2] _10 2 [4] exec [2] 5 0 [4] , [4] sol _4 _6 [3] C [3] / [3] > [3] > [2] ! _7 [2] ! _8 [3] > _8 _7 _9 _10 [3] decFn _6 _11 [3] lte _11 _5 [2] , [4] sol _5 _11 [3] C _9 [2] _10 3 [4] exec [2] 6 0 [4] , [4] sol _4 _11 [3] C [3] / _9 $ _10 [3] lte _11 _5 [3] incFn _11 _6 [2] , [4] sol _5 _6 [3] C [3] / [3] > $ _9 [3] / _14 _13 [2] M _10   
[4] sol 4 4 [3] C [3] / [3] > $ [3] > $ [3] > $ [3] > [3] > p [3] > p s [3] > p s [3] / _1 [3] / _2 [3] / _3 [3] > [3] > p [3] > p s [3] > p s [2] M [2] M [2] M I [3] fromNumberFn 25 [2] S [2] S [2] S [2] S [2] S [2] S [2] S [2] S [2] S [2] S [2] S [2] S [2] S [2] S [2] S [2] S [2] S [2] S [2] S [2] S [2] S [2] S   
[4] sol 3 3 [3] C [3] / [3] > $ [3] > [3] > p [3] > p s [3] > $ [3] > p s [3] / _1 [3] / [3] > [3] > p [3] > p s _2 [3] > [3] > p [3] > p s [3] > p s [2] M [2] [2] M [2] M I 2 [3] toNumberFn [2] S Z   
[4] sol 3 3 [3] C [3] / [3] > $ [3] > $ [3] > p s [3] / _1 [3] / _2 [3] > [3] > p [3] > p s [3] > p s [2] M [2] M [2] [2] M I 1 [3] incFn 6 7 [3] decFn   
[4] sol 3 3 [3] C [3] / [3] > $ [3] > $ [3] > p [3] > [3] > p s s [3] / _1 [3] / _2 [3] > [3] > p [3] > p s [3] > p s [2] M [2] M [2] [2] M I 2 [3] fromNumberFn 25 [2] S [2] S [2] S [2] S [2] S [2]   
[4] sol 3 3 [3] C [3] / [3] > $ [3] > $ [3] > p [3] > [3] > p s s [3] / _1 [3] / _2 [3] > [3] > p [3] > p s [3] > p s [2] M [2] M [2] [2] M I 2 [4] sol 3 3 [3] C [3] / [3] > $ [3] > $ [3] > p [3] > [3] > p s s [3] / _1 [3] / _2 [3] > [3] > p   
[4] sol 3 3 [3] C [3] / [3] > $ [3] > $ [3] > [2] ! [3] > p s [2] ! [3] > p [3] > p s [3] / _1 [3] / _2 [3] > [3] > p [3] > p s [3] > p s [2] M [2] M [2] [2] M I 3 [3] lte 22 23 [3] decFn 3   
[4] sol 3 3 [3] C [3] / [3] > $ [3] > $ [3] > [2] ! [3] > p s [2] ! [3] > p [3] > p s [3] / _1 [3] / _2 [3] > [3] > p [3] > p s [3] > p s [2] M [2] M [2] [2] M I 3 [3] fromNumberFn 16 [2] S [2] S [2] S [2] S [2] S [2]   
[4] sol 3 3 [3] C [3] / [3] > $ [3] > $ [3] > [2] ! [3] > p s [2] ! [3] > p [3] > p s [3] / _1 [3] / _2 [3] > [3] > p [3] > p s [3] > p s [2] M [2] M [2] [2] M I 3 [3] fromNumberFn 21 [2] 
[4] sol 3 3 [3] C [3] / [3] > $ [3] > $ [3] > [2] ! [3] > p s [2] ! [3] > p [3] > p s [3] / _1 [3] / _2 [3] > [3] > p [3] > p s [3] > p s [2] M [2] M [2] [2] M I 3 [4] sol 4 2 [3] C [3] / [3] > [2] ! [3] > [3] >   
[4] sol 3 3 [3] C [3] / [3] > $ [3] > $ [3] > [3] > p [3] > p s [3] > p s [3] / [3] > _1 _2 [3] / _1 [3] > [3] > p [3] > p s [3] > p s [2] [2] M [2] M [2] M I 2 [4] sol 2 2 [3] C [3] / [3] > [3] > [3] > p [3] > p s [3] > $ [3] > p s [3] > [3] > p [3] > p s _1 [3] / [3] > [3] > p [3] > p s [3] > _1 [3] > p s [3] >   
[4] sol 1 1 [3] C [3] / s [3] > [3] > p [3] > p s [3] > p   
[4] sol 2 2 [3] C [3] / $ [3] / [3] > p [3] > [3] > p s s [3] > [3] > p [3] > p s [3] > p s [2] [2] [2]   
[4] sol 3 3 [3] C [3] / [3] > $ [3] > [3] > p [3] > p s [3] > p s [3] / $ [3] / _1 [3] > [3] > p [3] > p s [3] > p s  
```

From this small sample, 8 are `toNumberFn`, 1 is in `lte`, 1 is in control flow, 4 are in `fromNumberFn`, 2 are `decFn`, and 5 are in the atom search.

Let's see what the distribution is like for the full search 16 second execution by printing 1 in 25K locations:
```
RUST_LOG="coref trans"=trace ./target/release/mork run kernel/resources/bfc-xp-T.mm2 bfc_13_plain.mm2 |& grep "TRACE coref trans] loc" | grep -oP '\bloc\s+\K.*(?=\s+len\s+\d+\s*$)' | awk 'BEGIN { srand() } rand() < (1/25000)'
...
[4] sol 4 4 [3] C [3] / [3] > $ [3] > $ [3] > $ [3] > s x [3] / [3] > _1 _2 [3] / _1 [3] / [3] > [3] > [3] > p s x _3 [3] > [3] > [3] > p s x [3] > s x [2] [2] M [2] M [2] M [2] [2] M [2] [2] M [2] M I 2 1 2 [4] sol 4 2 [3] C [3] / [3] > [3] > [2] ! [2] ! [3] > [3] > p s x [3] > $ [2] ! [2] ! [3] > s x   
[4] sol 4 4 [3] C [3] / [3] > $ [3] > $ [3] > $ [3] > s x [3] / [3] > _1 _2 [3] / _1 [3] / [3] > [3] > [3] > p s x _3 [3] > [3] > [3] > p s x [3] > s x [2] [2] M [2] M [2] M [2] [2] M [2] [2] M [2] M I 2 1 2 [4] sol 5 3 [3] C [3] / [3] > $ [3] > [2] ! [2] ! [2] ! [3] > [3] > [3] > p s x [3] > s x [2] ! [2] ! [2] ! $ [3] / _1 [3] / _2 [3] > [3] > [3] > p s x [3] > s x [2] M [2] [2] M [2] [2] M [2] [2] M   
[4] sol 4 4 [3] C [3] / [3] > $ [3] > $ [3] > $ [3] > s x [3] / [3] > _1 _2 [3] / [3] > _1 _3 [3] / _1 [3] > [3] > [3] > p s x [3] > s x [2] [2] M [2] M [2] [2] M [2] M [2] M [2] [2] M I 1 2 2 [3] lte 9 19 [3] decFn   
[4] sol 4 4 [3] C [3] / [3] > $ [3] > $ [3] > $ [3] > s x [3] / [3] > _1 _2 [3] / [3] > _1 _3 [3] / _1 [3] > [3] > [3] > p s x [3] > s x [2] [2] M [2] M [2] [2] M [2] M [2] M [2] [2] M I 1 2 2 [4] sol 3 3 [3] C [3] / [3] > [3] > [3] > [3] > $ [3] > [3] > [3] > p s x [3] > s x $ [3] > _1 [3] > [3] > [3] >   
[4] sol 4 4 [3] C [3] / [3] > $ [3] > $ [3] > $ [3] > s x [3] / [3] > _1 _2 [3] / [3] > _1 _3 [3] / _1 [3] > [3] > [3] > p s x [3] > s x [2] [2] M [2] M [2] [2] M [2] M [2] M [2] [2] M I 1 2 2 [4] sol 4 4 [3] C [3] / [3] > $ $ [3] / $ [3] / _1 [3] / [3] > s x [3] > [3] > [3] > p s x [3] > s x [2] [2] M [2] M [2] M [2]   
[4] sol 4 4 [3] C [3] / [3] > $ [3] > $ [3] > $ [3] > s x [3] / [3] > _1 _2 [3] / [3] > _1 _3 [3] / _1 [3] > [3] > [3] > p s x [3] > s x [2] [2] M [2] M [2] [2] M [2] M [2] M [2] [2] M I 1 2 2 [4] sol 4 4 [3] C [3] / [3] > $ [3] > $ $ [3] / [3] > [2] ! [3] > $ [3] > [3] > [3] > p s x [3] > s x [2] ! $ [3] / _5 [3] / _4 [3] > [3] > [3] > p s x [3] > s x [2] [2] M [2] [2] [2] M [2] M [2] M [2] M [2] M I 1 3 2 [3] decFn 4 3   
[4] sol 4 4 [3] C [3] / [3] > $ [3] > $ [3] > $ [3] > s x [3] / [3] > _1 _2 [3] / [3] > _1 _3 [3] / _1 [3] > [3] > [3] > p s x [3] > s x [2] [2] M [2] M [2] [2] M [2] M [2] M [2] [2] M I 1 2 2 [4] sol 4 4 [3] C [3] / [3] > $ [3] > $ [3] > s [3] > $ x [3] / _1 [3] / _2 [3] / [3] > [3] > [3] > p s x [3] > s _3 [3] > [3] > [3] > p s x [3] > s x [2] M [2] M [2] [2] M [2] [2] M [2]   
[4] sol 4 4 [3] C [3] / [3] > $ [3] > $ [3] > $ [3] > s x [3] / [3] > _1 _2 [3] / [3] > _1 _3 [3] / _1 [3] > [3] > [3] > p s x [3] > s x [2] [2] M [2] M [2] [2] M [2] M [2] M [2] [2] M I 1 2 2 [4] sol 4 4 [3] C [3] / [3] > $ [3] > $ [3] > [2] ! $ [2] ! [3] > [2] ! [3] > [3] > [3] > p s x [3] > s x [2] ! _3 [3] / _1 [3] / _2 [3] / [3] > [2] ! [3] > [3] > [3] > p s x [3] > s x [2] ! _3 [3] > [3] > [3] > p s x [3] > s x [2] M [2] M [2] [2] M [2] [2] [2] M [2] M [2] M I 2   
[4] sol 4 4 [3] C [3] / [3] > $ [3] > $ [3] > $ [3] > s x [3] / [3] > _1 _2 [3] / [3] > _1 _3 [3] / _1 [3] > [3] > [3] > p s x [3] > s x [2] [2] M [2] M [2] [2] M [2] M [2] M [2] [2] M I 1 2 2 [4] sol 4 4 [3] C [3] / [3] > [2] ! [3] > $ [3] > $ [3] > [3] > [3] > p s x [3] > s x [2] ! $ [3]   
[4] sol 4 4 [3] C [3] / [3] > $ [3] > $ [3] > $ [3] > s x [3] / [3] > [3] > _1 _2 _1 [3] / [3] > _1 _2 [3] / _3 [3] > [3] > [3] > p s x [3] > s x [2] [2] M [2] [2] M [2] M [2] M [2] M [2] [2] M I 1 2 2 [4] sol 4 4 [3] C [3] / $ [3] / $ [3] / [3] > [3] > [3] > p s x [3] > s x [3] / $ [3] > [3] > [3] > p s x [3] > s x [2] [2] [2] M [2] M [2] [2] M [2] M   
[4] sol 4 4 [3] C [3] / [3] > $ [3] > $ [3] > $ [3] > s x [3] / [3] > [3] > _1 _2 _1 [3] / [3] > _1 _2 [3] / _3 [3] > [3] > [3] > p s x [3] > s x [2] [2] M [2] [2] M [2] M [2] M [2] M [2] [2] M I 1 2 2 [4] sol 5 5 [3] C [3] / [3] > $ [3] > $ [3] > [2] ! [3] > [3] > [3] > p s x [3] > s x [3] > $ [2] ! $ [3] / _1 [3] / _2 [3] / [3] > [2] ! [3] > [3] > [3] > p s x [3] > s x _3 [3] / _4 [3] > [3] > [3] > p s x [3] > s x [2]   
[4] sol 4 4 [3] C [3] / [3] > $ [3] > $ [3] > $ [3] > s x [3] / [3] > [3] > _1 _2 _1 [3] / [3] > _1 _2 [3] / _3 [3] > [3] > [3] > p s x [3] > s x [2] [2] M [2] [2] M [2] M [2] M [2] M [2] [2] M I 1 2 2 [4] sol 7 3 [3] C [3] / $ [3] / [3] > [2]   
[4] sol 4 4 [3] C [3] / [3] > $ [3] > $ [3] > $ [3] > [2] ! x [2] ! s [3] / _1 [3] / [3] > _2 _3 [3] / _2 [3] > [3] > [3] > p s x [3] > s x [2] M [2] [2] M [2] M [2] M [2] [2] M [2] [2] M I 1 3 2 [4] sol 3 3 [3] C [3] / [3] > [2] ! [3] > $ [3] > [3] > [3] > p   
[4] sol 4 4 [3] C [3] / [3] > $ [3] > $ [3] > $ [3] > [2] ! x [2] ! s [3] / _1 [3] / [3] > _2 _3 [3] / _2 [3] > [3] > [3] > p s x [3] > s x [2] M [2] [2] M [2] M [2] M [2] [2] M [2] [2] M I 1 3 2 [4] sol 3 3 [3] C [3] / [3] > [3] > $ x $ [3] / [3] > _1 x [3]   
[4] sol 4 4 [3] C [3] / [3] > $ [3] > $ [3] > $ [3] > [2] ! x [2] ! s [3] / _1 [3] / [3] > _2 _3 [3] / _2 [3] > [3] > [3] > p s x [3] > s x [2] M [2] [2] M [2] M [2] M [2] [2] M [2] [2] M I 1 3 2 [4] sol 4 2 [3] C [3] / [2] ! $ [3] / _1 [3] > [3] > [3] > p s x [3] > s x [2] [2] [2] [2] M [2] M [2] M [2] [2] M [2] M I 3 1 1 3 [3]   
[4] sol 4 4 [3] C [3] / [3] > $ [3] > $ [3] > $ [3] > [2] ! x [2] ! s [3] / _1 [3] / [3] > _2 _3 [3] / _2 [3] > [3] > [3] > p s x [3] > s x [2] M [2] [2] M [2] M [2] M [2] [2] M [2] [2] M I 1 3 2 [4] sol 4 2 [3] C [3] / [3] > $ [3] > [2] ! x [2] ! s [3] / _1 [3] > [3] > [3] > p s x [3] > s x [2] M [2] [2] [2] [2] M [2] [2] M [2] M [2] M I 2 1 1 3 [3]   
[4] sol 4 4 [3] C [3] / [3] > $ [3] > $ [3] > $ [3] > [2] ! x [2] ! s [3] / _1 [3] / [3] > _2 _3 [3] / _2 [3] > [3] > [3] > p s x [3] > s x [2] M [2] [2] M [2] M [2] M [2] [2] M [2] [2] M I 1 3 2 [4] sol 4 4 [3] C [3] / [2] ! $ [3] / $ [3] / _1 [3] / $ [3] > [3] > [3] > p s x [3] > s x [2] [2] M [2] [2] M [2] [2] M [2]   
[4] sol 4 4 [3] C [3] / [3] > $ [3] > $ [3] > $ [3] > [2] ! x [2] ! s [3] / _1 [3] / [3] > _2 _3 [3] / _2 [3] > [3] > [3] > p s x [3] > s x [2] M [2] [2] M [2] M [2] M [2] [2] M [2] [2] M I 1 3 2 [4] sol 4 4 [3] C [3] / [3] > [2] ! [3] > [2] ! [3] > [3] > [3] > p s x [3] > s x [2] ! $ [2] ! $ [3] / $ [3] / _2 [3] / _1 [3] > [3] > [3] > p s x [3] > s x [2] [2] M [2] M [2] [2] M [2] M [2] [2] M [2] M I   
[4] sol 4 4 [3] C [3] / [3] > $ [3] > $ [3] > $ [3] > [2] ! x [2] ! s [3] / _1 [3] / [3] > _2 _3 [3] / _2 [3] > [3] > [3] > p s x [3] > s x [2] M [2] [2] M [2] M [2] M [2] [2] M [2] [2] M I 1 3 2 [4] sol 5 3 [3] C [3] / [3] > $ [3] > [3] > [3] > p s x [3] > [3] > $ [3] > s x _2 [3] / _1 [3] / [3] > [3]   
[4] sol 4 4 [3] C [3] / [3] > $ [3] > $ [3] > $ [3] > [2] ! x [2] ! s [3] / [3] > _1 _2 [3] / _1 [3] / _3 [3] > [3] > [3] > p s x [3] > s x [2] [2] M [2] M [2] M [2] M [2] [2] M [2] [2] M I 1 3 2 [4] sol 3 1 [3] C [3] / [3] > [2] ! x [2] ! s [3] > [3] > [3] > p s x [3] > s x [2] [2] [2] M [2] [2] [2] M [2] M [2] M [2] [2] M I 1 1 3 2 1 [3] decFn 4 3   
[4] sol 4 4 [3] C [3] / [3] > $ [3] > $ [3] > $ [3] > [2] ! x [2] ! s [3] / [3] > _1 _2 [3] / _1 [3] / _3 [3] > [3] > [3] > p s x [3] > s x [2] [2] M [2] M [2] M [2] M [2] [2] M [2] [2] M I 1 3 2 [4] sol 3 3 [3] C [3] / [3] > [3] > [2] ! [3] > s x [2] ! [3] > [3] > p s x $ [3] / [3] > [2] ! [3] > s x [2] ! [3] > [3] > p s x [3] / $ [3] > [3] > [3] > p s x [3] > s x [2] [2] [2] M [2] M [2] M [2] [2] M [2] [2] M [2] M I 1 3 2 1 [3] decFn 4 3   
...
```

Now 4 are in `decFn`, 8 are in term traversal, and 8 are in proof traversal.
Let's try and fix that.

## The fix
Let's start with the inner loop query where `$ki` and `$ski` are already bound.
```
(, (sol $ski $shi (c: (-> (→ $𝜑 (→ $𝜓 $𝜑)) $b) $f))
   (decFn $shi $hi) (lte $hi $ki))
```
This could be precisely the "outer product" like check we were looking for, because `$shi` is iterated over in `sol` why it needn't be.
Reversing the relation:
```
(, (gte $ki $hi) (incFn $hi $shi)
   (sol $ski $shi (c: (-> (→ $𝜑 (→ $𝜓 $𝜑)) $b) $f)))
```

Executing this change provides us with a giant speed up, yey!
The 16s script is now in the millisecond around the startup time of MORK.
For the next two larger scripts in line:
`imim1 (size=15, time=25m5.188s)  ->  0.885s`
`loowoz (size=19, time=?)  ->  46.467s`
Judging by imim1, we're seeing about a 1500x speed-up.

## Other suggestions
I'd factor out the different axioms and shared `(gte $ki $hi) (incFn $hi $shi)` so the algorithmic structure is more clear:
```common lisp
(axiom 1 (> $p (> $s $p)))
(axiom 2 (> (> $p (> $s $x)) (> (> $p $s) (> $p $x))))
(axiom 3 (> (> (! $p) (! $s)) (> $s $p)))

(exec (2)
    (, (target $mps (C $ta $tx)))
    (, ;; Initialize source
       (sol $mps 1 (C (/ $ta $ta) I))
       ;; Expand one step forward
       (exec (2 $mps)
            (, ;; Capture inner self
               (exec (2 $ski) $ptrn $tplt)
               (decFn $ski $ki)
               (gte $ki $hi)
               (incFn $hi $shi)
               ;; for each axiom
               (axiom $r $constraint))
            (, ;; Apply current proof to axiom-$r
               (exec (3 $r)
                    (, (sol $ski $shi (C (/ $constraint $b) $f)))
                    (, (sol $ki $hi (C $b ($r $f)))))
               ;; Apply mp^i to current proof
               (exec (4 0)
                    (, (sol $ski $hi (C (/ $b $c) $f)))
                    (, (sol $ki $shi (C (/ (> $a $b) (/ $a $c)) (M $f)))))
               ;; Respawn inner self
               (exec (7 0) 
                    (, (lte 0 0)) ;; my editor doesn't like (,)
                    (, (exec (2 $ki) $ptrn $tplt)))))))
```
