{-- OPTIONS_GHC -Werror #-}

{- |
    # The Problem

    Uses `seq` to prevent overly-eager evaluation.

    Without this, `λx.fg` would compile to `K(fg)` which will cause
    the evaluation of `(fg)` at definition time, instead of waiting until
    `x` is passed.

    We can prevent this by transforming `λx.fg` into `λx.SKxfg`,
    which will delay the evaluation of `fg` until the right time.

    This transformation is especially important in recursive code, which
    will almost always contain an if expressions. If both branches of
    the if expression are always evaluated, then the loop will never
    terminate.

    # The Algorithm

    The goal of this algorithm is to make sure that no significant
    evaluation takes place before the most recent lambda binding has
    been made available.

      An example of insignificant evaluation, is applying `K` to `S`,
      which trivially becomes `KS`.

      Another example, is applying `3` to `ADD`, which trivial becomes
      `(ADD 3)`. This is because the `ADD` jet has arity two.

      In general, applying a value to a function of arity one is
      significant, and all other application is insignificant.

    The basic idea is to recurse through expressions, starting at the
    leaves, determine their arity, and delay any significant applications
    by transforming `(fg)` into `(SKxfg)`. This will prevent `f` from
    being applied to `g` until `x` is supplied.

    We treat the most recently bound variable as having arity 0, which is
    treated differently. Expressions of arity 0 do not need to be changed,
    since their evaluation already depends on the most-recently-bound
    variable.

    The arity of combinators:

      *S    -> 3
      *K    -> 2
      *J    -> 2
      *Jⁿ   -> 2
      *Jⁿtb -> n
      *D    -> 1

    The arity of variables:

      *x    -> 0 (most recently bound, or all from jet arguments)
      *f    -> 1 (free variable, arity statically unknowable)

    The arity of lambdas:

      *(λv.B) -> 0       (if B references `x`)
      *(λv.B) -> (*B)+1

    The arity of applications:

      *(Keₙ)  -> n+1
      *(e₀eₙ) -> 0
      *(eₙe₀) -> 0
      *(eₙeₘ) -> n-1

    The transformation of applications:

      *(e₁eₙ) -> (SEQ x e e)
      *(eₙeₙ) -> ee

    ## Better Output for Jets

    - Let's look at an example:

      - `λx.λy.λz.xyz`

    - Without this trasnformation, this compiles to:

      - `SKK`

    - But that doesn't preserve evaluation order.

      - `(λx.λy.λz.xyz) ded %too-early` evaluates to:

         `(λz. ded %too-early z)`

      - But `SKK ded %too-early` evaluates to:

        `(ded %too-early)`

    - The transformation above soves the problem, by instead producing:

      ```
      (S (S (K S)
         (S (K (S (K S)))
            (S (K (S S (K K))) (S (K (S (K K) S)) (S (K (S (S K))) K)))))
      (K (S K)))
      ```

    - However, this is large. To solve this problem, we can take advantage
      of the jet system. Let's look at the same example, jetted:

       ```
       J J J K (λx.λy.λz.xyz)
       ```

    - Because the jet system will delay evaluation until all three
      arguments have been passed, the transformation is not necessary for
      those arguments.

    - So, we can recover our nice output:

      ```
      J J J K (S K K)
      ```

    ## Better Output with `yet`

    In some expressions, we can produce slightly smaller code by using
    `In` instead of `seq`. `In` is the bulk combinator for the identity
    function. For example, `I5` is `J J J J J %In I`.

    For example, `λx.(fgx)` becomes λx.(seq x f g x), which produces
    significantly larger output.

    Instead, we can produce: `λx.(I3 f g x). This also delays the
    application `(fg)` until x is provided, but does so without
    introducing another variable reference, so the resulting code size
    is significantly smaller.

    When does this rule apply?

      (pqx) -> (I3 p q x)
      (pqrx) -> (I4 p q r x)
      (pqrsx) -> (I5 p q r s x)
      ...

    Informally, any application that would need to be delayed, but the
    result is eventually applied to `x`.

    What's the algorithm for this?

    It doesn't quite fit into the current model.

    When we process `fgx`, we first process `fg`. So, by the time we
    see the `x` we have already transformed `fg` into `SKxfg`.

    Let's just try some stuff.

    If we convert an expression to a tree first, then

      `(p q r s x)` turns into `p[q,r,s,x]`

    If the head and the first argument would need to be delayed, then
    we can apply this transformation.

    This is too agressive, though.  For example:

      `(K p q r x)` would become `(I5 K p q r x)`

    But, `Kpq` doesn't need to be delayed.

    Instead, it would be better to produce:

      `(I3 (Kpq) r x)`

    So, really, we want to find things of the shape:

      `AB(C‥)x` where `AB` would usually need to be delayed.

    And transform that into

      `In A B (C‥) x`

    I guess, in `Ex`, we can see that the RHS has arity 0, and remember
    that. Later, when we go to delay `AB`, we can use `In` instead of
    `Qx`. We will also need to know how far down the list we have gone.

    Let's go through an example:

      `ABCDEx`

    We see `(ABCDE)x` and x has arity 0.

      So, we begin processing `(ABCDE)` with the knowledge that there is an
      forced expression 1 steps behind.

        This is an application, with a RHS of arity (>0), so we process the
        LHS `(ABCD)`. with the knowledge that there is an forced expression 2
        steps behind.

          This is an application, with a RHS of arity (>0), so we process the
          LHS `(ABC)`. with the knowledge that there is an forced expression 3
          steps behind.

            This is an application, with a RHS of arity (>0), so we process the
            LHS `(AB)`. with the knowledge that there is an forced expression 4
            steps behind.

            This is an application, with a RHS of arity (>0), so we process the
            LHS `A`. with the knowledge that there is an forced expression 5
            steps behind.

            A is not an application, so we return `A` with arity 1.

          `(AB)` is an application that needs to be delayed, but we know
          that there is a forced expression 4 steps behind.

          So we produce `(I6 A B)` with arity 4

        `(I5 A B C)` has arity 3

        `(I5 A B C D)` has arity 2

      `(I5 A B C D E)` has arity 1

    Then `((I5 A B C D E) x)` is an application of an expression of
    arity 1 against an expression of arity 0, which is safe.

    This approach seems to work.
-}

{-
  Thinking out loud:

    What does MakeStrict operate on?

    Lambda expressions whose free variables are uruk values.

    What is an uruk value?

      An application of two uruk values
      S, K, J, D, or a jet.

    In the `pak` example:

      In the `pak` example:

      ```
      ++  (pak n)    (J J K (n sksucc skzero))
      ```

    We have this body: `(J J K (n sksucc skzero))`

    Here we have an expression that contains three uruk values: `J`,
    `J`, and `K`. Would combining them be the right anwser?

    I guess no.

      What is the arity of this?

        `(J J x)`

      Well, we can't know because we don't know if `x` is a `J`
      or not.

      However, `J` has arity 2, and `(J J)` also has arity two. The
      given value-arity machinery knows this. So, actually, yes: I think
      combining applications of values into values will give correct
      arity information.
-}

module Urbit.Moon.MakeStrict (makeStrict, makeJetStrict) where

import ClassyPrelude hiding (try)

import Bound
import Urbit.Uruk.Bracket

import Data.List (nub)

import Text.Show.Pretty (ppShow)
import Bound.Var        (unvar)
import Control.Arrow    ((<<<), (>>>))
import Numeric.Natural  (Natural)
import Numeric.Positive (Positive)

import qualified Urbit.Uruk.Fast.Types  as F
import qualified Urbit.Uruk.Refr.Jetted as Ur


-- Types -----------------------------------------------------------------------

type ExpV a = Exp () (Var () a)


-- Utils -----------------------------------------------------------------------

{-
    [eₙe₀] -> ee
    [e₁eₙ] -> SKxee
    [eₙeₙ] -> ee
-}
fixApp :: Show a => ExpV a -> (Int, ExpV a) -> (Int, ExpV a) -> ExpV a
fixApp seq (_xArgs, x) (0, y)      = x :@ y
fixApp seq (1, x)      (_yArgs, y) = trace msg $ seq :@ Var (B ()) :@ x :@ y
 where msg = force (indent ("[delay]:\n" <> indent (ppShow ((1, x), (_yArgs, y))) <> "\n"))

fixApp seq (_, x)      (_yArgs, y) = x :@ y

{-
    *(Keₙ)  -> n+1
    *(e₀eₙ) -> 0
    *(eₙe₀) -> 0
    *(eₙeₘ) -> n-1
-}
appArity :: Bool -> Int -> Int -> Int
appArity True  _     yArgs = yArgs+1
appArity _xIsK 0     _     = 0
appArity _xIsK _     0     = 0
appArity _xIsK xArgs _     = xArgs-1

wrap :: (a -> (Bool, Int)) -> Var () a -> (Bool, Int)
wrap f = \case
  B () -> (False, 1)
  F v  -> f v

{- |
    Returns the arity of an expression and transform it if necessary.

    `f x` should return `(x == K, arity x)`.
-}
recur' :: Show a => Eq a => (ExpV a, ExpV a, a -> (Bool, Int)) -> ExpV a -> ((Bool, Int), [Var () a], ExpV a)
recur' (seq,k,f) = \case
  Var v -> (unvar (const (False, 0)) f v, [v], Var v)
  Lam () b ->
    let ((_, funArity), refs, bodExp) = recur (F <$> seq, F <$> k, wrap f) $ fromScope b
        ourRefs = cvt refs
        arity = if elem (B ()) ourRefs then 0 else funArity+1
    in ((False, arity), ourRefs, Lam () (toScope bodExp))

  x :@ y ->
    let
      ((xIsK, xArgs), xRefs, xVal) = recur (seq,k,f) x
      ((yIsK, yArgs), yRefs, yVal) = recur (seq,k,f) y
      resVal = fixApp seq (xArgs, xVal) (yArgs, yVal)
      resArgs = appArity xIsK xArgs yArgs
      resIsK = False
    in
      ((resIsK, resArgs), nub (xRefs<>yRefs), resVal)

 where
  cvt :: [Var () (Var () a)] -> [Var () a]
  cvt = mapMaybe (unvar (const Nothing) Just)

recur :: Show a => Eq a => (ExpV a, ExpV a, a -> (Bool, Int)) -> ExpV a -> ((Bool, Int), [Var () a], ExpV a)
recur tup x = trace msg result
 where
  result@((_, arity), free, exp) = recur' tup x
  msg = unlines
    [ "[recur]"
    , ""
    , ppShow exp
    , ""
    , "  free: " <> show free
    , "  arity: " <> show arity
    , ""
    ]


getExp :: ((Bool, Int), [Var () a], ExpV a) -> ExpV a
getExp (_,_,e) = e

{-
  foldValues turns any application of constant values into a single
  constant value. This allows us to make use of the given `arity`
  function to get better arity information for more complicated constant
  expressions.
-}
foldConstantValues :: forall b p . (p -> p -> p) -> Exp b p -> Exp b p
foldConstantValues app = go Just id
 where
  go :: (v -> Maybe p) -> (p -> v) -> Exp b v -> Exp b v
  go val unval = \case
    Var v -> Var v
    Var (val -> Just x) :@ Var (val -> Just y) -> Var (unval $ app x y)
    x :@ y -> go val unval x :@ go val unval y
    Lam bi b ->
      Lam bi
        $ toScope
        $ go (unvar (const Nothing) val) (fmap F unval)
        $ fromScope b


-- Entry-Point for Normal Functions --------------------------------------------

makeStrict :: Show p => Eq p => (p, p, p -> p -> p, p -> Int) -> Exp () p -> Exp () p
makeStrict (seq,k,app,arity) = go . foldConstantValues app
 where
  go = \case
    x   :@ y -> go x :@ go y
    Lam () b -> Lam () $ toScope $ getExp . recur (sv, kv, r) $ fromScope b
    Var v    -> Var v
  sv = Var (F seq)
  kv = Var (F k)
  r = \x -> (x == k, arity x)


-- Optimized Entry-Point for Jetted Functions ----------------------------------

{-
    TODO This is very complicated code to do something simple. Clean up!

    This expects it's input to be of the form `λx.λy.[...]b`. `n`
    bindings folloed by an expressions.

    It's the same as `makeStrict` except that it treats the first `n`
    bindings as having arity `0`.
-}
makeJetStrict
  :: Show p => Eq p => (p, p, p -> p -> p, p -> Int) -> Int -> Exp () p -> Exp () p
makeJetStrict (seq, k, app, arity) n topExp =
  top n (foldConstantValues app topExp)
 where
  top 0 e          = makeStrict (seq, k, app, arity) e
  top n (Var v   ) = makeStrict (seq, k, app, arity) (Var v)
  top n (x   :@ y) = makeStrict (seq, k, app, arity) (x :@ y)
  top n (Lam () b) = Lam () $ toScope $ go initTup (n - 1) $ fromScope b

  initTup = (,,,) (Var (F seq))
                  (Var (F k))
                  (\x -> (x == k, arity x))
                  (\x -> (x == k, arity x))

  go
    :: Show a
    => Eq a
    => (ExpV a, ExpV a, a -> (Bool, Int), a -> (Bool, Int))
    -> Int
    -> ExpV a
    -> ExpV a
  go (seq, k, f, j) 0 b          = getExp $ jetRecur (seq, k, f, j) b
  go (seq, k, f, j) n b@(Var _ ) = getExp $ recur (seq, k, f) b
  go (seq, k, f, j) n b@(_ :@ _) = getExp $ recur (seq, k, f) b
  go (seq, k, f, j) n (Lam () b) =
    Lam ()
      $ toScope
      $ go (F <$> seq, F <$> k, wrap f, wrapJet j) (n - 1)
      $ fromScope b

  wrapJet :: (a -> (Bool, Int)) -> Var () a -> (Bool, Int)
  wrapJet = unvar (const (False, 0))

{- |
    Returns the arity of an expression and transform it if necessary.

    `f x` should return `(x == K, arity x)`.
-}
jetRecur'
  :: Show a => Eq a
  => (ExpV a, ExpV a, a -> (Bool, Int), a -> (Bool, Int))
  -> ExpV a
  -> ((Bool, Int), [Var () a], ExpV a)
jetRecur' (seq,k,f,j) = \case
  Var v -> (unvar (const (False, 0)) f v, [v], Var v)

  Lam () b ->
    let ((_, funArity), refs, bodExp) = recur (F <$> seq, F <$> k, wrap f) $ fromScope b
        ourRefs = cvt refs
        arity = if elem (B ()) ourRefs then 0 else funArity+1
    in ((False, arity), ourRefs, Lam () (toScope bodExp))

  x :@ y ->
    let
      ((xIsK, xArgs), xRefs, xVal) = jetRecur (seq,k,f,j) x
      ((yIsK, yArgs), yRefs, yVal) = jetRecur (seq,k,f,j) y
      resVal = fixApp seq (xArgs, xVal) (yArgs, yVal)
      resArgs = appArity xIsK xArgs yArgs
      resRefs = nub (xRefs <> yRefs)
      resIsK = False
    in
      ((resIsK, resArgs), resRefs, resVal)

 where
  cvt :: [Var () (Var () a)] -> [Var () a]
  cvt = mapMaybe (unvar (const Nothing) Just)

jetRecur
  :: (Show a, Eq a)
  => (ExpV a, ExpV a, a -> (Bool, Int), a -> (Bool, Int))
  -> ExpV a
  -> ((Bool, Int), [Var () a], ExpV a)
jetRecur tup x = trace msg result
 where
  result@((_, arity), free, exp) = jetRecur' tup x
  msg = unlines
    [ "jetRecur:"
    , "  arity: " <> show arity
    , "  free: " <> show free
    , "  exp:"
    , indent (indent (ppShow exp))
    ]

indent :: String -> String
indent = unlines . fmap ("  " <>) . lines

l n b = Lam () (abstract1 n b)

testTup :: (String, String, String -> String -> String, String -> Int)
testTup = ("Q", "K", (<>), const 1)

testStrict = makeJetStrict testTup

instance IsString (Exp () String) where fromString = Var


{-
  (1,'inc',(S (K PAK) (S (K (S (S (K S) K))) (S (S (K S) (S (K (S (K S))) (S (K (S S (K K))) (S (K (S (K K) S)) (S (K (S SE
  Q)) K))))) (K (S K))))))

  (2,'add',(S (K (S (S SEQ (K PAK)))) (S (S (K (S (K S) K)) (S (K S) (S (K (S (K S))) (S (K (S S (K K))) (S (K (S (K K) S))
   (S (K (S SEQ)) K)))))) (K (S (S (K S) (S (K (S (K S))) (S (K (S S (K K))) (S (K (S (K K) S)) (S (K (S SEQ)) K))))) (K (S
   K)))))))
-}