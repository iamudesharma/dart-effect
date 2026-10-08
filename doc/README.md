# Effect Core contracts

Effect computations are lazy and reusable. Expected failures, programmer defects
and interruption remain distinct. Resources use scoped, exactly-once cleanup;
Runtime.shutdown waits for child fibers and finalizers. Cancellation is cooperative.

Dart generic covariance means the environment parameter is requirement
documentation, not a complete static proof of service provision. Context service
presence is checked at runtime.

Read the [runtime guide](https://effect-dart.ginjustice4.chatgpt.site/docs/runtime/)
and [testing guide](https://effect-dart.ginjustice4.chatgpt.site/docs/testing/) for
implementation boundaries and recorded verification.
