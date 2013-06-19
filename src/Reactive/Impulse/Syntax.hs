{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE DeriveFunctor #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE RecursiveDo #-}

{-# OPTIONS_GHC -Wall #-}
module Reactive.Impulse.Syntax (
  Event
, Behavior
, stepper
, accumB
, applyB
, sample
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
