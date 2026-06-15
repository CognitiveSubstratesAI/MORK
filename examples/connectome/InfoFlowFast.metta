;;;; InfoFlowFast.metta — scalable variant of the Fig-6a info-flow model
;;;;
;;;; Identical model to InfoFlow.metta, but the connectome is stored
;;;; REVERSE-KEYED as  (in <post> <pre> <cnt>)  instead of (syn <pre> <post> <cnt>).
;;;;
;;;; WHY: every hot query is BY POST — total-in/reached-in iterate the edges
;;;; INTO a neuron p.  With post leading the expression, `(match &self (in <p>
;;;; $r $c) …)` pins a concrete prefix `(in <p>` → Core's prefix-narrowed
;;;; core_match descends the trie to that subtrie and touches only p's in-edges
;;;; (O(in-degree)) instead of scanning every atom (O(N)).  `(reached <n> $k)`
;;;; is likewise pinned by n.  This is what makes the model tractable at
;;;; connectome scale.  (syn-keyed InfoFlow.metta can't narrow: the bound post
;;;; is the 2nd arg, not a leading prefix — every atom is `syn`.)
;;;;
;;;; Ingest edges as:  (in <post_root_id> <pre_root_id> <syn_count>)
;;;; Seed as:          (reached <afferent_root_id> 0)

;; (reached? N) → True iff a (reached N _) atom exists.  Pinned by N.
(= (reached? $n) (> (size-atom (collapse (match &self (reached $n $k) $n))) 0))

;; Σ syn_count over ALL input edges of P.  Pinned by P → O(in-degree).
(= (total-in $p)
   (foldl-atom (collapse (match &self (in $p $r $c) $c)) 0 $a $x (+ $a $x)))

;; Σ syn_count over input edges of P whose presynaptic neuron is reached.
(= (reached-in $p)
   (foldl-atom (collapse (match &self (in $p $r $c) ($r $c))) 0 $a $pr
       (+ $a (if (reached? (car-atom $pr)) (car-atom (cdr-atom $pr)) 0))))

(= (ratio $p) (/ (reached-in $p) (total-in $p)))
(= (qualifies? $p) (and (not (reached? $p)) (>= (ratio $p) 0.3)))

;; all post-synaptic neurons (functor-only → full walk, but ONCE per step).
(= (post-neurons) (unique-atom (collapse (match &self (in $p $r $c) $p))))
(= (step-candidates) (filter-atom (post-neurons) $p (qualifies? $p)))

(= (mark-each $lst $k)
   (if (== (size-atom $lst) 0)
       done
       (do (add-atom &self (reached (car-atom $lst) $k))
           (mark-each (cdr-atom $lst) $k))))

(= (flow-step $k)
   (let $cands (step-candidates)
     (if (== (size-atom $cands) 0)
         done
         (do (mark-each $cands $k)
             (flow-step (+ $k 1))))))

(= (ranks) (collapse (match &self (reached $n $k) ($n $k))))
