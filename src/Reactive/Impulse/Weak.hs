{-# LANGUAGE MagicHash #-}
{-# LANGUAGE UnboxedTuples #-}

{-# OPTIONS_GHC -Wall #-}
module Reactive.Impulse.Weak (
  mkWeakTVar
, mkWeakTVarKey
) where

import GHC.Conc.Sync (TVar (..))
import GHC.Weak
import GHC.Base

mkWeakTVar :: TVar a -> Maybe (IO ()) -> IO (Weak (TVar a))
mkWeakTVar t f = mkWeakTVarKey t t f

-- | Create a Weak reference keyed off a TVar.
mkWeakTVarKey :: TVar b -> a -> Maybe (IO ()) -> IO (Weak a)
mkWeakTVarKey (TVar r#) v (Just f) = IO $ \s ->
      case mkWeak# r# v f s of (# s1, w #) -> (# s1, Weak w #)
mkWeakTVarKey (TVar r#) v Nothing = IO $ \s ->
      case mkWeakNoFinalizer# r# v s of (# s1, w #) -> (# s1, Weak w #)
