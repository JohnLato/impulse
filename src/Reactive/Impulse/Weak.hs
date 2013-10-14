{-# LANGUAGE MagicHash #-}
{-# LANGUAGE UnboxedTuples #-}

{-# OPTIONS_GHC -Wall #-}
module Reactive.Impulse.Weak (
  mkWeakTVar
) where

import GHC.Conc.Sync (TVar (..))
import GHC.Weak
import GHC.Base

mkWeakTVar :: TVar a -> Maybe (IO ()) -> IO (Weak (TVar a))
mkWeakTVar r@(TVar r#) (Just f) = IO $ \s ->
      case mkWeak# r# r f s of (# s1, w #) -> (# s1, Weak w #)
mkWeakTVar r@(TVar r#) Nothing = IO $ \s ->
      case mkWeakNoFinalizer# r# r s of (# s1, w #) -> (# s1, Weak w #)
