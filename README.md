# Hindley-Milner

A toy implementation of the [Hindley-Milner type
system](https://en.wikipedia.org/wiki/Hindley%E2%80%93Milner_type_system). This
implementation is lazy and supports recursive bindings.

## Quickstart

Using the interactive REPL:

```sh
$ stack run
hm> incr = add 1
incr :: Double -> Double
hm> incr 0
1
hm> dot f g a = f (g a)
dot :: ($1 -> $2) -> ($3 -> $1) -> $3 -> $2
hm> dot incr incr 0
2
```

See the `examples/` folder for a few more sample definitions and the [Haddock
documentation](https://mtth.github.io/hindley-milner) for more information.

## References

+ https://en.wikipedia.org/wiki/Hindley%E2%80%93Milner_type_system
+ http://dev.stephendiehl.com/fun/006_hindley_milner.html
+ https://en.wikipedia.org/wiki/Lambda_calculus
