
module Core where

import qualified IVarSet as IS
import Common
import Interval
import Substitution

{-

--------------------------------------------------------------------------------

We adapt ordinary NbE to CTT, with explicit call-by-name interval
substitutions.

In ordinary NbE
- we have terms in a var context, t : Tm Γ A
- semantic values have closures instead of binders
- eval has type:
    (Γ Δ : Con)(env : ValSub Γ Δ)(A : Ty Δ) (t : Tm Δ A) → Val Γ (evalTy env A)
  where evalTy evaluates types, but usually we only have "eval", because of
  Russell universes and weak typing of definitions. In the simplest case, we
  only pass "env" and "t" as arguments and nothing else. In some impls, we might
  also want to pass "Γ" as well, which makes it possible to create "fresh"
  variables during evaluation.
- we store (env : ValSub Γ Δ) and (t : Tm (Δ,A) B) in a closure.

In CTT we have terms in a triple context consisting of
 - interval var context
 - a cofibration
 - a fibrant var context
written as ψ|α|Γ, with t : Tm (ψ|α|Γ) A

In ordinary TT NbE, environments are semantic context morphisms ("ValSub").  We
try to do the same in CTT. Informally, a morphism between ψ|α|Γ and ψ'|α'|Γ'
consists of
 - an interval substitution σ : ISub ψ ψ'
 - a cof morphism δ : α ⇒ α'[σ]
 - a substitution ν : ValSub Γ (Γ'[σ,δ])

The full type of eval is:

  eval : ∀ ψ α Γ π' α' Γ' (σ : ISub ψ ψ')(δ : α ⇒ α'[σ])(ν : ValSub Γ (Γ'[σ,δ]))
           (A : Ty (ψ'|α'|Γ'))
           (t : Tm (ψ'|α'|Γ') A)
         → Val (ψ|α|Γ) (eval A)

Now, what's actually relevant from this? We only pass the following data:

  ψ α Γ σ ν t

- ψ is given as a natural number size. It is used to get fresh ivars in
  filling operations.
- α is needed in forcing (see later)
- Γ is given as a size, it's used to distinguish closed and open evaluation;
  Γ=0 marks the closed case.
- σ,ν,t are needed in evaluation


-- Evaluation, substitution, forcing
--------------------------------------------------------------------------------

- Evaluation:   Env  -> Tm  -> Val.

- Substitution: ISub -> Val -> Val. Substitutes ivars. It *does not* perform any
  expensive operation, it only stores an explicit substitution into values. It does
  compose explicit substitutions eagerly.

- Forcing: Env -> Val -> Val.
  Computes values to head normal form w.r.t. explicit substitution and
  cofibrations. It pushes subs down. It only does expensive computation on
  neutrals, where the following might happen:
    1. the sub that's being pushed down creates redexes in the neutral
    2. the current cofibration creates redexes in the neutral

  More detail on 2. Recall that in vanilla NbE, weakening of values comes for
  free, we can just use values under extra binders. In CTT, weakening of fibrant
  contexts is still free, but cofibration weakening is not. If I have a neutral
  value under some cof, it might not be neutral under a conjuncted cof.

  However, cofs are only every weakened! There's no general "substitution"
  operation with cof morphisms. For this reason, we don't want to explicitly
  store cofs; we only pass the "current" cof and do forcing on demand. We also
  don't have to store cofs in closures!

Semantic ops:
  - They assume that their inputs are forced!
  - coe/hcom have two flavors

-- neutrals

-- coe, hcom
-}

{-

- Should we call VSystem neutral instead, and always pair it up with an ivar set?
- Better binder ergonomics in coe, hcom, mapVSystem?
- sub checks for idSub, then we don't have to write duplicate code
  where there's an extra ISub arg.

- when we make systems, should we instead use "inlined" semantic versions
  of SCons/SEmpty? (YES)

- TODO: try to get rid of typed forcing! Code should be much cleaner that way
  and overhead should be tolerable.

-}


newtype F a = F {unF :: a}
  deriving SubAction via a

-- Syntax
--------------------------------------------------------------------------------

type Name = String
type Ty = Tm

data Tm
  = TopVar Lvl ~(DontPrint Val)
  | LocalVar Ix
  | Let Name Tm Ty Tm

  | Pi Name Ty Ty
  | App Tm Tm
  | Lam Name Tm

  | Sg Name Ty Ty
  | Pair Tm Tm
  | Proj1 Tm
  | Proj2 Tm

  | U

  | PathP Name Ty Tm Tm         -- PathP i.A x y
  | PApp Tm Tm Tm I             -- (x : A i0)(y : A i1)(t : PathP i.A x y)(j : I)
  | PLam Name Tm

  | Coe I I Name Ty Tm          -- coe r r' i.A t
  | HCom I I Name Ty System Tm  -- hcom r r' i.A [α → t] u

  -- we switch the field orders here compared to the papers, because
  -- this one is the sensible "dependency" order

  | GlueTy Ty System            -- Glue A [α ↦ B]      (B : Σ X (X ≃ A))
  | GlueTm Tm System            -- glue a [α ↦ b]
  | Unglue Tm System            -- unglue g [α ↦ B]
  deriving Show

-- | Atomic equation.
data CofEq = CofEq I I
  deriving Show

-- | Conjunction of equations.
data Cof = CTrue | CAnd {-# unpack #-} CofEq Cof
  deriving Show

data System = SEmpty | SCons Cof Tm System
  deriving Show


-- Cof and System semantics
--------------------------------------------------------------------------------

data NeCof
  = NCEq I I
  | NCAnd NeCof NeCof
  deriving Show

data VCof
  = VCTrue
  | VCFalse
  | VCNe NeCof IS.IVarSet
  deriving Show

ctrue  = F VCTrue
cfalse = F VCFalse

cand :: F VCof -> F VCof -> F VCof
cand c1 c2 = case (unF c1, unF c2) of
  (VCFalse    , c2         ) -> cfalse
  (_          , VCFalse    ) -> cfalse
  (VCTrue     , c2         ) -> F c2
  (c1         , VCTrue     ) -> F c1
  (VCNe n1 is1, VCNe n2 is2) -> F (VCNe (NCAnd n1 n2) (is1 <> is2))

iToVarSet :: I -> IS.IVarSet
iToVarSet = \case
  IVar x -> IS.singleton x
  _      -> mempty

vCofToVarSet :: F VCof -> IS.IVarSet
vCofToVarSet cof = case unF cof of
  VCTrue    -> mempty
  VCFalse   -> mempty
  VCNe _ is -> is

ceq :: F I -> F I -> F VCof
ceq c1 c2 = case (unF c1, unF c2) of
  (i, j) | i == j -> ctrue
  (i, j) -> matchIVar i
    (\x -> matchIVar j
     (\y -> F (VCNe (NCEq i j) (IS.singleton x <> IS.singleton y)))
     cfalse)
    cfalse

data NSystemComps cof
  = NSEmpty
  | NSCons cof ~Val (NSystemComps cof)
  deriving Show

data NSystem cof = NSystem {_nsys :: NSystemComps cof, _ivars :: IS.IVarSet}
  deriving Show

data VSystem cof
  = VSTotal ~Val
  | VSNe {-# unpack #-} (NSystem cof)
  deriving Show

unFSystem :: F (VSystem (F VCof)) -> VSystem VCof
unFSystem = coerce

unFNSystem :: NSystem (F VCof) -> NSystem VCof
unFNSystem = coerce

evalI :: SubArg => NCofArg => I -> F I
evalI i = F (sub (sub i ?sub) ?cof)

evalEq :: SubArg => NCofArg => CofEq -> F VCof
evalEq (CofEq i j) = ceq (evalI i) (evalI j)

-- (σ : ISub Γ Δ)(α : Cof Γ) → Cof Δ → F (VCof Γ)
evalCof :: SubArg => NCofArg => Cof -> F VCof
evalCof = \case
  CTrue       -> ctrue
  CAnd eq cof -> cand (evalEq eq) (evalCof cof)

sempty :: F (VSystem (F VCof))
sempty = F (VSNe (NSystem NSEmpty mempty))

bindI' :: (IDomArg => SubArg => NCofArg => IVar -> a)
       -> (IDomArg => SubArg => NCofArg => a)
bindI' act =
  let fresh = ?idom in
  let ?idom = ?idom + 1
      ?sub  = extSub ?sub (IVar ?idom)
      ?cof  = extSub ?cof (IVar ?idom)
  in act fresh
{-# inline bindI' #-}

bindI :: (IDomArg => NCofArg => IVar -> a) -> (IDomArg => NCofArg => a)
bindI act =
  let fresh = ?idom in
  let ?idom = ?idom + 1
      ?cof  = extSub ?cof (IVar ?idom)
  in act fresh
{-# inline bindI #-}

conjIVarI :: NCof -> IVar -> I -> NCof
conjIVarI cof x i = mapSub go cof where
  go _ j = case j of
    IVar y | x == y -> i
    j               -> j

conjNeCof :: NCof -> F NeCof -> NCof
conjNeCof ncof necof = case unF necof of
  NCAnd c1 c2 -> ncof `conjNeCof` F c1 `conjNeCof` F c2
  NCEq i j -> case (i, j) of
    (IVar x, IVar y) -> let (x, i) = if x < y then (x, IVar y)
                                              else (y, IVar x) in
                        conjIVarI ncof x i
    (IVar x, j     ) -> conjIVarI ncof x j
    (i     , IVar y) -> conjIVarI ncof y i
    _                -> impossible

conjVCof :: NCof -> F VCof -> NCof
conjVCof ncof cof = case unF cof of
  VCFalse      -> impossible
  VCTrue       -> ncof
  VCNe necof _ -> conjNeCof ncof (F necof)

bindCof :: F VCof -> (NCofArg => a) -> (NCofArg => a)
bindCof cof action = let ?cof = conjVCof ?cof cof in action

scons ::
  IDomArg => NCofArg =>
  F VCof -> Val -> F (VSystem (F VCof)) -> F (VSystem (F VCof))
scons cof ~v sys = case unF sys of
  VSTotal v              -> F (VSTotal v)
  VSNe (NSystem nsys is) -> F (VSNe (NSystem (NSCons cof v nsys) (vCofToVarSet cof <> is)))
{-# inline scons #-}

evalSystem :: IDomArg => SubArg => NCofArg => DomArg => EnvArg =>
              System -> F (VSystem (F VCof))
evalSystem = \case
  SEmpty          -> sempty
  SCons cof t sys ->
    let vcof = evalCof cof in
    scons vcof (bindCof vcof (bindI \_ -> eval t)) (evalSystem sys)

-- TODO: we generally get a runtime closure from this! Try to make GHC lambda-lift function args
-- instead!
mapNSystemComps :: (IDomArg => NCofArg => DomArg => IVar -> Val -> Val) ->
               (IDomArg => NCofArg => DomArg => NSystemComps (F VCof) -> NSystemComps (F VCof))
mapNSystemComps f = go where
  go NSEmpty            = NSEmpty
  go (NSCons cof v sys) = NSCons cof (bindCof cof (bindI \i -> f i v)) (go sys)
{-# inline mapNSystemComps #-}

mapNSystem :: (IDomArg => NCofArg => DomArg => IVar -> Val -> Val) ->
              (IDomArg => NCofArg => DomArg => NSystem (F VCof) -> NSystem (F VCof))
mapNSystem f (NSystem nsys is) = NSystem (mapNSystemComps f nsys) is
{-# inline mapNSystem #-}


mapVSystem :: (IDomArg => NCofArg => DomArg => IVar -> Val -> Val) ->
              (IDomArg => NCofArg => DomArg => F (VSystem (F VCof)) -> F (VSystem (F VCof)))
mapVSystem f sys = case unF sys of
  VSTotal v  -> F (VSTotal (bindI \i -> f i v))
  VSNe nsys  -> F (VSNe (mapNSystem f nsys))
{-# inline mapVSystem #-}

data Ne
  = NLocalVar Lvl
  | NSub Ne Sub
  | NApp Ne Val
  | NPApp Ne Val Val IVar
  | NProj1 Ne
  | NProj2 Ne
  | NCoe I I Name VTy Val
  | NHCom I I Name VTy (NSystem VCof) Val
  | NUnglue Val (NSystem VCof)
  | NGlue Val (NSystem VCof)
  deriving Show

data Env
  = ENil
  | EDef Env ~Val
  deriving Show

type EnvArg = (?env :: Env)

-- | Defunctionalized closures.
data Closure
  -- ^ Body of vanilla term evaluation.
  = CEval Sub Env Tm

  -- ^ Body of function coercions.
  | CCoePi I I Name VTy Closure Val

  -- ^ Body of function hcom.
  | CHComPi I I Name VTy Closure {-# unpack #-} (NSystem VCof) Val
  deriving Show

-- | Defunctionalized closures for IVar abstraction.
data IClosure
  = ICEval Sub Env Tm
  | ICCoePathP I I Name IClosure Val Val Val
  | ICHComPathP I I Name IClosure Val Val {-# unpack #-} (NSystem VCof) Val
  deriving Show

type VTy = Val

-- TODO: could we index values by forcedness? Then all canonical consructors
-- could be written without explicit F wrapping.
data Val
  = VSub Val Sub

  -- Neutrals. These are annotated with sets of blocking ivars.  Glue types are
  -- also neutral, but they're handled separately, because we have to match on
  -- them in coe/hcom.
  | VNe Ne IS.IVarSet         -- TODO: can we annotate with NCof (of the last forcing)
                              -- if stored NCof == current NCof, shortcut?
  | VGlueTy VTy (NSystem VCof)

  -- canonicals
  | VPi Name VTy Closure
  | VLam Name Closure
  | VPathP Name IClosure Val Val
  | VPLam Name IClosure
  | VSg Name VTy Closure
  | VPair Val Val
  | VU
  deriving Show

type DomArg  = (?dom :: Lvl)    -- fresh LocalVar

-- Substitution
--------------------------------------------------------------------------------

instance SubAction Val where
  goSub v s = case v of
    VSub v s' -> VSub v (goSub s' s)
    v         -> VSub v s

instance SubAction NeCof where
  goSub cof s = case cof of
    NCAnd c1 c2 -> NCAnd (goSub c1 s) (goSub c2 s)
    NCEq i j    -> NCEq (goSub i s) (goSub j s)

instance SubAction VCof where
  goSub cof s = case cof of
    VCTrue        -> VCTrue
    VCFalse       -> VCFalse
    VCNe necof is -> VCNe (goSub necof s) (goSub is s)

instance SubAction (NSystem VCof) where
  goSub (NSystem nsys is) s = NSystem (goSub nsys s) (goSub is s)

instance SubAction (NSystemComps VCof) where
  goSub sys s = case sys of
    NSEmpty          -> NSEmpty
    NSCons cof v sys -> NSCons (goSub cof s) (goSub v s) (goSub sys s)

instance SubAction (VSystem VCof) where
  goSub sys s = case sys of
    VSTotal v              -> VSTotal (goSub v s)
    VSNe (NSystem nsys is) -> VSNe (NSystem (goSub nsys s) (goSub is s))

instance SubAction Ne where
  goSub n s = case n of
    NSub n s' -> NSub n (goSub s' s)
    n         -> NSub n s

instance SubAction Closure where
  goSub cl s = case cl of
    CEval s' env t ->
      CEval (goSub s' s) (goSub env s) t

    -- note: recursive closure sub below! TODO to scrutinize, but this is probably
    -- fine, because recursive depth is bounded by Pi type nesting.
    CCoePi r r' i a b t ->
      CCoePi (goSub r s) (goSub r' s) i (goSub a s) (goSub b s) (goSub t s)

    CHComPi r r' i a b sys base ->
      CHComPi (goSub r s) (goSub r' s) i (goSub a s)
              (goSub b s) (goSub sys s) (goSub base s)

instance SubAction IClosure where
  goSub cl s = case cl of
    ICEval s' env t ->
      ICEval (goSub s' s) (goSub env s) t

    -- recursive sub here as well!
    ICCoePathP r r' i a lhs rhs p ->
      ICCoePathP (sub r s) (sub r' s) i (sub a s)
                 (sub lhs s) (sub rhs s) (sub p s)

    ICHComPathP r r' i a lhs rhs sys base ->
      ICHComPathP (sub r s) (sub r' s) i (sub a s)
                  (sub lhs s) (sub rhs s) (sub sys s) (sub base s)

instance SubAction Env where
  goSub e s = case e of
    ENil     -> ENil
    EDef e v -> EDef (goSub e s) (goSub v s)

instance SubAction CofEq where
  goSub (CofEq i j) s = CofEq (goSub i s) (goSub j s)

instance SubAction Cof where
  goSub cof s = case cof of
    CTrue       -> CTrue
    CAnd eq cof -> CAnd (goSub eq s) (goSub cof s)

-- Evaluation
--------------------------------------------------------------------------------

localVar :: EnvArg => Ix -> Val
localVar x = go ?env x where
  go (EDef _ v) 0 = v
  go (EDef e _) x = go e (x - 1)
  go _          _ = impossible

-- | Apply a function. Note: *strict* in argument.
app :: IDomArg => NCofArg => DomArg => F Val -> Val -> Val
app t u = case unF t of
  VLam _ t -> capp t u
  VNe t is -> VNe (NApp t u) is
  _        -> impossible

appf  t u = force (app t u); {-# inline appf #-}
appf' t u = force' (app t u); {-# inline appf' #-}

-- | Apply a closure. Note: *lazy* in argument.
capp :: IDomArg => NCofArg => DomArg => Closure -> Val -> Val
capp t ~u = case t of

  CEval s env t ->
    let ?sub = s; ?env = EDef env u in eval t

  CCoePi (forceI -> r) (forceI -> r') i (force -> a) b t ->
   let fu = force u in
   unF (coe r r' i (bindI \_ -> cappf b (unF (coeFillInv r' (unF a) fu)))
                   (appf (force t) (unF (coe r' r i a fu))))

  CHComPi (forceI -> r) (forceI -> r') i a b sys base ->
    hcom r r' i (cappf b u)
         (mapVSystem                    -- TODO: map+force can be fused
            (implParams \i t -> app (force t) u)
            (forceNSystem sys))
         (appf (force base) u)


cappf  t ~u = force  (capp t u); {-# inline cappf  #-}
cappf' t ~u = force' (capp t u); {-# inline cappf' #-}

-- This is required to make lambdas with impl params strict. TODO: improve
-- the plugin!
-- TODO: can I instead make functions strict at use site in mapVSystem?
implParams :: (IDomArg => NCofArg => DomArg => a) -> (IDomArg => NCofArg => DomArg => a)
implParams f = let !_ = ?idom; !_ = ?cof; !_ = ?dom in f
{-# inline implParams #-}

-- | Apply an ivar closure.
icapp :: IDomArg => NCofArg => DomArg => IClosure -> I -> Val
icapp t arg = case t of
  ICEval s env t -> let ?env = env; ?sub = extSub s arg in eval t

  ICCoePathP (forceI -> r) (forceI -> r') ix a lhs rhs p ->
    let farg = forceI arg in
    com r r' ix (icappf a arg)
        ( scons (ceq farg (F I0)) lhs $
          scons (ceq farg (F I1)) rhs $
          sempty)
        (pappf (force p) lhs rhs farg)

  ICHComPathP (forceI -> r) (forceI -> r') ix a lhs rhs
              (forceNSystem -> sys) p ->

    let farg = forceI arg in

    hcom r r' ix (icappf a arg)
        ( scons (ceq farg (F I0)) lhs $
          scons (ceq farg (F I1)) rhs $
          (mapVSystem (implParams \_ t -> papp (force t) lhs rhs farg)  sys)
        )
      (pappf (force p) lhs rhs farg)


icappf  t i = force  (icapp t i); {-# inline icappf  #-}
icappf' t i = force' (icapp t i); {-# inline icappf' #-}

proj1 :: F Val -> Val
proj1 t = case unF t of
  VPair t _ -> t
  VNe t is  -> VNe (NProj1 t) is
  _         -> impossible

proj1f  t = force  (proj1 t); {-# inline proj1f  #-}
proj1f' t = force' (proj1 t); {-# inline proj1f' #-}

proj2 :: F Val -> Val
proj2 t = case unF t of
  VPair _ u -> u
  VNe t is  -> VNe (NProj2 t) is
  _         -> impossible

proj2f  t = force  (proj2 t); {-# inline proj2f #-}
proj2f' t = force' (proj2 t); {-# inline proj2f' #-}

-- | Apply a path.
papp :: IDomArg => NCofArg => DomArg => F Val -> Val -> Val -> F I -> Val
papp ~t ~u0 ~u1 i = case unF i of
  I0     -> u0
  I1     -> u1
  IVar x -> case unF t of
    VPLam _ t -> icapp t (IVar x)
    VNe t is  -> VNe (NPApp t u0 u1 x) (IS.insert x is)
    _         -> impossible
{-# inline papp #-}

pappf  ~t ~u0 ~u1 i = force  (papp t u0 u1 i); {-# inline pappf  #-}
pappf' ~t ~u0 ~u1 i = force' (papp t u0 u1 i); {-# inline pappf' #-}

-- Γ, i ⊢ coeFillⁱ r A t : A  [i=r ↦ t, i=r' ↦ coeⁱ r r' A t ]  for all r'
coeFill :: IDomArg => NCofArg => DomArg => F I -> Val -> F Val -> F Val
coeFill r a t =
  let i = ?idom - 1 in
  goCoe r (F (IVar i)) "j" (bindI \j -> singleSubf (force a) i (F (IVar j))) t
{-# inline coeFill #-}

coeFillInv :: IDomArg => NCofArg => DomArg => F I -> Val -> F Val -> F Val
coeFillInv r' a t =
  let i = ?idom - 1 in
  goCoe r' (F (IVar i)) "j" (bindI \j -> singleSubf (force a) i (F (IVar j))) t
{-# inline coeFillInv #-}

-- assumption: r /= r'
goCoe :: IDomArg => NCofArg => DomArg => F I -> F I -> Name -> F Val -> F Val -> F Val
goCoe r r' i a t = case unF a of
  VPi x a b ->
    F (VLam x (CCoePi (unF r) (unF r') i a b (unF t)))

  VSg x a b ->
    let fa    = bindI \_ -> force a
        t1    = force (proj1 t)
        t2    = force (proj2 t)
        bfill = bindI \_ -> cappf b (unF (coeFill r (unF fa) t1))
    in F (VPair (unF (goCoe r r' i fa t1))
                (unF (goCoe r r' i bfill t2)))

  VPathP j a lhs rhs ->
    F (VPLam j (ICCoePathP (unF r) (unF r') j a lhs rhs (unF t)))

  VU ->
    t

  a@(VNe n is) ->
    F (VNe (NCoe (unF r) (unF r') i a (unF t))
           (IS.insertI (unF r) $ IS.insertI (unF r') is))

  VGlueTy a sys ->
    uf

  _ ->
    impossible

coe :: IDomArg => NCofArg => DomArg => F I -> F I -> Name -> F Val -> F Val -> F Val
coe r r' i ~a t
  | unF r == unF r' = t
  | True            = goCoe r r' i a t
{-# inline coe #-}

-- assumption: r /= r' and system is stuck
goHCom :: IDomArg => NCofArg => DomArg =>
          F I -> F I -> Name -> F Val -> NSystem (F VCof) -> F Val -> F Val
goHCom r r' ix a nsys base = case unF a of

  VPi x a b ->
    F (VLam x (CHComPi (unF r) (unF r') ix a b (unFNSystem nsys) (unF base)))

  VSg x a b ->

    let bfill = bindI \i ->
          cappf b (unF (goHCom r (F (IVar i)) ix (force a)
                               (mapNSystem (\i t -> proj1 (force t)) nsys)
                               (proj1f base))) in

    F (VPair
      (unF (goHCom r r' ix (force a)
                  (mapNSystem (\i t -> proj1 (force t)) nsys)
                  (proj1f base)))
      (unF (goCom r r' ix bfill
                  (mapNSystem (\i t -> proj2 (force t)) nsys)
                  (proj2f base)))
      )

  VPathP j a lhs rhs ->
    F (VPLam j (ICHComPathP (unF r) (unF r')
                            ix a lhs rhs (unFNSystem nsys) (unF base)))

  a@(VNe n is) ->
    F (VNe (NHCom (unF r) (unF r') ix a (unFNSystem nsys) (unF base))
           (IS.insertI (unF r) $ IS.insertI (unF r') (_ivars nsys <> is)))

  VU ->
    uf

  VGlueTy a sys  ->
    uf

  _ ->
    impossible

hcom :: IDomArg => NCofArg => DomArg => F I -> F I
     -> Name -> F Val -> F (VSystem (F VCof)) -> F Val -> Val
hcom r r' i ~a ~t ~b
  | unF r == unF r'          = unF b
  | VSTotal v       <- unF t = topSub v r'
  | VSNe nsys       <- unF t = unF (goHCom r r' i a nsys b)
{-# inline hcom #-}

hcomf  r r' i ~a ~t ~b = force  (hcom r r' i a t b); {-# inline hcomf  #-}
hcomf' r r' i ~a ~t ~b = force' (hcom r r' i a t b); {-# inline hcomf' #-}

-- | Identity sub except one var is mapped to
singleSubf :: IDomArg => NCofArg => DomArg => F Val -> IVar -> F I -> F Val
singleSubf t x i = forceVSub (unF t) (single x (unF i))

singleSub :: IDomArg => Val -> IVar -> F I -> Val
singleSub t x i = sub t (single x (unF i))

-- | Instantiate the topmost var.
topSubf :: IDomArg => NCofArg => DomArg => F Val -> F I -> F Val
topSubf t i = forceVSub (unF t) (idSub ?idom `extSub` unF i)

-- | Instantiate the topmost var.
topSub :: IDomArg => Val -> F I -> Val
topSub t i = sub t (idSub ?idom `extSub` unF i)

com :: IDomArg => NCofArg => DomArg => F I -> F I -> Name -> F Val
    -> F (VSystem (F VCof)) -> F Val -> Val
com r r' x ~a ~sys ~b =
  hcom r r' x
    (topSubf a r')
    (mapVSystem
       (implParams \i t ->
           unF (goCoe (F (IVar i)) r' "j"
               (bindI \j -> singleSubf a i (F (IVar j)))
               (force t)))
       sys)
    (coe r r' x a b)
{-# inline com #-}

goCom :: IDomArg => NCofArg => DomArg => F I -> F I -> Name -> F Val
    -> NSystem (F VCof) -> F Val -> F Val
goCom r r' x a nsys  b =
  goHCom r r' x
    (topSubf a r')
    (mapNSystem
       (implParams \i t ->
           unF (goCoe (F (IVar i)) r' "j"
               (bindI \j -> singleSubf a i (F (IVar j)))
               (force t)))
       nsys)
    (goCoe r r' x a b)

glueTy :: IDomArg => NCofArg => DomArg => Val -> F (VSystem (F VCof)) -> Val
glueTy a sys = case unF sys of
  VSTotal b -> proj1 (force b)
  VSNe nsys -> VGlueTy a (unFNSystem nsys)
{-# inline glueTy #-}

glueTyf  ~a sys = force  (glueTy a sys); {-# inline glueTyf  #-}
glueTyf' ~a sys = force' (glueTy a sys); {-# inline glueTyf' #-}

glue :: Val -> F (VSystem (F VCof)) -> Val
glue ~t sys = case unF sys of
  VSTotal v -> v
  VSNe nsys -> VNe (NGlue t (unFNSystem nsys)) (_ivars nsys)
{-# inline glue #-}

gluef  ~a sys = force  (glue a sys); {-# inline gluef  #-}
gluef' ~a sys = force' (glue a sys); {-# inline gluef' #-}

unglue :: IDomArg => NCofArg => DomArg => Val -> F (VSystem (F VCof)) -> Val
unglue t sys = case unF sys of
  VSTotal teqv -> app (proj1f (proj2f (force teqv))) t
  VSNe nsys    -> VNe (NUnglue t (unFNSystem nsys)) (_ivars nsys)
{-# inline unglue #-}

ungluef  ~a sys = force  (unglue a sys); {-# inline ungluef  #-}
ungluef' ~a sys = force' (unglue a sys); {-# inline ungluef' #-}


evalf :: IDomArg => SubArg => NCofArg => DomArg => EnvArg => Tm -> F Val
evalf t = force (eval t)
{-# inline evalf #-}

eval :: IDomArg => SubArg => NCofArg => DomArg => EnvArg => Tm -> Val
eval = \case
  TopVar _ v        -> coerce v
  LocalVar x        -> localVar x
  Let x _ t u       -> let ~v = eval t in let ?env = EDef ?env v in eval u
  Pi x a b          -> VPi x (eval a) (CEval ?sub ?env b)
  App t u           -> app (evalf t) (eval u)
  Lam x t           -> VLam x (CEval ?sub ?env t)
  Sg x a b          -> VSg x (eval a) (CEval ?sub ?env b)
  Pair t u          -> VPair (eval t) (eval u)
  Proj1 t           -> proj1 (evalf t)
  Proj2 t           -> proj2 (evalf t)
  U                 -> VU
  PathP x a t u     -> VPathP x (ICEval ?sub ?env a) (eval t) (eval u)
  PApp t u0 u1 i    -> papp (evalf t) (eval u0) (eval u1) (evalI i)
  PLam x t          -> VPLam x (ICEval ?sub ?env t)
  Coe r r' x a t    -> unF (coe (evalI r) (evalI r') x (bindI' \_ -> evalf a) (evalf t))
  HCom r r' x a t b -> hcom (evalI r) (evalI r') x (evalf a) (evalSystem t) (evalf b)
  GlueTy a sys      -> glueTy (eval a) (evalSystem sys)
  GlueTm t sys      -> glue   (eval t) (evalSystem sys)
  Unglue t sys      -> unglue (eval t) (evalSystem sys)


-- Forcing
--------------------------------------------------------------------------------

forceNeCof' :: SubArg => NCofArg => NeCof -> F VCof
forceNeCof' = \case
  NCEq i j -> ceq (forceI' i) (forceI' j)
  NCAnd c1 c2 -> cand (forceNeCof' c1) (forceNeCof' c2)

forceCof' :: SubArg => NCofArg => VCof -> F VCof
forceCof' = \case
  VCTrue       -> ctrue
  VCFalse      -> cfalse
  VCNe ncof is -> forceNeCof' ncof

forceNSystem :: IDomArg => NCofArg => NSystem VCof -> F (VSystem (F VCof))
forceNSystem nsys = let ?sub = idSub ?idom in forceNSystem' nsys

forceSystem :: IDomArg => NCofArg => VSystem VCof -> F (VSystem (F VCof))
forceSystem sys = let ?sub = idSub ?idom in forceSystem' sys

forceSystem' :: IDomArg => SubArg => NCofArg => VSystem VCof -> F (VSystem (F VCof))
forceSystem' = \case
  VSTotal v -> F (VSTotal v)
  VSNe nsys -> forceNSystem nsys

forceNSystemComps' :: IDomArg => SubArg => NCofArg => NSystemComps VCof -> F (VSystem (F VCof))
forceNSystemComps' = \case
  NSEmpty          -> sempty
  NSCons cof t sys -> scons (forceCof' cof) t (forceNSystemComps' sys)

forceNSystem' :: IDomArg => SubArg => NCofArg => NSystem VCof -> F (VSystem (F VCof))
forceNSystem' (NSystem nsys _) = forceNSystemComps' nsys

forceVSub :: IDomArg => NCofArg => DomArg => Val -> Sub -> F Val
forceVSub v s = let ?sub = s in force' v
{-# inline forceVSub #-}

force :: IDomArg => NCofArg => DomArg => Val -> F Val
force v = let ?sub = idSub ?idom in force' v
{-# inline force #-}

force' :: IDomArg => SubArg => NCofArg => DomArg => Val -> F Val
force' = \case
  VSub v s                                  -> let ?sub = sub s ?sub in force' v
  VNe t is      | isUnblocked' is           -> forceNe' t
  VGlueTy a sys | isUnblocked' (_ivars sys) -> glueTyf' a (forceNSystem' sys)
  v                                         -> F (sub v ?sub)

forceI :: NCofArg => I -> F I
forceI i = F (sub i ?cof)

forceI' :: SubArg => NCofArg => I -> F I
forceI' i = F (i `sub` ?sub `sub` ?cof)

forceIVar :: NCofArg => IVar -> F I
forceIVar x = F (lookupSub x ?cof)

forceIVar' :: SubArg => NCofArg => IVar -> F I
forceIVar' x = F (lookupSub x ?sub `sub` ?cof)

forceNSub :: IDomArg => NCofArg => DomArg => Ne -> Sub -> F Val
forceNSub n s = let ?sub = s in forceNe' n
{-# inline forceNSub #-}

forceNe' :: IDomArg => SubArg => NCofArg => DomArg => Ne -> F Val
forceNe' = \case
  n@(NLocalVar x)      -> F (VNe n mempty)
  NSub n s             -> let ?sub = sub s ?sub in forceNe' n
  NApp t u             -> appf' (forceNe' t) (sub u ?sub)
  NPApp t l r i        -> pappf' (forceNe' t) (sub l ?sub) (sub r ?sub) (forceIVar' i)
  NProj1 t             -> proj1f' (forceNe' t)
  NProj2 t             -> proj2f' (forceNe' t)
  NCoe r r' x a t      -> coe (forceI' r) (forceI' r') x (bindI' \_ -> force' a) (force' t)
  NHCom r r' x a sys t -> hcomf' (forceI' r) (forceI' r') x (force' a)
                                 (forceNSystem' sys) (force' t)
  NUnglue t sys        -> ungluef' t (forceNSystem' sys)
  NGlue t sys          -> gluef' t (forceNSystem' sys)
