;;;; InfoFlowMS.metta — multi-space (App + Common) variant of the info-flow model
;;;;
;;;; Same deterministic Fig-6a rule as InfoFlow.metta, but structured for the
;;;; Whitepaper §9 App+Common federation: the connectome lives ONCE in a shared
;;;; `&common` space (read by every modality), and each sensory modality's
;;;; traversal state (`reached`/`rank`) lives in its OWN space — passed as the
;;;; `$ss` (state-space) argument.  Run per modality with isolated `$ss`; the
;;;; modalities never cross-contaminate, and their rank sets are directly
;;;; comparable (Fig 6d/e).  See CONNECTOME_MULTISPACE.md.
;;;;
;;;; Setup (caller):
;;;;   !(bind! &common (new-space))            ; shared connectome
;;;;   !(add-atom &common (syn <pre> <post> <cnt>))  ...
;;;;   !(bind! &olfactory (new-space))         ; one state space per modality
;;;;   !(add-atom &olfactory (reached <seed> 0)) ...
;;;;   !(flow-step &olfactory 1)               ; propagate in that modality
;;;;   !(ranks &olfactory)                     ; read its ranks

;; (reached? $ss $n) → True iff a (reached $n _) atom exists in state space $ss.
(= (reached? $ss $n) (> (size-atom (collapse (match $ss (reached $n $k) $n))) 0))

;; Σ syn_count over ALL input edges of P — connectome is SHARED in &common.
(= (total-in $p)
   (foldl-atom (collapse (match &common (syn $r $p $c) $c)) 0 $a $x (+ $a $x)))

;; Σ syn_count over input edges of P whose presynaptic neuron is reached in $ss.
(= (reached-in $ss $p)
   (foldl-atom (collapse (match &common (syn $r $p $c) ($r $c))) 0 $a $pr
       (+ $a (if (reached? $ss (car-atom $pr)) (car-atom (cdr-atom $pr)) 0))))

;; weighted input ratio for P against the reached set in $ss.
(= (ratio $ss $p) (/ (reached-in $ss $p) (total-in $p)))

;; P qualifies this step iff not-yet-reached (in $ss) and ratio ≥ 0.3.
(= (qualifies? $ss $p) (and (not (reached? $ss $p)) (>= (ratio $ss $p) 0.3)))

;; all post-synaptic neurons in the SHARED connectome (the candidate pool).
(= (post-neurons) (unique-atom (collapse (match &common (syn $r $p $c) $p))))

;; candidates to add this step for modality $ss.
(= (step-candidates $ss) (filter-atom (post-neurons) $p (qualifies? $ss $p)))

;; mark each neuron in $lst as reached at rank $k IN state space $ss.
(= (mark-each $ss $lst $k)
   (if (== (size-atom $lst) 0)
       done
       (do (add-atom $ss (reached (car-atom $lst) $k))
           (mark-each $ss (cdr-atom $lst) $k))))

;; synchronous flow step for modality $ss: mark all qualifying candidates at
;; rank $k, recurse at $k+1.  Stops when no new neuron crosses the threshold.
(= (flow-step $ss $k)
   (let $cands (step-candidates $ss)
     (if (== (size-atom $cands) 0)
         done
         (do (mark-each $ss $cands $k)
             (flow-step $ss (+ $k 1))))))

;; all (neuron . rank) pairs reached in modality $ss.
(= (ranks $ss) (collapse (match $ss (reached $n $k) ($n $k))))
