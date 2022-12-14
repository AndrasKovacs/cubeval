
module Substitution where

import Common
import qualified IVarSet as IS
import Interval


{-|
Interval substitutions are length-postfixed lists of interval expressions,
stored in a 64-bit word. The most significant 4-bit (nibble) is the length. -}
newtype Sub = Sub {unSub :: Word}
  deriving Eq via Word

type SubArg = (?sub :: Sub)  -- ImplicitParams

{-|
Normalized cofibrations are also represented as interval substitutions. Here,
every ivar is mapped to the greatest (as a De Bruijn level) representative of
its equivalence class.
-}
type NCof = Sub
type NCofArg = (?cof :: NCof)

nibblesToWord :: [Word] -> Sub
nibblesToWord ns = Sub (go 0 0 ns) where
  go shift acc []     = acc
  go shift acc (n:ns) = go (shift + 4) (unsafeShiftL n shift .|. acc) ns

wordNibbles :: Sub -> [Word]
wordNibbles (Sub s) = go s where
  go 0 = []
  go n = n .&. 15 : go (unsafeShiftR n 4)

emptySub# :: Word
emptySub# = 1070935975390360080 -- nibblesToSub [0..14]
{-# inline emptySub# #-}

emptySub :: Sub
emptySub = Sub emptySub#
{-# inline emptySub #-}

idSub :: IVar -> Sub
idSub (IVar# x) = Sub (emptySub# .|. unsafeShiftL x 60)
{-# inline idSub #-}

subLength :: Sub -> Word
subLength (Sub n) = unsafeShiftR n 60
{-# inline subLength #-}

lookupSub :: IVar -> Sub -> I
lookupSub (IVar# x) (Sub s) =
  I (unsafeShiftR s (unsafeShiftL (w2i x) 2) .&. 15)
{-# inline lookupSub #-}

-- | Strict right fold over all (index, I) mappings in a substitution.
foldrSub :: forall b. (IVar -> I -> b -> b) -> b -> Sub -> b
foldrSub f b (Sub s) = go 0 (IVar# (subLength (Sub s))) s where
  go i l n | i < l = f i (I (n .&. 15)) $! go (i + 1) l (unsafeShiftR n 4)
  go i l n = b
{-# inline foldrSub #-}

subToList :: Sub -> [I]
subToList = foldrSub (\_ i is -> i:is) []

subFromList :: [I] -> Sub
subFromList is = Sub (go acc 0 is .|. unsafeShiftL (i2w len) 60) where
  len  = length is
  blen = unsafeShiftL len 2
  acc  = unsafeShiftL (unsafeShiftR emptySub# blen) blen

  go :: Word -> Int -> [I] -> Word
  go acc shift []     = acc
  go acc shift (i:is) = go (unsafeShiftL (coerce i) shift .|. acc) (shift + 4)  is

instance Show Sub where
  show = show . subToList

mapSub :: (IVar -> I -> I) -> Sub -> Sub
mapSub f (Sub s) = Sub (go s s' 0 (coerce len)) where
  len  = subLength (Sub s)
  blen = unsafeShiftL len 2
  s'   = unsafeShiftL (unsafeShiftR s (w2i blen)) (w2i blen)
  go :: Word -> Word -> IVar -> IVar -> Word
  go inp out ix len
    | ix < len = let i' = f ix (I (inp .&. 15))
                 in go (unsafeShiftR inp 4)
                       (out .|. unsafeShiftL (coerce i') (w2i (coerce (unsafeShiftL ix 2))))
                       (ix + 1) len
    | True     = out
{-# inline mapSub #-}

-- 0 bits where the length is, else 1
lengthUnMask# :: Word
lengthUnMask# = 1152921504606846975

extSub :: Sub -> I -> Sub
extSub (Sub s) i =
  let l  = subLength (Sub s)
      bl = unsafeShiftL l 2
  in Sub (s .&. lengthUnMask#
            .&. complement (unsafeShiftL 15 (w2i bl))
            .|. unsafeShiftL (l + 1) 60
            .|. unsafeShiftL (coerce i) (w2i bl))
{-# inline extSub #-}

single :: IDomArg => IVar -> I -> Sub
single x i =
  let xbits  = unsafeShiftL (coerce x) 2
  in Sub (unSub (idSub ?idom)
            .&. complement (unsafeShiftL 15 (w2i xbits))
            .|. unsafeShiftL (coerce i) (w2i xbits))
{-# inline single #-}

class SubAction a where
  sub :: SubArg => a -> a

doSub :: SubAction a => a -> Sub -> a
doSub a s = let ?sub = s in sub a
{-# inline doSub #-}

hasAction :: Sub -> Bool
hasAction (Sub s) = (s .&. lengthUnMask#) /= emptySub#
{-# inline hasAction #-}

subIfHasAction :: SubAction a => a -> Sub -> a
subIfHasAction ~a s = if hasAction s then doSub a s else a
{-# inline subIfHasAction #-}

instance SubAction I where
  sub i = matchIVar i
    (\x -> lookupSub x ?sub) i
  {-# inline sub #-}

-- substitution composition
instance SubAction Sub where
  sub f = mapSub (\_ i -> sub i) f
  {-# noinline sub #-}

-- A set of blocking ivars is still blocked under a cofibration
-- if all vars in the set are represented by distinct vars.
isUnblocked :: NCofArg => IS.IVarSet -> Bool
isUnblocked is = go is mempty where
  go :: IS.IVarSet -> IS.IVarSet -> Bool
  go is varset = IS.popSmallest is
    (\is x -> matchIVar (lookupSub x ?cof)
       (\x -> not (IS.member x varset) && go is (IS.insert x varset))
       True)
    False

isUnblocked' :: SubArg => NCofArg => IS.IVarSet -> Bool
isUnblocked' is = go is (mempty @IS.IVarSet) where
  go :: IS.IVarSet -> IS.IVarSet -> Bool
  go is varset = IS.popSmallest is
    (\is x -> matchIVar (lookupSub x ?sub)
      (\x -> matchIVar (lookupSub x ?cof)
        (\x -> not (IS.member x varset) && go is (IS.insert x varset))
        True)
      True)
    False

instance SubAction IS.IVarSet where
  sub is = IS.foldl
    (\acc i -> IS.insertI (lookupSub i ?sub) acc)
    mempty is
  {-# noinline sub #-}
