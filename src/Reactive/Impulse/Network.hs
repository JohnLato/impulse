{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE DeriveFunctor #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE RecursiveDo #-}

{-# OPTIONS_GHC -Wall #-}
module Reactive.Impulse.Network (
  Network (..)
, compileNetwork
, startNetwork
, stopNetwork
) where

import Reactive.Impulse.Core
import Reactive.Impulse.Chain

import Control.Applicative ()
import Control.Monad.RWS
import Control.Monad.State

import Data.Either (rights)
import Data.IORef

import Unsafe.Coerce

-----------------------------------------------------------
-- Network, starting/stopping.

-- a Network is a set of inputs and chains.  It doesn't ref the whole 
-- event graph so that Events can be GC'd if they're no longer used.
-- TODO: reconfigure the chain/behavior mapping and make it use weak refs
-- so those elements can be GC'd also.
data Network = Network
    { nInputs :: [SGInput]
    , nDynGraph :: DynGraph
    }

compileNetwork :: SGen a -> IO (a,Network)
compileNetwork net = do
    (a,SGState {..}) <- runStateT net (SGState [] [])
    (nDynGraph,_) <- execRWST (buildTopChains outputs) () emptyDynGraph
    return $ (a, Network { nInputs = inputs, nDynGraph })

-- TODO: cache the built actions somewhere
startNetwork :: Network -> IO ()
startNetwork Network {..} = do
    forM_ (reverse nInputs) $ \(SGInput ref (EIn lbl)) -> do
        mTrace $ "compiling input " ++ show lbl
        case getChain lbl nDynGraph of
            Nothing -> error $ "runNetwork: no node for input: " ++ show lbl
            Just (EChain chain)-> do
                when (chainLbl chain /= lbl)
                    $ error "runNetwork: label mismatch"
                let !actK = compileChain chain
                    action a = do
                        steps <- (unsafeCoerce actK) id a
                        sequence_ $ rights steps
                writeIORef ref action

-- terminate a network (TODO: make this pause)
stopNetwork :: Network -> IO ()
stopNetwork Network {..} = forM_ nInputs $
    \(SGInput ref _) -> writeIORef ref (const $ return ())
