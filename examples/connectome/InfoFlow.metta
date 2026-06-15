;;;; InfoFlow.metta — Drosophila Fig-6 information-flow model (Stage 1, synthetic)
;;;;
;;;; Source: docs/specs/flywire_connectome_spec.md §7 (Dorkenwald et al. Nature 2024).
;;;; Deterministic core of the probabilistic-ramp model: a neuron is reached at
;;;; step k+1 iff the SYNAPSE-weighted ratio of its inputs coming from the
;;;; already-reached set ≥ 0.3.  Seed = afferent (sensory) neurons; rank = step.
;;;;
;;;;   ratio(P) = (Σ syn_count of edges into P from reached) / (Σ syn_count into P)
;;;;
;;;; Edges: (syn <pre> <post> <syn_count>)   — maps 1:1 to FAFB connections_princeton
;;;;        (pre_root_id, post_root_id, syn_count).  Stage 2 swaps this synthetic
;;;;        graph for the real CSV via space_load_csv!.

;; ── Synthetic connectome (2 modalities, a shared core, one motor output) ──
;; Designed so olfactory and visual flows take DIFFERENT paths (the 0.3 threshold
;; gates weak cross-pathways) yet CONVERGE on the motor output m1.
(syn oA1 c1 6) (syn oA2 c1 4)      ; olfactory afferents → c1  (in-sum 10)
(syn vB1 c2 6) (syn vB2 c2 4)      ; visual afferents    → c2  (in-sum 10)
(syn c1 c3 8) (syn c2 c3 2)        ; c3: olfactory-dominated (8 vs 2)
(syn c2 c4 8) (syn c1 c4 2)        ; c4: visual-dominated    (8 vs 2)
(syn c3 c5 9) (syn c4 c5 1)        ; c5: deep on the olfactory path
(syn c3 m1 5) (syn c4 m1 5)        ; m1: motor output, fed by both paths

;; ── Model helpers ──────────────────────────────────────────────────────────

;; (reached? N) → True iff a (reached N _) atom exists.
(= (reached? $n) (> (size-atom (collapse (match &self (reached $n $k) $n))) 0))

;; Σ syn_count over ALL input edges of P.
(= (total-in $p)
   (foldl-atom (collapse (match &self (syn $r $p $c) $c)) 0 $a $x (+ $a $x)))

;; Σ syn_count over input edges of P whose presynaptic neuron is reached.
(= (reached-in $p)
   (foldl-atom (collapse (match &self (syn $r $p $c) ($r $c))) 0 $a $pr
       (+ $a (if (reached? (car-atom $pr)) (car-atom (cdr-atom $pr)) 0))))

;; weighted input ratio.
(= (ratio $p) (/ (reached-in $p) (total-in $p)))

;; A not-yet-reached neuron qualifies this step iff ratio ≥ 0.3.
(= (qualifies? $p) (and (not (reached? $p)) (>= (ratio $p) 0.3)))

;; all post-synaptic neurons (the only reachable candidates).
(= (post-neurons) (unique-atom (collapse (match &self (syn $r $p $c) $p))))

;; candidates to add this step.
(= (step-candidates) (filter-atom (post-neurons) $p (qualifies? $p)))

;; mark each neuron in the list as reached at rank k (recursive; do = sequence).
(= (mark-each $lst $k)
   (if (== (size-atom $lst) 0)
       done
       (do (add-atom &self (reached (car-atom $lst) $k))
           (mark-each (cdr-atom $lst) $k))))

;; synchronous flow step: compute all qualifying candidates against the current
;; reached set, mark them at rank k, recurse at k+1.  Stops when no new neuron.
(= (flow-step $k)
   (let $cands (step-candidates)
     (if (== (size-atom $cands) 0)
         done
         (do (mark-each $cands $k)
             (flow-step (+ $k 1))))))

;; ── Reporting ────────────────────────────────────────────────────────────────
;; all (neuron . rank) pairs, for inspection.
(= (ranks) (collapse (match &self (reached $n $k) ($n $k))))

;; ── Running per modality (verified on the MettaJam live server) ──────────────
;; This file is the model + connectome library.  Run each modality in its OWN
;; fresh space (the per-modality isolation of Fig 6) — append a seed + run to a
;; copy of this file and feed it to the STATELESS endpoint:
;;
;;   client.sh run-file <this + olfactory-seed>
;;     (reached oA1 0) (reached oA2 0)  !(flow-step 1)  !(ranks)
;;     → ((c1 1) (c3 2) (c5 3) (m1 3) (oA1 0) (oA2 0))   ; olfactory path
;;
;;   client.sh run-file <this + visual-seed>
;;     (reached vB1 0) (reached vB2 0)  !(flow-step 1)  !(ranks)
;;     → ((c2 1) (c4 2) (m1 3) (vB1 0) (vB2 0))          ; visual path
;;
;; Both converge on the motor output m1 @ rank 3; the 0.3 synapse-weighted
;; threshold keeps each modality on its dominant path (olfactory: c1→c3→c5;
;; visual: c2→c4), excluding the other's weak cross-pathway.
;;
;; Stage 2 (DONE) keeps this exact model and replaces the synthetic (syn ...)
;; block with REAL FAFB v783 edges, seeding from `classification.csv`
;; (flow=afferent, by `class` modality).  The unchanged model reproduced a
;; native reference oracle node-for-node on real data — thermosensory K=1
;; (46 rank-1) and K=2 (46/45, iterate-to-fixed-point), 0 diff.  Extraction +
;; oracle: extract_fafb_subset.sh.  Full results + the substrate bug it found
;; (collapse-of-single-expression-result) + the O(N)-match tractability
;; boundary: STAGE2_RESULTS.md.  Background: docs/CONNECTOME_MULTISPACE.md +
;; docs/specs/flywire_connectome_spec.md §7/§11.
