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
, sample
, switchB
, switchE
, dynE
, SGen
, reactimate
, newAddHandler
) where

import Reactive.Impulse.Core

import Control.Applicative

import System.IO.Unsafe (unsafePerformIO)

-----------------------------------------------------------
-- Event/Behavior combinators

stepper :: a -> Event a -> Behavior a
stepper a0 e = BAcc (unsafePerformIO getLabel) a0 (const <$> e)

accumB :: a -> Event (a -> a) -> Behavior a
accumB a e = BAcc (unsafePerformIO getLabel) a e

applyB :: Event a -> Behavior (a -> b) -> Event b
applyB e b = EApply (unsafePerformIO getLabel) e b

sample :: Event a -> Behavior b -> Event b
sample e = applyB e . (const <$>)

switchB :: Behavior a -> Event (Behavior a) -> Behavior a
switchB b0 e = BSwch (unsafePerformIO getLabel) b0 e

switchE :: Behavior (Event a) -> Event a
switchE b = ESwch (unsafePerformIO getLabel) b

dynE :: Event (SGen a) -> Event a
dynE e = EDyn (unsafePerformIO getLabel) e
