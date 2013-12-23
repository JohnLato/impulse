{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE DeriveFunctor #-}
{-# LANGUAGE GADTs #-}
{-# OPTIONS_GHC -Wall #-}
module Reactive.Impulse.Syntax (
  Event
, Behavior
, stepper
, accumB
, applyB
, applyE
, sample
, switchB
, switchE
, dynE
, joinE
, filterE
, onCreation
, SGen
, reactimate
, newAddHandler
) where

import Reactive.Impulse.Core
import Reactive.Impulse.Internal.Types (FireOnce(..))

import Control.Applicative
import Control.Monad.IO.Class

import System.IO.Unsafe (unsafePerformIO)

-----------------------------------------------------------
-- Event/Behavior combinators

stepper :: a -> Event a -> Behavior a
stepper a0 e = BAcc (unsafePerformIO getLabel) a0 (const <$> e)

accumB :: a -> Event (a -> a) -> Behavior a
accumB a e = BAcc (unsafePerformIO getLabel) a e

applyB :: Event a -> Behavior (a -> b) -> Event b
applyB e b = EApply (unsafePerformIO getLabel) e b

applyE :: Event (a -> b) -> Behavior a -> Event b
applyE e b = applyB e ((\a -> ($ a)) <$> b)

sample :: Event a -> Behavior b -> Event b
sample e = applyB e . (const <$>)

switchB :: Behavior a -> Event (Behavior a) -> Behavior a
switchB b0 e = BSwch (unsafePerformIO getLabel) b0 e

switchE :: Behavior (Event a) -> Event a
switchE b = ESwch (unsafePerformIO getLabel) b

dynE :: Event (SGen a) -> Event a
dynE e = EDyn (unsafePerformIO getLabel) e

filterE :: (a -> Maybe b) -> Event a -> Event b
filterE p e = EFilt (unsafePerformIO getLabel) p e

joinE :: Event (Event a) -> Event a
joinE e = EJoin (unsafePerformIO getLabel) e

onCreation :: a -> SGen (Event a)
onCreation a = do
    lbl <- liftIO $ getLabel
    let evt = EIn lbl
        dirty = FireOnce lbl a
    error "TODO: onCreation: need to make sure the head exists, and need to add a dirty log to SGen"
    return evt
