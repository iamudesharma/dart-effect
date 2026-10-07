# 001: Typed aggregate environments and trampoline

Use a concrete R parameter for typed selectors, not an inferred requirement union. Because Dart generics are covariant, R is advisory plus runtime-checked; widening to Object can bypass static provision checks. Explicit
sealed common error types keep composition sound in Dart. Context keys use
identity instead of names. Internal instruction nodes erase types to Object?
only at the interpreter boundary; constructor and continuation closures restore
A/E/R with checked casts. This existential storage is necessary for a stack of
heterogeneous continuations; it must never escape as a public dynamic result.

A trampoline provides deep-chain stack safety. Cooperative cancellation and
protected cleanup cannot forcibly abort arbitrary Dart Futures or CPU loops.
Cause cleanup composition is an original sequential tree; upstream v4 behavior
may use a different representation. This is a documented Dart divergence.
