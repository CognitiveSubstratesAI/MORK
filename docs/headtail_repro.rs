// Standalone reproduction of upstream MORK's HeadTailSink (kernel/src/sinks.rs,
// commit d409be2) — the exact fill+capacity logic, copied verbatim. The `extrema`
// PathMap<()> is modeled by a BTreeSet<Vec<u8>> (ordered set of paths):
//   - upstream `extrema.insert(p,()).is_none()` (newly inserted) == BTreeSet::insert -> true
//   - upstream `descend_last_path()`  (largest path)  == iter().next_back()
//   - upstream `to_next_val()`        (smallest path) == iter().next()
// Everything else (the `if head {<=} else {>=}` capacity test, the SHARED fill
// branch that updates `extremum` only on `extremum <= mpath`) is verbatim.

use std::collections::BTreeSet;

struct HeadTailSink {
    head: bool,                 // upstream const generic `head: bool`
    extrema: BTreeSet<Vec<u8>>, // upstream extrema: PathMap<()>
    count: usize,
    max: usize,
    extremum: Vec<u8>,          // upstream extremum: Vec<u8> (eviction boundary)
}

impl HeadTailSink {
    fn new(head: bool, max: usize) -> Self {
        Self { head, extrema: BTreeSet::new(), count: 0, max, extremum: vec![] }
    }

    // verbatim port of HeadTailSink::sink
    fn sink(&mut self, mpath: &[u8]) {
        if self.count == self.max {
            let ignore = if self.head { &self.extremum[..] <= mpath }
                         else         { &self.extremum[..] >= mpath };
            if ignore {
                // doesn't displace any path
            } else {
                let old = self.extremum.clone();
                self.extrema.insert(mpath.to_vec());
                self.extrema.remove(&old);
                self.extremum = if self.head {
                    self.extrema.iter().next_back().cloned().unwrap() // descend_last_path
                } else {
                    self.extrema.iter().next().cloned().unwrap()      // to_next_val
                };
            }
        } else {
            // SHARED fill branch — updates extremum only on `extremum <= mpath`
            // (tracks the MAX inserted, for BOTH head and tail).
            if &self.extremum[..] <= mpath {
                if self.extrema.insert(mpath.to_vec()) {
                    self.extremum = mpath.to_vec();
                    self.count += 1;
                }
            } else {
                if self.extrema.insert(mpath.to_vec()) {
                    self.count += 1;
                }
            }
        }
    }
}

fn run(head: bool, n: usize, order: &[&str]) {
    let mut s = HeadTailSink::new(head, n);
    for p in order { s.sink(p.as_bytes()); }
    let kept: BTreeSet<&str> = s.extrema.iter()
        .map(|v| std::str::from_utf8(v).unwrap()).collect();

    // ground truth: the n smallest (head) or n largest (tail) of the input set
    let mut sorted: Vec<&str> = order.iter().cloned().collect();
    sorted.sort(); sorted.dedup();
    let truth: BTreeSet<&str> = if head {
        sorted.iter().take(n).cloned().collect()
    } else {
        sorted.iter().rev().take(n).cloned().collect()
    };

    let name = if head { "head" } else { "tail" };
    let ok = kept == truth;
    println!("{} {}  input order {:?}", name, n, order);
    println!("    kept  : {:?}", kept);
    println!("    truth : {:?}   ({})", truth,
        if ok { "OK" } else { "BUG — kept set is NOT the correct extreme-N" });
}

fn main() {
    println!("=== upstream HeadTailSink logic, verbatim ===\n");
    // head is the control (should be correct); tail is the suspect.
    run(true,  2, &["e","a","b"]);            // head 2 → {a,b}
    run(false, 2, &["e","a","b"]);            // tail 2 → want {b,e}
    println!();
    run(true,  3, &["e","a","c","b","d"]);    // head 3 → {a,b,c}
    run(false, 3, &["e","a","c","b","d"]);    // tail 3 → want {c,d,e}
}
