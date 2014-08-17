{-# LANGUAGE CPP #-}
{-# LANGUAGE MagicHash #-}
{-# LANGUAGE UnboxedTuples #-}

{-# OPTIONS_GHC -Wall #-}
module Reactive.Impulse.Internal.Weak (
  mkWeakTVar
, mkWeakTVarKey
) where

import GHC.Conc.Sync (TVar (..))
import GHC.Weak
import GHC.Base

#if MIN_VERSION_stm(2,4,3)
import qualified Control.Concurrent.STM as STM

mkWeakTVar :: TVar a -> Maybe (IO ()) -> IO (Weak (TVar a))
mkWeakTVar t f = STM.mkWeakTVar t (maybe (return ()) id f)
#else
mkWeakTVar :: TVar a -> Maybe (IO ()) -> IO (Weak (TVar a))
mkWeakTVar t f = mkWeakTVarKey t t f
#endif

-- | Create a Weak reference keyed off a TVar.
mkWeakTVarKey :: TVar b -> a -> Maybe (IO ()) -> IO (Weak a)
mkWeakTVarKey (TVar r#) v (Just f) = IO $ \s ->
      case mkWeak# r# v f s of (# s1, w #) -> (# s1, Weak w #)
mkWeakTVarKey (TVar r#) v Nothing = IO $ \s ->
      case mkWeakNoFinalizer# r# v s of (# s1, w #) -> (# s1, Weak w #)
